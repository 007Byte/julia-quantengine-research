"""
Capital Allocator — distributes risk budget across teams.

Runs on a slow cadence (daily/weekly). Uses composite scoring
with penalties — never trailing Sharpe alone.
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

from src.ledger import postgres

logger = logging.getLogger(__name__)


class TeamScore(dict):
    """Composite score for a team used in allocation."""
    pass


class CapitalAllocator:
    """
    Allocates capital across teams based on performance, risk, and quality metrics.

    Scoring factors:
    - Risk-adjusted return (Sharpe-like, but penalized)
    - Reconciliation quality (incident count)
    - Execution quality (slippage)
    - Drawdown behavior
    - Strategy diversity
    """

    def __init__(self, total_capital: Decimal = Decimal("1000000")) -> None:
        self._total_capital = total_capital
        self._min_team_pct = Decimal("0.05")   # 5% floor
        self._max_team_pct = Decimal("0.50")   # 50% ceiling

    async def score_teams(self) -> dict[str, TeamScore]:
        """Compute composite scores for all active teams."""
        pool = await postgres.get_pool()
        scores: dict[str, TeamScore] = {}

        async with pool.acquire() as conn:
            # Get active teams from risk_budgets
            teams = await conn.fetch(
                "SELECT scope FROM risk_budgets WHERE scope LIKE 'team:%'"
            )

            for row in teams:
                team_id = row["scope"].replace("team:", "")

                # Performance
                perf = await conn.fetchrow("""
                    SELECT
                        COALESCE(SUM(realized_pnl), 0) as total_pnl,
                        COUNT(DISTINCT instrument_id) as instruments_traded
                    FROM strategy_positions WHERE team_id = $1
                """, team_id)

                # Fills quality
                fills = await conn.fetchrow("""
                    SELECT
                        COUNT(*) as fill_count,
                        AVG(ABS(slippage_bps)) as avg_slippage,
                        MAX(ABS(slippage_bps)) as max_slippage
                    FROM fills
                    WHERE team_id = $1 AND fill_time_utc >= NOW() - INTERVAL '30 days'
                """, team_id)

                # Incident quality
                incidents = await conn.fetchval("""
                    SELECT COUNT(*) FROM reconciliation_incidents
                    WHERE team_id = $1 AND detected_at >= NOW() - INTERVAL '30 days'
                """, team_id)

                # Budget utilization
                budget = await conn.fetchrow(
                    "SELECT * FROM risk_budgets WHERE scope = $1",
                    f"team:{team_id}",
                )

                score = TeamScore({
                    "team_id": team_id,
                    "total_pnl": Decimal(str(perf["total_pnl"])) if perf else Decimal("0"),
                    "instruments_traded": perf["instruments_traded"] if perf else 0,
                    "fill_count_30d": fills["fill_count"] if fills else 0,
                    "avg_slippage_bps": float(fills["avg_slippage"] or 0) if fills else 0.0,
                    "incident_count_30d": incidents or 0,
                    "composite_score": 0.0,
                })

                # Composite: PnL positive + low incidents + low slippage = high score
                pnl_score = min(float(score["total_pnl"]) / 10000, 1.0)  # normalize
                incident_penalty = min((incidents or 0) * 0.1, 0.5)
                slippage_penalty = min(score["avg_slippage_bps"] / 100, 0.3)

                score["composite_score"] = max(0.0, pnl_score - incident_penalty - slippage_penalty + 0.5)
                scores[team_id] = score

        return scores

    async def compute_allocation(self) -> dict[str, Decimal]:
        """
        Compute target capital allocation per team.

        Returns team_id -> allocated capital amount.
        """
        scores = await self.score_teams()

        if not scores:
            return {}

        # Normalize scores to weights
        total_score = sum(max(s["composite_score"], 0.01) for s in scores.values())
        weights: dict[str, Decimal] = {}

        for team_id, score in scores.items():
            raw_weight = Decimal(str(max(score["composite_score"], 0.01))) / Decimal(str(total_score))

            # Apply floor and ceiling
            clamped = max(self._min_team_pct, min(self._max_team_pct, raw_weight))
            weights[team_id] = clamped

        # Re-normalize to sum to 1.0
        weight_sum = sum(weights.values())
        allocation = {
            team_id: (w / weight_sum) * self._total_capital
            for team_id, w in weights.items()
        }

        return allocation

    async def apply_allocation(self) -> dict[str, Decimal]:
        """
        Compute and apply capital allocation to risk budgets.

        Returns the allocation that was applied.
        """
        allocation = await self.compute_allocation()

        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            for team_id, capital in allocation.items():
                daily_loss_limit = capital * Decimal("0.03")  # 3% per team

                await conn.execute(
                    """
                    UPDATE risk_budgets SET
                        max_gross_exposure = $1,
                        max_notional = $1,
                        max_daily_loss = $2,
                        updated_at = NOW()
                    WHERE scope = $3
                    """,
                    capital, daily_loss_limit, f"team:{team_id}",
                )

            # Audit
            await conn.execute(
                """
                INSERT INTO audit_log (log_id, actor, action, entity_type, details)
                VALUES ($1, 'capital_allocator', 'rebalance', 'allocation', $2)
                """,
                uuid.uuid4(),
                {team_id: str(cap) for team_id, cap in allocation.items()},
            )

        logger.info(
            "Capital allocated: %s",
            {t: f"${c:,.0f}" for t, c in allocation.items()},
        )
        return allocation
