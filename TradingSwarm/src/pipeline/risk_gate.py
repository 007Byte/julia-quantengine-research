"""
Pre-Trade Risk Gate + Atomic Reservation Ledger.

Risk is INLINE — the signal path blocks on the risk decision.
No async "maybe later" approval.

Approval alone is not enough: scarce budget must be atomically reserved.
Reservation + risk decision happen in a single Postgres transaction.
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import Any

from src.core.config import get_config
from src.core.event_schema import (
    OrderIntent,
    OrderIntentState,
    ReservationStatus,
    RiskDecision,
    RiskDecisionType,
    RiskReservation,
    StreamEnvelope,
)
from src.ledger import outbox, postgres

logger = logging.getLogger(__name__)


class PreTradeRiskGate:
    """
    Synchronous pre-trade risk checker with atomic budget reservation.

    Uses Postgres row-level locks on risk_budgets for race safety.
    """

    def __init__(self) -> None:
        self._cfg = get_config().risk

    async def evaluate(
        self,
        intent: OrderIntent,
        estimated_notional: Decimal,
        estimated_margin: Decimal = Decimal("0"),
    ) -> tuple[RiskDecision, RiskReservation | None]:
        """
        Evaluate an order intent against all risk controls.

        Returns:
            (decision, reservation) — reservation is None if rejected.

        This is the ONLY entry point. Everything is atomic.
        """
        pool = await postgres.get_pool()

        async with pool.acquire() as conn:
            async with conn.transaction():
                # Lock the relevant risk budget rows FOR UPDATE
                # This prevents concurrent approvals from oversubscribing
                global_budget = await conn.fetchrow(
                    "SELECT * FROM risk_budgets WHERE scope = 'global' FOR UPDATE"
                )
                team_budget = await conn.fetchrow(
                    "SELECT * FROM risk_budgets WHERE scope = $1 FOR UPDATE",
                    f"team:{intent.team_id}",
                )

                # --- Run all hard risk checks ---
                rejection = await self._check_hard_limits(
                    conn, intent, estimated_notional, global_budget, team_budget
                )

                if rejection:
                    decision = RiskDecision(
                        order_intent_id=intent.order_intent_id,
                        team_id=intent.team_id,
                        decision=RiskDecisionType.REJECTED,
                        reason=rejection,
                        original_qty=intent.requested_qty,
                        risk_snapshot=self._snapshot(global_budget, team_budget),
                    )
                    await self._persist_decision(conn, decision)
                    logger.warning(
                        "REJECTED %s: %s", intent.order_intent_id, rejection
                    )
                    return decision, None

                # --- Size reduction check ---
                approved_qty = intent.requested_qty
                reduction_reason = await self._check_size_reduction(
                    conn, intent, estimated_notional, global_budget, team_budget
                )
                if reduction_reason:
                    approved_qty = intent.requested_qty / Decimal("2")
                    estimated_notional = estimated_notional / Decimal("2")
                    decision_type = RiskDecisionType.SIZE_REDUCED
                    reason = reduction_reason
                else:
                    decision_type = RiskDecisionType.APPROVED
                    reason = "all checks passed"

                # --- Atomic reservation ---
                reservation = RiskReservation(
                    order_intent_id=intent.order_intent_id,
                    scope="global",
                    reserved_notional=estimated_notional,
                    reserved_gross=estimated_notional,
                    reserved_margin=estimated_margin,
                    expires_at=datetime.now(timezone.utc) + timedelta(
                        seconds=self._cfg.reservation_expiry_seconds
                    ),
                )

                # Debit the budget atomically
                await conn.execute(
                    """
                    UPDATE risk_budgets SET
                        current_gross_exposure = current_gross_exposure + $1,
                        current_notional = current_notional + $2,
                        current_position_count = current_position_count + 1,
                        updated_at = NOW()
                    WHERE scope = 'global'
                    """,
                    estimated_notional, estimated_notional,
                )

                if team_budget:
                    await conn.execute(
                        """
                        UPDATE risk_budgets SET
                            current_gross_exposure = current_gross_exposure + $1,
                            current_notional = current_notional + $2,
                            current_position_count = current_position_count + 1,
                            updated_at = NOW()
                        WHERE scope = $3
                        """,
                        estimated_notional, estimated_notional,
                        f"team:{intent.team_id}",
                    )

                # Persist reservation
                await conn.execute(
                    """
                    INSERT INTO risk_reservations (
                        reservation_id, order_intent_id, scope,
                        reserved_notional, reserved_gross, reserved_margin,
                        status, expires_at
                    ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
                    """,
                    reservation.reservation_id, reservation.order_intent_id,
                    reservation.scope, reservation.reserved_notional,
                    reservation.reserved_gross, reservation.reserved_margin,
                    reservation.status.value, reservation.expires_at,
                )

                # Persist decision
                decision = RiskDecision(
                    order_intent_id=intent.order_intent_id,
                    team_id=intent.team_id,
                    decision=decision_type,
                    reason=reason,
                    original_qty=intent.requested_qty,
                    approved_qty=approved_qty,
                    risk_snapshot=self._snapshot(global_budget, team_budget),
                )
                await self._persist_decision(conn, decision)

                # Outbox for downstream
                envelope = StreamEnvelope.wrap(
                    "risk.decision",
                    decision,
                    idempotency_key=f"risk:{intent.order_intent_id}",
                )
                await outbox.write_with_outbox(
                    conn,
                    "SELECT 1", (),
                    "risk.decisions", envelope,
                )

        logger.info(
            "%s %s: notional=%s, qty=%s -> %s",
            decision_type.value.upper(),
            intent.order_intent_id,
            estimated_notional,
            approved_qty,
            reason,
        )
        return decision, reservation

    async def release_reservation(self, reservation_id: uuid.UUID) -> None:
        """Release a reservation (on reject/cancel/timeout)."""
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            async with conn.transaction():
                row = await conn.fetchrow(
                    "SELECT * FROM risk_reservations WHERE reservation_id = $1 FOR UPDATE",
                    reservation_id,
                )
                if not row or row["status"] != "active":
                    return

                # Credit back to budget
                await conn.execute(
                    """
                    UPDATE risk_budgets SET
                        current_gross_exposure = GREATEST(0, current_gross_exposure - $1),
                        current_notional = GREATEST(0, current_notional - $2),
                        current_position_count = GREATEST(0, current_position_count - 1),
                        updated_at = NOW()
                    WHERE scope = $3
                    """,
                    row["reserved_gross"], row["reserved_notional"],
                    row["scope"],
                )

                await conn.execute(
                    """
                    UPDATE risk_reservations SET
                        status = 'released', released_at = NOW()
                    WHERE reservation_id = $1
                    """,
                    reservation_id,
                )

        logger.info("Released reservation: %s", reservation_id)

    async def expire_stale_reservations(self) -> int:
        """Expire reservations that the OMS never consumed."""
        pool = await postgres.get_pool()
        expired = 0
        async with pool.acquire() as conn:
            rows = await conn.fetch(
                """
                SELECT reservation_id FROM risk_reservations
                WHERE status = 'active' AND expires_at < NOW()
                FOR UPDATE SKIP LOCKED
                """
            )
            for row in rows:
                await self.release_reservation(row["reservation_id"])
                expired += 1

        if expired:
            logger.warning("Expired %d stale reservations", expired)
        return expired

    # ---- Hard limit checks ----

    async def _check_hard_limits(
        self,
        conn: Any,
        intent: OrderIntent,
        notional: Decimal,
        global_budget: Any,
        team_budget: Any,
    ) -> str | None:
        """Returns rejection reason or None if all checks pass."""

        if not global_budget:
            return "no global risk budget configured"

        cfg = self._cfg

        # 1) Global gross exposure cap
        new_gross = Decimal(str(global_budget["current_gross_exposure"])) + notional
        if new_gross > Decimal(str(global_budget["max_gross_exposure"])):
            return f"global gross exposure would exceed cap: {new_gross} > {global_budget['max_gross_exposure']}"

        # 2) Global daily loss
        daily_loss = Decimal(str(global_budget["current_daily_loss"]))
        max_loss = Decimal(str(global_budget["max_daily_loss"]))
        if daily_loss >= max_loss:
            return f"global daily loss limit reached: {daily_loss} >= {max_loss}"

        # 3) Position count
        pos_count = global_budget["current_position_count"]
        max_pos = global_budget["max_position_count"]
        if pos_count >= max_pos:
            return f"position count cap reached: {pos_count} >= {max_pos}"

        # 4) Per-team daily loss
        if team_budget:
            team_loss = Decimal(str(team_budget["current_daily_loss"]))
            team_max = Decimal(str(team_budget["max_daily_loss"]))
            if team_loss >= team_max:
                return f"team daily loss limit: {team_loss} >= {team_max}"

        # 5) Single position cap
        single_cap = Decimal(str(global_budget["max_gross_exposure"])) * Decimal(str(cfg.single_position_cap_pct))
        if notional > single_cap:
            return f"single position exceeds cap: {notional} > {single_cap}"

        return None

    async def _check_size_reduction(
        self,
        conn: Any,
        intent: OrderIntent,
        notional: Decimal,
        global_budget: Any,
        team_budget: Any,
    ) -> str | None:
        """Returns reason for size reduction, or None."""
        if not global_budget:
            return None

        # If approaching 80% of gross cap, reduce size
        max_gross = Decimal(str(global_budget["max_gross_exposure"]))
        current = Decimal(str(global_budget["current_gross_exposure"]))
        utilization = current / max_gross if max_gross > 0 else Decimal("1")

        if utilization > Decimal("0.8"):
            return f"gross utilization at {utilization:.0%}, reducing size"

        return None

    async def _persist_decision(self, conn: Any, decision: RiskDecision) -> None:
        await conn.execute(
            """
            INSERT INTO risk_decisions (
                decision_id, order_intent_id, team_id, decision,
                reason, original_qty, approved_qty, risk_snapshot, decided_at
            ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
            """,
            decision.decision_id, decision.order_intent_id,
            decision.team_id, decision.decision.value,
            decision.reason, decision.original_qty,
            decision.approved_qty, decision.risk_snapshot,
            decision.decided_at,
        )

    def _snapshot(self, global_budget: Any, team_budget: Any) -> dict[str, Any]:
        result: dict[str, Any] = {}
        if global_budget:
            result["global"] = dict(global_budget)
        if team_budget:
            result["team"] = dict(team_budget)
        return result


# ---- Budget initialization ----

async def initialize_risk_budgets(config: Any = None) -> None:
    """Create default risk budget rows if they don't exist."""
    cfg = config or get_config().risk
    pool = await postgres.get_pool()
    async with pool.acquire() as conn:
        await conn.execute(
            """
            INSERT INTO risk_budgets (scope, max_gross_exposure, max_notional, max_daily_loss, max_position_count)
            VALUES ('global', $1, $1, $2, $3)
            ON CONFLICT (scope) DO NOTHING
            """,
            cfg.global_gross_exposure_cap,
            cfg.global_gross_exposure_cap * Decimal(str(cfg.global_max_daily_loss_pct)),
            cfg.position_count_cap,
        )
    logger.info("Risk budgets initialized")
