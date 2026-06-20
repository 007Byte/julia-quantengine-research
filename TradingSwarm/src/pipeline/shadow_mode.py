"""
Shadow Mode — real market data, no order submission, signal comparison.

Connects to real Binance data feed. Runs the full signal pipeline.
Records what the system WOULD have done. Compares against actual
market outcomes after the fact.

This is the bridge between "architecture works" and "system has edge."

Shadow mode produces:
- Signal log: every signal with direction, strength, timestamp, instrument
- Market outcome log: what actually happened after each signal
- Comparison metrics: hit rate, expected vs actual move, timing quality
- No fills, no orders, no capital at risk
"""

from __future__ import annotations

import asyncio
import logging
import time
import uuid
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import Any

import orjson

from src.core.config import get_config
from src.core.instrument_master import InstrumentMaster
from src.core.julia_bridge import get_bridge
from src.ledger import postgres

logger = logging.getLogger(__name__)


class ShadowSignal:
    """A signal recorded in shadow mode with its market outcome."""

    def __init__(
        self,
        signal_id: str,
        instrument_id: str,
        venue_symbol: str,
        direction: str,
        strength: float,
        price_at_signal: Decimal,
        signal_time: datetime,
    ) -> None:
        self.signal_id = signal_id
        self.instrument_id = instrument_id
        self.venue_symbol = venue_symbol
        self.direction = direction
        self.strength = strength
        self.price_at_signal = price_at_signal
        self.signal_time = signal_time

        # Filled after observation window
        self.price_after_1m: Decimal | None = None
        self.price_after_5m: Decimal | None = None
        self.price_after_15m: Decimal | None = None
        self.price_after_1h: Decimal | None = None
        self.outcome_recorded = False

    @property
    def move_1m_bps(self) -> float | None:
        if self.price_after_1m is None or self.price_at_signal == 0:
            return None
        move = float((self.price_after_1m - self.price_at_signal) / self.price_at_signal * 10000)
        return move if self.direction == "buy" else -move

    @property
    def move_5m_bps(self) -> float | None:
        if self.price_after_5m is None or self.price_at_signal == 0:
            return None
        move = float((self.price_after_5m - self.price_at_signal) / self.price_at_signal * 10000)
        return move if self.direction == "buy" else -move

    @property
    def move_1h_bps(self) -> float | None:
        if self.price_after_1h is None or self.price_at_signal == 0:
            return None
        move = float((self.price_after_1h - self.price_at_signal) / self.price_at_signal * 10000)
        return move if self.direction == "buy" else -move

    @property
    def was_correct_1m(self) -> bool | None:
        m = self.move_1m_bps
        return m > 0 if m is not None else None

    @property
    def was_correct_5m(self) -> bool | None:
        m = self.move_5m_bps
        return m > 0 if m is not None else None

    def to_dict(self) -> dict[str, Any]:
        return {
            "signal_id": self.signal_id,
            "instrument_id": self.instrument_id,
            "venue_symbol": self.venue_symbol,
            "direction": self.direction,
            "strength": self.strength,
            "price_at_signal": str(self.price_at_signal),
            "signal_time": self.signal_time.isoformat(),
            "move_1m_bps": self.move_1m_bps,
            "move_5m_bps": self.move_5m_bps,
            "move_1h_bps": self.move_1h_bps,
            "was_correct_1m": self.was_correct_1m,
            "was_correct_5m": self.was_correct_5m,
        }


class ShadowSession:
    """
    A shadow trading session.

    Connects to real venue data, runs the full Julia signal pipeline,
    but never submits orders. Records signals and compares against
    subsequent price action.
    """

    def __init__(
        self,
        team_id: str = "crypto",
        venue: str = "binance",
        instruments: list[str] | None = None,
    ) -> None:
        self.team_id = team_id
        self.venue = venue
        self._instruments = instruments or ["BTCUSDT", "ETHUSDT"]
        self._signals: list[ShadowSignal] = []
        self._pending_outcomes: list[ShadowSignal] = []
        self._prices: dict[str, Decimal] = {}
        self._price_history: dict[str, list[tuple[float, Decimal]]] = {}
        self._session_start: datetime | None = None
        self._session_id = str(uuid.uuid4())[:8]
        self._bridge = get_bridge()

    @property
    def signal_count(self) -> int:
        return len(self._signals)

    @property
    def signals_with_outcomes(self) -> list[ShadowSignal]:
        return [s for s in self._signals if s.outcome_recorded]

    def record_price(self, symbol: str, price: Decimal) -> None:
        """Record a price tick from the venue."""
        self._prices[symbol] = price
        now = time.time()
        hist = self._price_history.setdefault(symbol, [])
        hist.append((now, price))
        # Keep 2 hours of history
        cutoff = now - 7200
        while hist and hist[0][0] < cutoff:
            hist.pop(0)

    def _get_price_at(self, symbol: str, target_time: float) -> Decimal | None:
        """Get the closest price to a target timestamp."""
        hist = self._price_history.get(symbol, [])
        if not hist:
            return None

        best = None
        best_delta = float("inf")
        for ts, price in hist:
            delta = abs(ts - target_time)
            if delta < best_delta:
                best_delta = delta
                best = price
        # Only return if within 30 seconds of target
        return best if best_delta < 30 else None

    async def process_market_tick(
        self,
        symbol: str,
        prices: list[float],
        volumes: list[float],
        highs: list[float],
        lows: list[float],
    ) -> ShadowSignal | None:
        """
        Run the signal pipeline on real data. Record but do not execute.
        """
        if not self._bridge.is_healthy:
            return None

        current_price = self._prices.get(symbol)
        if current_price is None:
            return None

        # Resolve instrument_id (in shadow mode, use symbol as proxy)
        instrument_id = f"shadow:{symbol}"

        # Call Julia for features + ensemble
        try:
            feature_result = await self._bridge.compute_features(
                instrument_id=instrument_id,
                prices=prices,
                volumes=volumes,
                highs=highs,
                lows=lows,
            )
            if feature_result.get("type") == "error":
                return None

            features = feature_result.get("features", [])
            if not features:
                return None

            ensemble_result = await self._bridge.run_ensemble(
                instrument_id=instrument_id,
                features=[features],
                strategy_id="default",
            )
            if ensemble_result.get("type") == "error":
                return None

            direction = ensemble_result.get("signal_direction", "hold")
            strength = float(ensemble_result.get("signal_strength", 0.0))

            if direction == "hold" or strength < 0.55:
                return None

            # Record the shadow signal
            signal = ShadowSignal(
                signal_id=str(uuid.uuid4()),
                instrument_id=instrument_id,
                venue_symbol=symbol,
                direction=direction,
                strength=strength,
                price_at_signal=current_price,
                signal_time=datetime.now(timezone.utc),
            )
            self._signals.append(signal)
            self._pending_outcomes.append(signal)

            logger.info(
                "SHADOW SIGNAL: %s %s @ %s (strength=%.3f) [session=%s]",
                direction, symbol, current_price, strength, self._session_id,
            )
            return signal

        except Exception:
            logger.exception("Shadow signal processing error")
            return None

    async def update_outcomes(self) -> int:
        """Check pending signals and fill in market outcomes."""
        updated = 0
        now = time.time()
        still_pending = []

        for signal in self._pending_outcomes:
            signal_ts = signal.signal_time.timestamp()
            symbol = signal.venue_symbol

            # 1-minute outcome
            if signal.price_after_1m is None and now - signal_ts >= 60:
                signal.price_after_1m = self._get_price_at(symbol, signal_ts + 60)

            # 5-minute outcome
            if signal.price_after_5m is None and now - signal_ts >= 300:
                signal.price_after_5m = self._get_price_at(symbol, signal_ts + 300)

            # 15-minute outcome
            if signal.price_after_15m is None and now - signal_ts >= 900:
                signal.price_after_15m = self._get_price_at(symbol, signal_ts + 900)

            # 1-hour outcome
            if signal.price_after_1h is None and now - signal_ts >= 3600:
                signal.price_after_1h = self._get_price_at(symbol, signal_ts + 3600)

            # Mark as complete when we have at least 1h outcome
            if signal.price_after_1h is not None:
                signal.outcome_recorded = True
                updated += 1
            elif now - signal_ts < 7200:
                still_pending.append(signal)
            else:
                # Too old, mark with whatever we have
                signal.outcome_recorded = True
                updated += 1

        self._pending_outcomes = still_pending
        return updated

    def get_stats(self) -> dict[str, Any]:
        """Compute aggregate shadow session statistics."""
        completed = self.signals_with_outcomes
        if not completed:
            return {
                "session_id": self._session_id,
                "total_signals": len(self._signals),
                "completed_signals": 0,
                "pending_outcomes": len(self._pending_outcomes),
                "message": "no completed signals yet",
            }

        correct_1m = [s for s in completed if s.was_correct_1m is True]
        correct_5m = [s for s in completed if s.was_correct_5m is True]
        moves_1m = [s.move_1m_bps for s in completed if s.move_1m_bps is not None]
        moves_5m = [s.move_5m_bps for s in completed if s.move_5m_bps is not None]
        moves_1h = [s.move_1h_bps for s in completed if s.move_1h_bps is not None]

        def _stats(values: list[float]) -> dict[str, float]:
            if not values:
                return {"count": 0, "mean": 0, "median": 0, "min": 0, "max": 0}
            s = sorted(values)
            return {
                "count": len(s),
                "mean": sum(s) / len(s),
                "median": s[len(s) // 2],
                "min": s[0],
                "max": s[-1],
            }

        return {
            "session_id": self._session_id,
            "total_signals": len(self._signals),
            "completed_signals": len(completed),
            "pending_outcomes": len(self._pending_outcomes),
            "hit_rate_1m": len(correct_1m) / len(completed) if completed else 0,
            "hit_rate_5m": len(correct_5m) / len(completed) if completed else 0,
            "move_1m_bps": _stats(moves_1m),
            "move_5m_bps": _stats(moves_5m),
            "move_1h_bps": _stats(moves_1h),
            "by_direction": {
                "buy": {
                    "count": len([s for s in completed if s.direction == "buy"]),
                    "hit_rate_5m": (
                        len([s for s in completed if s.direction == "buy" and s.was_correct_5m]) /
                        max(len([s for s in completed if s.direction == "buy"]), 1)
                    ),
                },
                "sell": {
                    "count": len([s for s in completed if s.direction == "sell"]),
                    "hit_rate_5m": (
                        len([s for s in completed if s.direction == "sell" and s.was_correct_5m]) /
                        max(len([s for s in completed if s.direction == "sell"]), 1)
                    ),
                },
            },
        }

    async def persist_signals(self) -> int:
        """Write shadow signals to Postgres for analysis."""
        pool = await postgres.get_pool()
        count = 0
        async with pool.acquire() as conn:
            for signal in self._signals:
                await conn.execute("""
                    INSERT INTO audit_log (log_id, actor, action, entity_type, entity_id, details)
                    VALUES ($1, 'shadow_mode', 'shadow_signal', 'shadow_signal', $2, $3)
                    ON CONFLICT DO NOTHING
                """,
                    uuid.uuid4(),
                    signal.signal_id,
                    orjson.dumps(signal.to_dict()).decode(),
                )
                count += 1
        return count

    def print_report(self) -> None:
        """Print a human-readable shadow session report."""
        stats = self.get_stats()
        print(f"\n{'=' * 60}")
        print(f"SHADOW SESSION REPORT — {self._session_id}")
        print(f"{'=' * 60}")
        print(f"Total signals:     {stats['total_signals']}")
        print(f"With outcomes:     {stats['completed_signals']}")
        print(f"Pending:           {stats['pending_outcomes']}")

        if stats["completed_signals"] > 0:
            print(f"\nHit rate (1m):     {stats['hit_rate_1m']:.1%}")
            print(f"Hit rate (5m):     {stats['hit_rate_5m']:.1%}")
            m5 = stats["move_5m_bps"]
            print(f"\n5-min move (bps):  mean={m5['mean']:.1f}  median={m5['median']:.1f}  "
                  f"min={m5['min']:.1f}  max={m5['max']:.1f}")
            m1h = stats["move_1h_bps"]
            if m1h["count"] > 0:
                print(f"1-hr move (bps):   mean={m1h['mean']:.1f}  median={m1h['median']:.1f}  "
                      f"min={m1h['min']:.1f}  max={m1h['max']:.1f}")

            by_dir = stats["by_direction"]
            print(f"\nBuy signals:       {by_dir['buy']['count']}  hit_rate_5m={by_dir['buy']['hit_rate_5m']:.1%}")
            print(f"Sell signals:      {by_dir['sell']['count']}  hit_rate_5m={by_dir['sell']['hit_rate_5m']:.1%}")
        else:
            print("\nNo completed signals — need more observation time")

        print(f"{'=' * 60}\n")
