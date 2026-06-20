"""
Factor Exposure Model — cross-team concentration risk.

Per Section 8.4: cross-team risk must work on factor exposures,
not just pairwise historical correlations.

Factors:
- crypto_beta: exposure to BTC/crypto market
- usd_exposure: USD-denominated exposure
- growth_beta: sensitivity to growth stocks
- rates_sensitivity: interest rate exposure
- event_overlap: prediction/event market correlation
- sector: GICS sector buckets
"""

from __future__ import annotations

import logging
import uuid
from decimal import Decimal
from typing import Any

from src.ledger import postgres

logger = logging.getLogger(__name__)

# Canonical factor names
FACTORS = [
    "crypto_beta",
    "usd_exposure",
    "growth_beta",
    "value_beta",
    "rates_sensitivity",
    "event_overlap",
    "vol_sensitivity",
    "momentum",
]


class InstrumentFactors:
    """Factor loadings for a single instrument."""

    def __init__(
        self,
        instrument_id: uuid.UUID,
        loadings: dict[str, float],
    ) -> None:
        self.instrument_id = instrument_id
        self.loadings = loadings

    def get(self, factor: str) -> float:
        return self.loadings.get(factor, 0.0)


class FactorExposureModel:
    """
    Tracks and enforces factor-level concentration across all teams.

    Computes:
    - Per-factor gross exposure across all positions
    - Factor concentration vs limits
    - Cross-team overlap detection
    """

    def __init__(self) -> None:
        self._instrument_factors: dict[uuid.UUID, InstrumentFactors] = {}
        self._factor_limits: dict[str, Decimal] = {
            "crypto_beta": Decimal("500000"),
            "usd_exposure": Decimal("1000000"),
            "growth_beta": Decimal("300000"),
            "value_beta": Decimal("300000"),
            "rates_sensitivity": Decimal("200000"),
            "event_overlap": Decimal("100000"),
            "vol_sensitivity": Decimal("200000"),
            "momentum": Decimal("300000"),
        }

    def register_instrument_factors(
        self,
        instrument_id: uuid.UUID,
        loadings: dict[str, float],
    ) -> None:
        """Register factor loadings for an instrument."""
        self._instrument_factors[instrument_id] = InstrumentFactors(instrument_id, loadings)

    def set_factor_limit(self, factor: str, limit: Decimal) -> None:
        self._factor_limits[factor] = limit

    async def compute_factor_exposures(self) -> dict[str, dict[str, Decimal]]:
        """
        Compute current factor exposures across all teams.

        Returns:
            {factor: {team_id: exposure}} for each factor
        """
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            positions = await conn.fetch("""
                SELECT team_id, instrument_id, quantity, avg_entry_price
                FROM strategy_positions
                WHERE quantity != 0
            """)

        exposures: dict[str, dict[str, Decimal]] = {f: {} for f in FACTORS}

        for pos in positions:
            iid = pos["instrument_id"]
            team = pos["team_id"]
            notional = abs(Decimal(str(pos["quantity"])) * Decimal(str(pos["avg_entry_price"] or 0)))

            factors = self._instrument_factors.get(iid)
            if not factors:
                continue

            for factor_name in FACTORS:
                loading = Decimal(str(factors.get(factor_name)))
                factor_exposure = notional * loading
                exposures[factor_name].setdefault(team, Decimal("0"))
                exposures[factor_name][team] += factor_exposure

        return exposures

    async def check_factor_limits(self) -> list[dict[str, Any]]:
        """
        Check all factor exposures against limits.

        Returns list of breaches: [{factor, total_exposure, limit, teams}]
        """
        exposures = await self.compute_factor_exposures()
        breaches = []

        for factor, team_exposures in exposures.items():
            total = sum(abs(v) for v in team_exposures.values())
            limit = self._factor_limits.get(factor, Decimal("1000000"))

            if total > limit:
                breaches.append({
                    "factor": factor,
                    "total_exposure": total,
                    "limit": limit,
                    "utilization_pct": float(total / limit * 100),
                    "teams": {t: str(v) for t, v in team_exposures.items()},
                })

        if breaches:
            logger.warning("Factor limit breaches: %d", len(breaches))
            for b in breaches:
                logger.warning(
                    "  %s: %s / %s (%.0f%%)",
                    b["factor"], b["total_exposure"], b["limit"], b["utilization_pct"],
                )

        return breaches

    async def get_marginal_factor_impact(
        self,
        instrument_id: uuid.UUID,
        notional: Decimal,
    ) -> dict[str, dict[str, Any]]:
        """
        Compute the marginal factor impact of a proposed trade.

        Used by risk gate to check if a new trade would breach factor limits.
        """
        factors = self._instrument_factors.get(instrument_id)
        if not factors:
            return {}

        current_exposures = await self.compute_factor_exposures()
        impact: dict[str, dict[str, Any]] = {}

        for factor_name in FACTORS:
            loading = Decimal(str(factors.get(factor_name)))
            marginal = abs(notional * loading)
            current_total = sum(abs(v) for v in current_exposures.get(factor_name, {}).values())
            new_total = current_total + marginal
            limit = self._factor_limits.get(factor_name, Decimal("1000000"))

            impact[factor_name] = {
                "marginal_exposure": marginal,
                "current_total": current_total,
                "new_total": new_total,
                "limit": limit,
                "would_breach": new_total > limit,
            }

        return impact

    async def get_cross_team_overlap(self) -> list[dict[str, Any]]:
        """
        Detect instruments held by multiple teams.

        Returns list of overlapping positions.
        """
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            rows = await conn.fetch("""
                SELECT instrument_id, array_agg(DISTINCT team_id) as teams,
                       COUNT(DISTINCT team_id) as team_count,
                       SUM(ABS(quantity * COALESCE(avg_entry_price, 0))) as total_notional
                FROM strategy_positions
                WHERE quantity != 0
                GROUP BY instrument_id
                HAVING COUNT(DISTINCT team_id) > 1
            """)

        overlaps = []
        for row in rows:
            overlaps.append({
                "instrument_id": str(row["instrument_id"]),
                "teams": row["teams"],
                "team_count": row["team_count"],
                "total_notional": Decimal(str(row["total_notional"])),
            })

        return overlaps


# Default factor assignments for common instrument types
DEFAULT_FACTORS = {
    "crypto_spot": {"crypto_beta": 1.0, "usd_exposure": 1.0, "vol_sensitivity": 0.8},
    "crypto_perpetual": {"crypto_beta": 1.2, "usd_exposure": 1.0, "vol_sensitivity": 1.0},
    "equity": {"usd_exposure": 1.0, "growth_beta": 0.5, "momentum": 0.3},
    "etf": {"usd_exposure": 1.0, "growth_beta": 0.3},
    "fx_spot": {"usd_exposure": 1.0, "rates_sensitivity": 0.5},
    "prediction": {"event_overlap": 1.0},
}


def get_default_factors(instrument_type: str) -> dict[str, float]:
    """Get default factor loadings for an instrument type."""
    return DEFAULT_FACTORS.get(instrument_type, {"usd_exposure": 1.0})
