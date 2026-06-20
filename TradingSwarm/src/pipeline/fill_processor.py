"""
Fill Processor — updates positions, cash ledger, and parent order state from fills.

Flow:
1. Receive fill event
2. Update strategy_positions (quantity, avg_entry_price, realized_pnl)
3. Update cash_ledger (settlement, fees)
4. Update parent intent state (partially_filled / filled)
5. Convert risk reservation to actual exposure
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

from src.core.event_schema import OrderIntentState, Side, VenueOrderState
from src.ledger import postgres
from src.pipeline.oms import OrderManagementSystem

logger = logging.getLogger(__name__)


class FillProcessor:
    """Process fills into position and cash ledger updates."""

    def __init__(self, team_id: str, oms: OrderManagementSystem) -> None:
        self.team_id = team_id
        self.oms = oms

    async def process_fill_event(self, payload: dict[str, Any]) -> None:
        """
        Process a fill event from the fills.events stream.

        Idempotent: checks fill_id before processing.
        """
        fill_id = payload.get("fill_id")
        if not fill_id:
            logger.warning("Fill event missing fill_id")
            return

        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            # Idempotency check
            existing = await conn.fetchval(
                "SELECT 1 FROM fills WHERE fill_id = $1", uuid.UUID(fill_id)
            )
            if existing:
                logger.debug("Duplicate fill: %s", fill_id)
                return

            async with conn.transaction():
                # 1. Update strategy position
                await self._update_position(
                    conn,
                    team_id=payload["team_id"],
                    strategy_id=payload["strategy_id"],
                    instrument_id=uuid.UUID(payload["instrument_id"]),
                    side=payload["side"],
                    quantity=Decimal(str(payload["quantity"])),
                    price=Decimal(str(payload["price"])),
                )

                # 2. Update cash ledger
                await self._update_cash_ledger(
                    conn,
                    team_id=payload["team_id"],
                    fill_id=uuid.UUID(fill_id),
                    side=payload["side"],
                    quantity=Decimal(str(payload["quantity"])),
                    price=Decimal(str(payload["price"])),
                    fee=Decimal(str(payload.get("fee", "0"))),
                )

                # 3. Update parent intent and venue order states
                await self._update_order_states(
                    conn,
                    order_intent_id=uuid.UUID(payload["order_intent_id"]),
                    venue_order_id=uuid.UUID(payload["venue_order_id_internal"]) if payload.get("venue_order_id_internal") else None,
                    fill_qty=Decimal(str(payload["quantity"])),
                )

        logger.info(
            "Fill processed: %s [%s %s @ %s]",
            fill_id, payload["side"], payload["quantity"], payload["price"],
        )

    async def _update_position(
        self,
        conn: Any,
        team_id: str,
        strategy_id: str,
        instrument_id: uuid.UUID,
        side: str,
        quantity: Decimal,
        price: Decimal,
    ) -> None:
        """Update strategy_positions with fill data."""
        row = await conn.fetchrow(
            """
            SELECT quantity, avg_entry_price, realized_pnl, cost_basis
            FROM strategy_positions
            WHERE team_id = $1 AND strategy_id = $2 AND instrument_id = $3
            FOR UPDATE
            """,
            team_id, strategy_id, instrument_id,
        )

        if row is None:
            # New position
            signed_qty = quantity if side == "buy" else -quantity
            await conn.execute(
                """
                INSERT INTO strategy_positions (
                    team_id, strategy_id, instrument_id,
                    quantity, avg_entry_price, cost_basis
                ) VALUES ($1, $2, $3, $4, $5, $6)
                """,
                team_id, strategy_id, instrument_id,
                signed_qty, price, abs(signed_qty) * price,
            )
        else:
            current_qty = Decimal(str(row["quantity"]))
            current_avg = Decimal(str(row["avg_entry_price"] or 0))
            current_rpnl = Decimal(str(row["realized_pnl"]))

            signed_qty = quantity if side == "buy" else -quantity
            new_qty = current_qty + signed_qty

            # Determine if this is opening or closing
            is_reducing = (
                (current_qty > 0 and side == "sell") or
                (current_qty < 0 and side == "buy")
            )

            if is_reducing and current_avg > 0:
                # Closing: realize PnL
                reduce_qty = min(abs(signed_qty), abs(current_qty))
                if current_qty > 0:
                    # Was long, selling
                    rpnl = reduce_qty * (price - current_avg)
                else:
                    # Was short, buying
                    rpnl = reduce_qty * (current_avg - price)
                new_rpnl = current_rpnl + rpnl
                new_avg = current_avg if new_qty != 0 else Decimal("0")
            else:
                # Opening or adding: update avg entry
                new_rpnl = current_rpnl
                if abs(new_qty) > 0:
                    total_cost = abs(current_qty) * current_avg + abs(signed_qty) * price
                    new_avg = total_cost / abs(new_qty)
                else:
                    new_avg = Decimal("0")

            new_cost = abs(new_qty) * new_avg

            await conn.execute(
                """
                UPDATE strategy_positions SET
                    quantity = $4,
                    avg_entry_price = $5,
                    realized_pnl = $6,
                    cost_basis = $7,
                    updated_at = NOW()
                WHERE team_id = $1 AND strategy_id = $2 AND instrument_id = $3
                """,
                team_id, strategy_id, instrument_id,
                new_qty, new_avg, new_rpnl, new_cost,
            )

    async def _update_cash_ledger(
        self,
        conn: Any,
        team_id: str,
        fill_id: uuid.UUID,
        side: str,
        quantity: Decimal,
        price: Decimal,
        fee: Decimal,
    ) -> None:
        """Record settlement and fee entries in cash ledger."""
        notional = quantity * price

        # Settlement
        if side == "buy":
            amount = -notional  # cash out
        else:
            amount = notional  # cash in

        await conn.execute(
            """
            INSERT INTO cash_ledger (entry_id, team_id, entry_type, amount, reference_id, reference_type)
            VALUES ($1, $2, 'settlement', $3, $4, 'fill')
            """,
            uuid.uuid4(), team_id, amount, fill_id,
        )

        # Fee
        if fee > 0:
            await conn.execute(
                """
                INSERT INTO cash_ledger (entry_id, team_id, entry_type, amount, reference_id, reference_type)
                VALUES ($1, $2, 'fee', $3, $4, 'fill')
                """,
                uuid.uuid4(), team_id, -fee, fill_id,
            )

    async def _update_order_states(
        self,
        conn: Any,
        order_intent_id: uuid.UUID,
        venue_order_id: uuid.UUID | None,
        fill_qty: Decimal,
    ) -> None:
        """Update parent intent and venue order based on fill."""
        # Check total filled vs requested on parent
        row = await conn.fetchrow(
            """
            SELECT requested_qty, current_state,
                   COALESCE((SELECT SUM(quantity) FROM fills WHERE order_intent_id = $1), 0) as total_filled
            FROM order_intents WHERE order_intent_id = $1
            """,
            order_intent_id,
        )
        if not row:
            return

        total_filled = Decimal(str(row["total_filled"]))
        requested = Decimal(str(row["requested_qty"]))
        current_state = row["current_state"]

        if total_filled >= requested:
            new_state = "filled"
        else:
            new_state = "partially_filled"

        if current_state != new_state and current_state not in ("filled", "canceled", "rejected"):
            await conn.execute(
                "UPDATE order_intents SET current_state = $1, updated_at = NOW() WHERE order_intent_id = $2",
                new_state, order_intent_id,
            )

        # Update venue order if specified
        if venue_order_id:
            vo_row = await conn.fetchrow(
                "SELECT requested_qty, filled_qty FROM venue_orders WHERE venue_order_id_internal = $1",
                venue_order_id,
            )
            if vo_row:
                new_filled = Decimal(str(vo_row["filled_qty"])) + fill_qty
                vo_requested = Decimal(str(vo_row["requested_qty"]))
                vo_state = "filled" if new_filled >= vo_requested else "partially_filled"

                await conn.execute(
                    """
                    UPDATE venue_orders SET
                        filled_qty = $1, remaining_qty = requested_qty - $1,
                        current_state = $2, updated_at = NOW()
                    WHERE venue_order_id_internal = $3
                    """,
                    new_filled, vo_state, venue_order_id,
                )
