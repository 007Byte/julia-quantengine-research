"""
Smart Order Router — venue selection and order slicing.

Responsibilities:
- Select best venue for an order based on:
  - Liquidity / spread
  - Fee structure
  - Venue health / connectivity
  - Concentration limits
- Slice large orders across venues (TWAP/VWAP-style)
- Handle venue failover
"""

from __future__ import annotations

import logging
from decimal import Decimal
from typing import Any

from src.core.instrument_master import InstrumentMaster
from src.execution.base_adapter import BaseAdapter, ConnectionState
from src.monitoring.execution_metrics import ExecutionMetrics

logger = logging.getLogger(__name__)


class VenueScore:
    """Score for a venue on a given instrument."""

    def __init__(self, venue: str, score: float, reasons: list[str]) -> None:
        self.venue = venue
        self.score = score
        self.reasons = reasons


class SmartRouter:
    """
    Routes orders to the best available venue.

    Phase 5: supports multi-venue execution with slicing.
    Earlier phases: single-venue with failover awareness.
    """

    def __init__(
        self,
        adapters: dict[str, BaseAdapter],
        instrument_master: InstrumentMaster,
        metrics: ExecutionMetrics,
    ) -> None:
        self._adapters = adapters
        self._im = instrument_master
        self._metrics = metrics

    def select_venue(
        self,
        instrument_id: str,
        side: str,
        quantity: Decimal,
    ) -> str | None:
        """
        Select the best venue for this order.

        Scoring factors:
        1. Venue is connected
        2. Instrument is mapped to the venue
        3. Execution quality is acceptable
        4. Fee structure
        """
        import uuid
        iid = uuid.UUID(instrument_id) if isinstance(instrument_id, str) else instrument_id

        scores: list[VenueScore] = []

        for venue, adapter in self._adapters.items():
            reasons = []
            score = 0.0

            # Must be connected
            if adapter.connection_state != ConnectionState.CONNECTED:
                continue

            # Must have mapping
            sym = self._im.get_venue_symbol(iid, venue)
            if not sym:
                continue

            score += 50.0  # base score for being available
            reasons.append("available")

            # Execution quality bonus
            if self._metrics.is_quality_acceptable(venue):
                score += 30.0
                reasons.append("quality_ok")
            else:
                score -= 20.0
                reasons.append("quality_degraded")

            # Fill rate bonus
            fill_rate = self._metrics.get_fill_rate(venue)
            if fill_rate > 0.9:
                score += 10.0
            elif fill_rate > 0:
                score += fill_rate * 10

            # Slippage penalty
            slip = self._metrics.get_slippage_stats(venue)
            if slip["count"] > 0:
                score -= min(slip["mean_bps"], 20.0)

            scores.append(VenueScore(venue, score, reasons))

        if not scores:
            logger.warning("No available venue for %s", instrument_id)
            return None

        scores.sort(key=lambda s: s.score, reverse=True)
        best = scores[0]
        logger.debug("Route %s -> %s (score=%.1f: %s)", instrument_id, best.venue, best.score, best.reasons)
        return best.venue

    def compute_slices(
        self,
        quantity: Decimal,
        max_slice_pct: Decimal = Decimal("0.25"),
        min_slices: int = 1,
    ) -> list[Decimal]:
        """
        Compute order slices for TWAP/VWAP-style execution.

        For Phase 5: splits large orders into time-distributed slices.
        """
        max_slice = quantity * max_slice_pct
        if quantity <= max_slice or min_slices <= 1:
            return [quantity]

        n_slices = max(min_slices, int(quantity / max_slice) + 1)
        base_qty = quantity / Decimal(str(n_slices))
        slices = [base_qty] * n_slices

        # Distribute remainder to first slice
        remainder = quantity - sum(slices)
        if remainder > 0:
            slices[0] += remainder

        return slices

    def get_available_venues(self, instrument_id: str) -> list[str]:
        """List venues where this instrument can be traded."""
        import uuid
        iid = uuid.UUID(instrument_id) if isinstance(instrument_id, str) else instrument_id

        available = []
        for venue, adapter in self._adapters.items():
            if adapter.connection_state != ConnectionState.CONNECTED:
                continue
            if self._im.get_venue_symbol(iid, venue):
                available.append(venue)
        return available
