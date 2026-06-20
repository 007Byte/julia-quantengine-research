"""
Projection Alignment — ensures team positions roll up correctly to global.

Phase 2 exit criteria: team and global projections must align.

Computes:
- Team-level netted positions from strategy_positions
- Global netted positions from team positions
- Detects mismatches between cached team_positions and live roll-up
- Detects budget counter drift vs actual positions
"""

from __future__ import annotations

import logging
import uuid
from decimal import Decimal
from typing import Any

from src.ledger import postgres

logger = logging.getLogger(__name__)


class ProjectionAlignment:
    """
    Validates that team and global projections are consistent.

    Strategy positions → team positions → global projections
    Risk budget counters → actual positions
    """

    async def check_team_projections(self) -> list[dict[str, Any]]:
        """
        Compare strategy_positions aggregated to team level
        against budget counters.

        Returns list of mismatches.
        """
        pool = await postgres.get_pool()
        mismatches = []

        async with pool.acquire() as conn:
            # Actual position counts per team from strategy_positions
            actual = await conn.fetch("""
                SELECT team_id,
                       COUNT(DISTINCT instrument_id) as position_count,
                       SUM(ABS(quantity * COALESCE(avg_entry_price, 0))) as gross_exposure
                FROM strategy_positions
                WHERE quantity != 0
                GROUP BY team_id
            """)
            actual_by_team = {r["team_id"]: dict(r) for r in actual}

            # Budget counters per team
            budgets = await conn.fetch(
                "SELECT * FROM risk_budgets WHERE scope LIKE 'team:%'"
            )

            for budget in budgets:
                team_id = budget["scope"].replace("team:", "")
                actual_data = actual_by_team.get(team_id)

                actual_count = actual_data["position_count"] if actual_data else 0
                budget_count = budget["current_position_count"]

                actual_gross = Decimal(str(actual_data["gross_exposure"])) if actual_data else Decimal("0")
                budget_gross = Decimal(str(budget["current_gross_exposure"]))

                # Position count mismatch
                if actual_count != budget_count:
                    mismatches.append({
                        "type": "position_count_drift",
                        "team_id": team_id,
                        "actual": actual_count,
                        "budget": budget_count,
                        "delta": actual_count - budget_count,
                    })

                # Gross exposure drift (> 5% tolerance)
                if budget_gross > 0:
                    drift_pct = abs(actual_gross - budget_gross) / budget_gross
                    if drift_pct > Decimal("0.05"):
                        mismatches.append({
                            "type": "gross_exposure_drift",
                            "team_id": team_id,
                            "actual": str(actual_gross),
                            "budget": str(budget_gross),
                            "drift_pct": float(drift_pct * 100),
                        })

        if mismatches:
            logger.warning("Projection alignment: %d mismatches found", len(mismatches))
            for m in mismatches:
                logger.warning("  %s: %s", m["type"], m)
        else:
            logger.info("Projection alignment: all teams consistent")

        return mismatches

    async def check_global_projection(self) -> list[dict[str, Any]]:
        """
        Compare sum of team budgets against global budget.
        """
        pool = await postgres.get_pool()
        mismatches = []

        async with pool.acquire() as conn:
            # Sum of team budgets
            team_totals = await conn.fetchrow("""
                SELECT
                    SUM(current_gross_exposure) as total_gross,
                    SUM(current_position_count) as total_positions
                FROM risk_budgets
                WHERE scope LIKE 'team:%'
            """)

            # Global budget
            global_budget = await conn.fetchrow(
                "SELECT * FROM risk_budgets WHERE scope = 'global'"
            )

            if team_totals and global_budget:
                team_gross = Decimal(str(team_totals["total_gross"] or 0))
                global_gross = Decimal(str(global_budget["current_gross_exposure"]))

                if abs(team_gross - global_gross) > Decimal("1"):
                    mismatches.append({
                        "type": "global_gross_mismatch",
                        "team_sum": str(team_gross),
                        "global": str(global_gross),
                        "delta": str(team_gross - global_gross),
                    })

                team_pos = int(team_totals["total_positions"] or 0)
                global_pos = global_budget["current_position_count"]
                if team_pos != global_pos:
                    mismatches.append({
                        "type": "global_position_count_mismatch",
                        "team_sum": team_pos,
                        "global": global_pos,
                    })

        if mismatches:
            logger.warning("Global projection: %d mismatches", len(mismatches))
        else:
            logger.info("Global projection alignment: consistent")

        return mismatches

    async def repair_counters(self) -> int:
        """
        Repair budget counters to match actual positions.

        Use after reconciliation or as a periodic maintenance task.
        """
        pool = await postgres.get_pool()
        repaired = 0

        async with pool.acquire() as conn:
            async with conn.transaction():
                # Recompute team counters
                actuals = await conn.fetch("""
                    SELECT team_id,
                           COUNT(DISTINCT instrument_id) as pos_count,
                           COALESCE(SUM(ABS(quantity * COALESCE(avg_entry_price, 0))), 0) as gross
                    FROM strategy_positions
                    WHERE quantity != 0
                    GROUP BY team_id
                """)

                for row in actuals:
                    result = await conn.execute("""
                        UPDATE risk_budgets SET
                            current_position_count = $1,
                            current_gross_exposure = $2,
                            current_notional = $2,
                            updated_at = NOW()
                        WHERE scope = $3
                    """, row["pos_count"], row["gross"], f"team:{row['team_id']}")
                    repaired += 1

                # Recompute global from team sums
                await conn.execute("""
                    UPDATE risk_budgets SET
                        current_position_count = (
                            SELECT COALESCE(SUM(current_position_count), 0)
                            FROM risk_budgets WHERE scope LIKE 'team:%'
                        ),
                        current_gross_exposure = (
                            SELECT COALESCE(SUM(current_gross_exposure), 0)
                            FROM risk_budgets WHERE scope LIKE 'team:%'
                        ),
                        current_notional = (
                            SELECT COALESCE(SUM(current_notional), 0)
                            FROM risk_budgets WHERE scope LIKE 'team:%'
                        ),
                        updated_at = NOW()
                    WHERE scope = 'global'
                """)
                repaired += 1

        logger.info("Repaired %d budget counters", repaired)
        return repaired
