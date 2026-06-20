"""
Replay Harness — deterministic replay from persisted events.

Supports:
- Replaying from Redis Streams or Postgres event tables
- Incident reconstruction
- Paper/live outcome comparison
- Bounded time-range replays
"""

from __future__ import annotations

import logging
from datetime import datetime
from decimal import Decimal
from typing import Any

from src.ledger import postgres

logger = logging.getLogger(__name__)


class ReplayHarness:
    """
    Replays historical events through the pipeline for validation.

    Does NOT execute against any venue — purely in-memory.
    """

    def __init__(self, team_id: str) -> None:
        self.team_id = team_id
        self._events: list[dict[str, Any]] = []
        self._fills_replayed: list[dict[str, Any]] = []
        self._signals_replayed: list[dict[str, Any]] = []

    async def load_events(
        self,
        start_time: datetime,
        end_time: datetime,
        event_types: list[str] | None = None,
    ) -> int:
        """Load events from Postgres for replay."""
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            # Load order events
            query = """
                SELECT event_id, order_intent_id, event_type, event_time_utc, payload
                FROM order_events
                WHERE event_time_utc >= $1 AND event_time_utc <= $2
            """
            args: list[Any] = [start_time, end_time]

            if event_types:
                query += " AND event_type = ANY($3)"
                args.append(event_types)

            query += " ORDER BY event_time_utc"

            rows = await conn.fetch(query, *args)
            self._events = [dict(r) for r in rows]

        logger.info(
            "Loaded %d events for replay (%s to %s)",
            len(self._events), start_time, end_time,
        )
        return len(self._events)

    async def load_fills(
        self,
        start_time: datetime,
        end_time: datetime,
    ) -> int:
        """Load fills for comparison."""
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            rows = await conn.fetch("""
                SELECT * FROM fills
                WHERE fill_time_utc >= $1 AND fill_time_utc <= $2
                AND team_id = $3
                ORDER BY fill_time_utc
            """, start_time, end_time, self.team_id)
            self._fills_replayed = [dict(r) for r in rows]

        logger.info("Loaded %d fills for replay", len(self._fills_replayed))
        return len(self._fills_replayed)

    async def replay(self) -> ReplayResult:
        """
        Replay loaded events and compute metrics.

        Returns replay statistics for comparison.
        """
        result = ReplayResult()

        for event in self._events:
            event_type = event.get("event_type", "")

            if "fill" in event_type:
                result.fill_count += 1
            elif "risk" in event_type:
                result.risk_decision_count += 1
            elif "signal" in event_type:
                result.signal_count += 1
            elif "intent" in event_type:
                result.intent_count += 1

            result.total_events += 1

        # Compute fill metrics
        for fill in self._fills_replayed:
            qty = Decimal(str(fill.get("quantity", 0)))
            price = Decimal(str(fill.get("price", 0)))
            fee = Decimal(str(fill.get("fee", 0)))
            side = fill.get("side", "buy")

            notional = qty * price
            result.total_volume += notional
            result.total_fees += fee

            if fill.get("slippage_bps"):
                result.slippage_samples.append(float(fill["slippage_bps"]))

        logger.info(
            "Replay complete: %d events, %d fills, volume=%s",
            result.total_events, result.fill_count, result.total_volume,
        )
        return result

    async def compare_with_live(
        self,
        live_fills: list[dict[str, Any]],
    ) -> dict[str, Any]:
        """
        Compare replay fills with live fills for parity check.

        Returns divergence metrics.
        """
        replay_by_intent: dict[str, list[dict]] = {}
        for f in self._fills_replayed:
            key = str(f.get("order_intent_id", ""))
            replay_by_intent.setdefault(key, []).append(f)

        live_by_intent: dict[str, list[dict]] = {}
        for f in live_fills:
            key = str(f.get("order_intent_id", ""))
            live_by_intent.setdefault(key, []).append(f)

        matched = 0
        diverged = 0
        missing_in_live = 0
        missing_in_replay = 0

        all_keys = set(replay_by_intent.keys()) | set(live_by_intent.keys())
        for key in all_keys:
            r_fills = replay_by_intent.get(key, [])
            l_fills = live_by_intent.get(key, [])

            if r_fills and not l_fills:
                missing_in_live += 1
            elif l_fills and not r_fills:
                missing_in_replay += 1
            elif len(r_fills) == len(l_fills):
                matched += 1
            else:
                diverged += 1

        return {
            "matched": matched,
            "diverged": diverged,
            "missing_in_live": missing_in_live,
            "missing_in_replay": missing_in_replay,
            "total_intents": len(all_keys),
            "parity_pct": matched / max(len(all_keys), 1) * 100,
        }


class ReplayResult:
    """Container for replay metrics."""

    def __init__(self) -> None:
        self.total_events = 0
        self.signal_count = 0
        self.risk_decision_count = 0
        self.intent_count = 0
        self.fill_count = 0
        self.total_volume = Decimal("0")
        self.total_fees = Decimal("0")
        self.slippage_samples: list[float] = []

    @property
    def avg_slippage_bps(self) -> float:
        if not self.slippage_samples:
            return 0.0
        return sum(self.slippage_samples) / len(self.slippage_samples)

    @property
    def max_slippage_bps(self) -> float:
        return max(self.slippage_samples) if self.slippage_samples else 0.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "total_events": self.total_events,
            "signal_count": self.signal_count,
            "risk_decision_count": self.risk_decision_count,
            "intent_count": self.intent_count,
            "fill_count": self.fill_count,
            "total_volume": str(self.total_volume),
            "total_fees": str(self.total_fees),
            "avg_slippage_bps": self.avg_slippage_bps,
            "max_slippage_bps": self.max_slippage_bps,
        }
