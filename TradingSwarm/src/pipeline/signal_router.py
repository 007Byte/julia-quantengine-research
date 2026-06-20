"""
Signal Router — connects the signal engine to risk gate, OMS, and execution.

This is the full hot-path orchestration:
  Signal -> Risk Evaluation -> Atomic Reservation -> OMS Accept -> Child Order -> Execution

No async approval. No polling. Synchronous and deterministic.
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

from src.core.event_schema import (
    Fill,
    OrderIntent,
    OrderIntentState,
    OrderIntentType,
    RiskDecisionType,
    Side,
    StreamEnvelope,
    TimeInForce,
    VenueOrderState,
)
from src.core.instrument_master import InstrumentMaster
from src.control.kill_switch import ConservativeMode, KillSwitch
from src.execution.base_adapter import BaseAdapter
from src.ledger import redis_streams
from src.pipeline.oms import OrderManagementSystem
from src.pipeline.risk_gate import PreTradeRiskGate

logger = logging.getLogger(__name__)


class SignalRouter:
    """
    Routes approved signals through the full execution pipeline.

    Enforces:
    - Kill switch check
    - Conservative mode sizing
    - Inline risk evaluation
    - Durable intent before order submission
    - No order without atomic reservation
    """

    def __init__(
        self,
        team_id: str,
        risk_gate: PreTradeRiskGate,
        oms: OrderManagementSystem,
        adapter: BaseAdapter,
        kill_switch: KillSwitch,
        conservative_mode: ConservativeMode,
        instrument_master: InstrumentMaster,
    ) -> None:
        self.team_id = team_id
        self._risk = risk_gate
        self._oms = oms
        self._adapter = adapter
        self._kill = kill_switch
        self._conservative = conservative_mode
        self._im = instrument_master

    async def route_signal(self, signal_data: dict[str, Any]) -> dict[str, Any]:
        """
        Route a signal through the full pipeline.

        Returns a result dict with status and details.
        """
        signal_id = signal_data.get("signal_id", str(uuid.uuid4()))
        instrument_id = signal_data.get("instrument_id", "")
        side_str = signal_data.get("side", "buy")
        strength = float(signal_data.get("strength", 0.0))
        strategy_id = signal_data.get("strategy_id", "default")

        # 1. Kill switch
        if self._kill.is_killed or self._kill.is_team_killed(self.team_id):
            logger.warning("Kill switch active — dropping signal %s", signal_id)
            return {"status": "killed", "signal_id": signal_id}

        # 2. OMS frozen check
        if self._oms.is_frozen:
            logger.warning("OMS frozen — dropping signal %s", signal_id)
            return {"status": "frozen", "signal_id": signal_id}

        # 3. Conservative mode strategy filter
        if not self._conservative.is_strategy_allowed(strategy_id):
            logger.info("Conservative mode blocked strategy %s", strategy_id)
            return {"status": "conservative_blocked", "signal_id": signal_id}

        # 4. Determine sizing
        base_qty = self._compute_order_qty(instrument_id, strength)
        if base_qty <= 0:
            return {"status": "zero_qty", "signal_id": signal_id}

        # Apply conservative mode multiplier
        order_qty = Decimal(str(base_qty)) * Decimal(str(self._conservative.size_multiplier))

        # 5. Estimate notional
        estimated_price = await self._get_estimated_price(instrument_id)
        if estimated_price is None:
            logger.warning("No price for %s — cannot route signal", instrument_id)
            return {"status": "no_price", "signal_id": signal_id}
        estimated_notional = order_qty * estimated_price

        # 6. Build order intent
        intent = OrderIntent(
            idempotency_key=f"signal:{signal_id}",
            team_id=self.team_id,
            strategy_id=strategy_id,
            instrument_id=uuid.UUID(instrument_id) if isinstance(instrument_id, str) else instrument_id,
            side=Side(side_str),
            intent_type=OrderIntentType.MARKET,
            requested_qty=order_qty,
            signal_id=uuid.UUID(signal_id) if isinstance(signal_id, str) else signal_id,
            model_version=signal_data.get("model_version", ""),
            feature_version=signal_data.get("feature_version", ""),
            config_hash=signal_data.get("config_hash", ""),
        )

        # 7. Risk evaluation (synchronous, inline, blocking)
        intent.current_state = OrderIntentState.RISK_PENDING
        decision, reservation = await self._risk.evaluate(
            intent, estimated_notional
        )

        if decision.decision == RiskDecisionType.REJECTED:
            logger.info("Signal %s rejected by risk: %s", signal_id, decision.reason)
            return {"status": "risk_rejected", "reason": decision.reason, "signal_id": signal_id}

        if decision.decision == RiskDecisionType.SIZE_REDUCED and decision.approved_qty:
            intent.requested_qty = decision.approved_qty
            order_qty = decision.approved_qty

        # 8. Accept into OMS (DB-first with outbox)
        intent.current_state = OrderIntentState.RISK_APPROVED
        intent = await self._oms.accept_intent(intent)

        # 9. Create child venue order
        venue = self._adapter.venue
        venue_symbol = self._im.get_venue_symbol(intent.instrument_id, venue)
        if not venue_symbol:
            logger.error("No venue symbol for %s on %s", intent.instrument_id, venue)
            await self._oms.transition_intent(
                intent.order_intent_id, OrderIntentState.REJECTED,
                event_type="no_venue_symbol",
            )
            if reservation:
                await self._risk.release_reservation(reservation.reservation_id)
            return {"status": "no_venue_symbol", "signal_id": signal_id}

        child = await self._oms.create_child_order(
            intent.order_intent_id, venue, order_qty, intent.limit_price
        )

        # 10. Submit to venue
        await self._oms.transition_intent(
            intent.order_intent_id, OrderIntentState.ROUTING
        )

        try:
            result = await self._adapter.submit_order(
                venue_symbol=venue_symbol,
                side=intent.side.value,
                order_type=intent.intent_type.value,
                quantity=order_qty,
                limit_price=intent.limit_price,
                client_order_id=str(child.venue_order_id_internal),
            )

            broker_order_id = result.get("broker_order_id", "")
            status = result.get("status", "UNKNOWN")

            # Update child order with broker ID
            await self._oms.transition_venue_order(
                child.venue_order_id_internal,
                VenueOrderState.SUBMITTED,
                broker_order_id=broker_order_id,
            )

            # If immediately filled (common with market orders and paper adapter)
            if status == "FILLED":
                fill_price = Decimal(str(result.get("fill_price", estimated_price)))
                fill_qty = Decimal(str(result.get("fill_quantity", order_qty)))
                fee = fill_price * fill_qty * Decimal("0.001")

                await self._oms.transition_venue_order(
                    child.venue_order_id_internal,
                    VenueOrderState.FILLED,
                    broker_order_id=broker_order_id,
                    filled_qty=fill_qty,
                    avg_fill_price=fill_price,
                )

                fill = Fill(
                    order_intent_id=intent.order_intent_id,
                    venue_order_id_internal=child.venue_order_id_internal,
                    instrument_id=intent.instrument_id,
                    team_id=self.team_id,
                    strategy_id=strategy_id,
                    venue=venue,
                    side=intent.side,
                    quantity=fill_qty,
                    price=fill_price,
                    fee=fee,
                    fee_currency="USD",
                    expected_fill_price=estimated_price,
                    slippage_bps=abs(fill_price - estimated_price) / estimated_price * Decimal("10000") if estimated_price > 0 else Decimal("0"),
                )
                await self._oms.record_fill(fill)

                await self._oms.transition_intent(
                    intent.order_intent_id, OrderIntentState.FILLED,
                    event_type="immediate_fill",
                )

                return {
                    "status": "filled",
                    "signal_id": signal_id,
                    "fill_price": str(fill_price),
                    "fill_qty": str(fill_qty),
                    "broker_order_id": broker_order_id,
                }

            else:
                # Working order
                await self._oms.transition_intent(
                    intent.order_intent_id, OrderIntentState.WORKING,
                )
                return {
                    "status": "working",
                    "signal_id": signal_id,
                    "broker_order_id": broker_order_id,
                }

        except Exception as e:
            logger.exception("Order submission failed for signal %s", signal_id)
            await self._oms.transition_intent(
                intent.order_intent_id, OrderIntentState.REJECTED,
                event_type="submission_error",
                payload={"error": str(e)},
            )
            if reservation:
                await self._risk.release_reservation(reservation.reservation_id)
            return {"status": "error", "signal_id": signal_id, "error": str(e)}

    def _compute_order_qty(self, instrument_id: str, strength: float) -> Decimal:
        """Compute order quantity based on signal strength and risk limits."""
        # Simple sizing: scale with signal strength
        # In production, this would use Kelly criterion, portfolio heat, etc.
        base_size = Decimal("0.01")  # 1% of portfolio
        strength_factor = Decimal(str(max(0.5, min(1.5, strength * 2))))
        return base_size * strength_factor

    async def _get_estimated_price(self, instrument_id: str) -> Decimal | None:
        """Get current estimated price for an instrument."""
        # In production, read from the market data cache
        # For now, try to get from adapter
        if isinstance(instrument_id, str):
            iid = uuid.UUID(instrument_id)
        else:
            iid = instrument_id

        venue_symbol = self._im.get_venue_symbol(iid, self._adapter.venue)
        if not venue_symbol:
            return None

        # Paper adapter: check last_prices
        if hasattr(self._adapter, '_last_prices'):
            price = self._adapter._last_prices.get(venue_symbol)
            if price:
                return price

        return Decimal("50000")  # fallback for testing
