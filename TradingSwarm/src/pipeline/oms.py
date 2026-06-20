"""
Order Management System — parent/child order model.

Responsibilities:
- Accept only risk-approved order intents
- Maintain canonical order state machine
- Translate parent intents into child venue orders
- Process fills/cancels/rejects
- Detect orphaned or stale working orders
- Survive restart and resume safely

All state transitions are DB-first + outbox.
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

from src.core.event_schema import (
    Fill,
    OrderEvent,
    OrderIntent,
    OrderIntentState,
    StreamEnvelope,
    VenueOrder,
    VenueOrderState,
)
from src.ledger import outbox, postgres

logger = logging.getLogger(__name__)

# Valid parent intent state transitions
INTENT_TRANSITIONS: dict[OrderIntentState, set[OrderIntentState]] = {
    OrderIntentState.INTENT_CREATED: {OrderIntentState.RISK_PENDING},
    OrderIntentState.RISK_PENDING: {
        OrderIntentState.RISK_APPROVED,
        OrderIntentState.REJECTED,
    },
    OrderIntentState.RISK_APPROVED: {OrderIntentState.RESERVING_BUDGET},
    OrderIntentState.RESERVING_BUDGET: {
        OrderIntentState.ACCEPTED_BY_OMS,
        OrderIntentState.REJECTED,
    },
    OrderIntentState.ACCEPTED_BY_OMS: {OrderIntentState.ROUTING},
    OrderIntentState.ROUTING: {
        OrderIntentState.WORKING,
        OrderIntentState.REJECTED,
        OrderIntentState.CANCELED,
    },
    OrderIntentState.WORKING: {
        OrderIntentState.PARTIALLY_FILLED,
        OrderIntentState.FILLED,
        OrderIntentState.CANCELED,
        OrderIntentState.SUSPENDED,
    },
    OrderIntentState.PARTIALLY_FILLED: {
        OrderIntentState.PARTIALLY_FILLED,
        OrderIntentState.FILLED,
        OrderIntentState.CANCELED,
        OrderIntentState.SUSPENDED,
    },
    OrderIntentState.SUSPENDED: {
        OrderIntentState.WORKING,
        OrderIntentState.CANCELED,
    },
}

# Valid child venue order state transitions
VENUE_ORDER_TRANSITIONS: dict[VenueOrderState, set[VenueOrderState]] = {
    VenueOrderState.CHILD_CREATED: {VenueOrderState.SUBMITTED},
    VenueOrderState.SUBMITTED: {
        VenueOrderState.ACKNOWLEDGED,
        VenueOrderState.REJECTED,
        VenueOrderState.UNKNOWN_BUT_OPEN,
    },
    VenueOrderState.ACKNOWLEDGED: {
        VenueOrderState.PARTIALLY_FILLED,
        VenueOrderState.FILLED,
        VenueOrderState.CANCEL_REQUESTED,
        VenueOrderState.CANCELED,
        VenueOrderState.EXPIRED,
    },
    VenueOrderState.PARTIALLY_FILLED: {
        VenueOrderState.PARTIALLY_FILLED,
        VenueOrderState.FILLED,
        VenueOrderState.CANCEL_REQUESTED,
        VenueOrderState.CANCELED,
    },
    VenueOrderState.CANCEL_REQUESTED: {
        VenueOrderState.CANCELED,
        VenueOrderState.FILLED,
        VenueOrderState.PARTIALLY_FILLED,
    },
    VenueOrderState.UNKNOWN_BUT_OPEN: {
        VenueOrderState.ACKNOWLEDGED,
        VenueOrderState.FILLED,
        VenueOrderState.CANCELED,
        VenueOrderState.REJECTED,
    },
}


class OrderManagementSystem:
    """
    Parent/child OMS with DB-first state persistence.

    All mutations go through:
    1. Validate state transition
    2. Write to Postgres (+ outbox) in a transaction
    3. Publish via outbox worker
    """

    def __init__(self) -> None:
        self._frozen = True  # frozen until reconciliation passes

    @property
    def is_frozen(self) -> bool:
        return self._frozen

    def unfreeze(self) -> None:
        logger.info("OMS unfrozen — trading enabled")
        self._frozen = False

    def freeze(self, reason: str = "") -> None:
        logger.warning("OMS frozen: %s", reason or "manual freeze")
        self._frozen = True

    # ---- Parent intent operations ----

    async def accept_intent(self, intent: OrderIntent) -> OrderIntent:
        """
        Accept a risk-approved order intent into the OMS.
        Deduplicates on idempotency_key.
        """
        if self._frozen:
            raise RuntimeError("OMS is frozen — no new orders until reconciliation passes")

        if intent.current_state != OrderIntentState.RISK_APPROVED:
            raise ValueError(
                f"OMS only accepts risk_approved intents, got {intent.current_state}"
            )

        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            # Dedupe check
            existing = await conn.fetchrow(
                "SELECT order_intent_id, current_state FROM order_intents WHERE idempotency_key = $1",
                intent.idempotency_key,
            )
            if existing:
                logger.info("Duplicate intent: %s", intent.idempotency_key)
                intent.order_intent_id = existing["order_intent_id"]
                intent.current_state = OrderIntentState(existing["current_state"])
                return intent

            intent.current_state = OrderIntentState.ACCEPTED_BY_OMS
            intent.updated_at = datetime.now(timezone.utc)

            async with conn.transaction():
                await conn.execute(
                    """
                    INSERT INTO order_intents (
                        order_intent_id, idempotency_key, team_id, strategy_id,
                        instrument_id, venue_preference, side, intent_type,
                        requested_qty, limit_price, stop_price, time_in_force,
                        signal_id, correlation_id, model_version, feature_version,
                        config_hash, current_state
                    ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18)
                    """,
                    intent.order_intent_id, intent.idempotency_key,
                    intent.team_id, intent.strategy_id,
                    intent.instrument_id, intent.venue_preference,
                    intent.side.value, intent.intent_type.value,
                    intent.requested_qty, intent.limit_price,
                    intent.stop_price, intent.time_in_force.value,
                    intent.signal_id, intent.correlation_id,
                    intent.model_version, intent.feature_version,
                    intent.config_hash, intent.current_state.value,
                )

                envelope = StreamEnvelope.wrap(
                    "order_intent.accepted",
                    intent,
                    idempotency_key=intent.idempotency_key,
                )
                await outbox.write_with_outbox(
                    conn,
                    "SELECT 1",  # no additional business SQL needed
                    (),
                    "oms.intents",
                    envelope,
                )

        logger.info(
            "Intent accepted: %s [%s %s %s]",
            intent.order_intent_id, intent.side.value,
            intent.requested_qty, intent.instrument_id,
        )
        return intent

    async def transition_intent(
        self,
        order_intent_id: uuid.UUID,
        new_state: OrderIntentState,
        event_type: str = "",
        payload: dict[str, Any] | None = None,
    ) -> None:
        """Transition a parent intent to a new state with validation."""
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT current_state FROM order_intents WHERE order_intent_id = $1 FOR UPDATE",
                order_intent_id,
            )
            if row is None:
                raise ValueError(f"Unknown order intent: {order_intent_id}")

            current = OrderIntentState(row["current_state"])
            allowed = INTENT_TRANSITIONS.get(current, set())
            if new_state not in allowed:
                raise ValueError(
                    f"Invalid transition: {current} -> {new_state} "
                    f"(allowed: {allowed})"
                )

            now = datetime.now(timezone.utc)
            async with conn.transaction():
                await conn.execute(
                    "UPDATE order_intents SET current_state = $1, updated_at = $2 WHERE order_intent_id = $3",
                    new_state.value, now, order_intent_id,
                )

                event = OrderEvent(
                    order_intent_id=order_intent_id,
                    event_type=event_type or f"intent.{new_state.value}",
                    event_time_utc=now,
                    payload=payload or {},
                )
                await conn.execute(
                    """
                    INSERT INTO order_events (event_id, order_intent_id, event_type, event_time_utc, payload)
                    VALUES ($1, $2, $3, $4, $5)
                    """,
                    event.event_id, order_intent_id,
                    event.event_type, event.event_time_utc,
                    event.payload,
                )

        logger.info("Intent %s: %s -> %s", order_intent_id, current.value, new_state.value)

    # ---- Child venue order operations ----

    async def create_child_order(
        self,
        order_intent_id: uuid.UUID,
        venue: str,
        requested_qty: Decimal,
        limit_price: Decimal | None = None,
    ) -> VenueOrder:
        """Create a child venue order for a parent intent."""
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            # Get next child sequence
            max_seq = await conn.fetchval(
                "SELECT COALESCE(MAX(child_seq), 0) FROM venue_orders WHERE order_intent_id = $1",
                order_intent_id,
            )
            child_seq = (max_seq or 0) + 1

            child = VenueOrder(
                order_intent_id=order_intent_id,
                venue=venue,
                child_seq=child_seq,
                requested_qty=requested_qty,
                remaining_qty=requested_qty,
                limit_price=limit_price,
            )

            await conn.execute(
                """
                INSERT INTO venue_orders (
                    venue_order_id_internal, order_intent_id, venue, child_seq,
                    current_state, requested_qty, remaining_qty, limit_price
                ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
                """,
                child.venue_order_id_internal, order_intent_id,
                venue, child_seq,
                child.current_state.value, requested_qty,
                requested_qty, limit_price,
            )

        logger.info(
            "Child order created: %s (parent=%s, seq=%d, venue=%s)",
            child.venue_order_id_internal, order_intent_id, child_seq, venue,
        )
        return child

    async def transition_venue_order(
        self,
        venue_order_id: uuid.UUID,
        new_state: VenueOrderState,
        broker_order_id: str | None = None,
        filled_qty: Decimal | None = None,
        avg_fill_price: Decimal | None = None,
    ) -> None:
        """Transition a child venue order with validation."""
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            row = await conn.fetchrow(
                "SELECT current_state, order_intent_id FROM venue_orders WHERE venue_order_id_internal = $1 FOR UPDATE",
                venue_order_id,
            )
            if row is None:
                raise ValueError(f"Unknown venue order: {venue_order_id}")

            current = VenueOrderState(row["current_state"])
            allowed = VENUE_ORDER_TRANSITIONS.get(current, set())
            if new_state not in allowed:
                raise ValueError(
                    f"Invalid venue order transition: {current} -> {new_state}"
                )

            now = datetime.now(timezone.utc)
            updates = ["current_state = $1", "updated_at = $2"]
            args: list[Any] = [new_state.value, now]
            idx = 3

            if broker_order_id is not None:
                updates.append(f"broker_order_id = ${idx}")
                args.append(broker_order_id)
                idx += 1
            if filled_qty is not None:
                updates.append(f"filled_qty = ${idx}")
                args.append(filled_qty)
                idx += 1
                updates.append(f"remaining_qty = requested_qty - ${idx}")
                args.append(filled_qty)
                idx += 1
            if avg_fill_price is not None:
                updates.append(f"avg_fill_price = ${idx}")
                args.append(avg_fill_price)
                idx += 1

            args.append(venue_order_id)
            set_clause = ", ".join(updates)
            await conn.execute(
                f"UPDATE venue_orders SET {set_clause} WHERE venue_order_id_internal = ${idx}",
                *args,
            )

            # Log event
            await conn.execute(
                """
                INSERT INTO order_events (
                    event_id, order_intent_id, venue_order_id_internal,
                    event_type, broker_order_id, event_time_utc
                ) VALUES ($1, $2, $3, $4, $5, $6)
                """,
                uuid.uuid4(), row["order_intent_id"], venue_order_id,
                f"venue_order.{new_state.value}", broker_order_id, now,
            )

        logger.info("Venue order %s: %s -> %s", venue_order_id, current.value, new_state.value)

    # ---- Fill processing ----

    async def record_fill(self, fill: Fill) -> None:
        """Record a fill and update parent/child state."""
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            async with conn.transaction():
                # Insert fill
                await conn.execute(
                    """
                    INSERT INTO fills (
                        fill_id, order_intent_id, venue_order_id_internal,
                        instrument_id, team_id, strategy_id, venue, side,
                        quantity, price, fee, fee_currency,
                        expected_fill_price, slippage_bps, fill_time_utc
                    ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15)
                    """,
                    fill.fill_id, fill.order_intent_id,
                    fill.venue_order_id_internal, fill.instrument_id,
                    fill.team_id, fill.strategy_id, fill.venue,
                    fill.side.value, fill.quantity, fill.price,
                    fill.fee, fill.fee_currency,
                    fill.expected_fill_price, fill.slippage_bps,
                    fill.fill_time_utc,
                )

                # Update venue order filled qty
                if fill.venue_order_id_internal:
                    await conn.execute(
                        """
                        UPDATE venue_orders SET
                            filled_qty = filled_qty + $1,
                            remaining_qty = requested_qty - filled_qty - $1,
                            avg_fill_price = $2,
                            updated_at = NOW()
                        WHERE venue_order_id_internal = $3
                        """,
                        fill.quantity, fill.price,
                        fill.venue_order_id_internal,
                    )

                # Outbox for downstream
                envelope = StreamEnvelope.wrap(
                    "fill.recorded", fill,
                    idempotency_key=str(fill.fill_id),
                )
                await outbox.write_with_outbox(
                    conn,
                    "SELECT 1", (),
                    "fills.events", envelope,
                )

        logger.info(
            "Fill recorded: %s [%s %s @ %s on %s]",
            fill.fill_id, fill.side.value, fill.quantity, fill.price, fill.venue,
        )

    # ---- Restart recovery (Section 10.5) ----

    async def load_unfinished(self) -> tuple[list[dict], list[dict]]:
        """Load all unfinished intents and venue orders on restart."""
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            intents = await conn.fetch("""
                SELECT * FROM order_intents
                WHERE current_state NOT IN ('filled', 'canceled', 'rejected', 'expired')
                ORDER BY created_at
            """)
            venue_orders = await conn.fetch("""
                SELECT * FROM venue_orders
                WHERE current_state NOT IN ('filled', 'canceled', 'rejected', 'expired')
                ORDER BY updated_at
            """)

        logger.info(
            "Loaded %d unfinished intents, %d unfinished venue orders",
            len(intents), len(venue_orders),
        )
        return [dict(r) for r in intents], [dict(r) for r in venue_orders]

    async def detect_stale_orders(self, stale_threshold_seconds: int = 300) -> list[dict]:
        """Find orders that have been working too long without update."""
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            rows = await conn.fetch("""
                SELECT * FROM venue_orders
                WHERE current_state IN ('submitted', 'acknowledged', 'unknown_but_open')
                AND updated_at < NOW() - $1 * INTERVAL '1 second'
            """, stale_threshold_seconds)
        if rows:
            logger.warning("Found %d stale venue orders", len(rows))
        return [dict(r) for r in rows]
