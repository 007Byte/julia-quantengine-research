"""
Execution Quality Metrics — slippage, latency, fill rate tracking.

Used for:
- Execution quality deterioration gate (risk control)
- Venue quality comparison
- Performance reporting
"""

from __future__ import annotations

import logging
import math
from collections import deque
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Any

logger = logging.getLogger(__name__)


@dataclass
class FillMetric:
    """Metrics from a single fill."""
    venue: str
    side: str
    expected_price: Decimal
    actual_price: Decimal
    quantity: Decimal
    latency_ms: float
    timestamp: float


class ExecutionMetrics:
    """
    Rolling execution quality tracker.

    Tracks per-venue:
    - Slippage distribution (bps)
    - Fill latency distribution (ms)
    - Fill rate (fills / attempts)
    - Rejection rate
    """

    def __init__(self, window_size: int = 500) -> None:
        self._window = window_size
        self._fills: dict[str, deque[FillMetric]] = {}  # venue -> deque
        self._attempts: dict[str, int] = {}
        self._rejections: dict[str, int] = {}

    def record_fill(self, metric: FillMetric) -> None:
        self._fills.setdefault(metric.venue, deque(maxlen=self._window)).append(metric)

    def record_attempt(self, venue: str) -> None:
        self._attempts[venue] = self._attempts.get(venue, 0) + 1

    def record_rejection(self, venue: str) -> None:
        self._rejections[venue] = self._rejections.get(venue, 0) + 1

    def get_slippage_stats(self, venue: str) -> dict[str, float]:
        """Slippage statistics in bps for a venue."""
        fills = self._fills.get(venue, deque())
        if not fills:
            return {"count": 0, "mean_bps": 0, "median_bps": 0, "p95_bps": 0, "max_bps": 0}

        slippages = []
        for f in fills:
            if f.expected_price > 0:
                slip_bps = float(
                    (f.actual_price - f.expected_price) / f.expected_price * Decimal("10000")
                )
                if f.side == "sell":
                    slip_bps = -slip_bps  # normalize: positive = unfavorable
                slippages.append(slip_bps)

        if not slippages:
            return {"count": 0, "mean_bps": 0, "median_bps": 0, "p95_bps": 0, "max_bps": 0}

        slippages.sort()
        n = len(slippages)
        return {
            "count": n,
            "mean_bps": sum(slippages) / n,
            "median_bps": slippages[n // 2],
            "p95_bps": slippages[int(n * 0.95)] if n >= 20 else slippages[-1],
            "max_bps": slippages[-1],
        }

    def get_latency_stats(self, venue: str) -> dict[str, float]:
        """Latency statistics in ms for a venue."""
        fills = self._fills.get(venue, deque())
        if not fills:
            return {"count": 0, "mean_ms": 0, "median_ms": 0, "p95_ms": 0, "max_ms": 0}

        latencies = sorted(f.latency_ms for f in fills)
        n = len(latencies)
        return {
            "count": n,
            "mean_ms": sum(latencies) / n,
            "median_ms": latencies[n // 2],
            "p95_ms": latencies[int(n * 0.95)] if n >= 20 else latencies[-1],
            "max_ms": latencies[-1],
        }

    def get_fill_rate(self, venue: str) -> float:
        """Fill rate = fills / attempts."""
        attempts = self._attempts.get(venue, 0)
        if attempts == 0:
            return 0.0
        fills = len(self._fills.get(venue, deque()))
        return fills / attempts

    def get_rejection_rate(self, venue: str) -> float:
        """Rejection rate = rejections / attempts."""
        attempts = self._attempts.get(venue, 0)
        if attempts == 0:
            return 0.0
        return self._rejections.get(venue, 0) / attempts

    def is_quality_acceptable(self, venue: str, max_slippage_bps: float = 50.0) -> bool:
        """Gate: is execution quality acceptable for continued trading?"""
        stats = self.get_slippage_stats(venue)
        if stats["count"] < 10:
            return True  # not enough data
        return stats["p95_bps"] < max_slippage_bps

    def summary(self) -> dict[str, Any]:
        """Summary across all venues."""
        result = {}
        for venue in set(list(self._fills.keys()) + list(self._attempts.keys())):
            result[venue] = {
                "slippage": self.get_slippage_stats(venue),
                "latency": self.get_latency_stats(venue),
                "fill_rate": self.get_fill_rate(venue),
                "rejection_rate": self.get_rejection_rate(venue),
                "quality_ok": self.is_quality_acceptable(venue),
            }
        return result
