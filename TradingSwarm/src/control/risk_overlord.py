"""
Risk Overlord — global risk aggregation across all teams.

Responsibilities:
- Aggregate gross exposure, notional, PnL across teams
- Enforce global hard limits (daily loss, drawdown, gross cap)
- Track factor exposures for cross-team concentration
- Auto-trigger kill switch or conservative mode on breach
- Reset daily counters at configurable time
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, time, timezone
from decimal import Decimal
from typing import Any

from src.core.config import get_config
from src.control.kill_switch import get_conservative_mode, get_kill_switch
from src.ledger import postgres

logger = logging.getLogger(__name__)


class RiskOverlord:
    """
    Global risk aggregator — the single authoritative view of platform risk.

    Reads from risk_budgets and strategy_positions to build
    a real-time risk snapshot. Triggers protective actions on breach.
    """

    def __init__(self) -> None:
        self._cfg = get_config().risk
        self._high_water_mark = Decimal("0")
        self._last_daily_reset: datetime | None = None

    async def get_global_snapshot(self) -> dict[str, Any]:
        """Build a complete risk snapshot across all teams."""
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            # Global budget state
            global_budget = await conn.fetchrow(
                "SELECT * FROM risk_budgets WHERE scope = 'global'"
            )

            # Team budgets
            team_budgets = await conn.fetch(
                "SELECT * FROM risk_budgets WHERE scope LIKE 'team:%'"
            )

            # Position summary by team
            position_summary = await conn.fetch("""
                SELECT team_id,
                       COUNT(*) as position_count,
                       SUM(ABS(quantity * COALESCE(avg_entry_price, 0))) as gross_notional,
                       SUM(realized_pnl) as realized_pnl
                FROM strategy_positions
                WHERE quantity != 0
                GROUP BY team_id
            """)

            # Today's fill activity
            fills_today = await conn.fetchrow("""
                SELECT COUNT(*) as fill_count,
                       COALESCE(SUM(quantity * price), 0) as volume,
                       COALESCE(SUM(fee), 0) as total_fees
                FROM fills
                WHERE fill_time_utc >= CURRENT_DATE
            """)

            # Unresolved incidents
            incident_count = await conn.fetchval("""
                SELECT COUNT(*) FROM reconciliation_incidents
                WHERE status != 'resolved'
            """)

            # Active reservations
            active_reservations = await conn.fetchrow("""
                SELECT COUNT(*) as count,
                       COALESCE(SUM(reserved_notional), 0) as total_reserved
                FROM risk_reservations
                WHERE status = 'active'
            """)

        snapshot = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "global_budget": dict(global_budget) if global_budget else {},
            "team_budgets": [dict(r) for r in team_budgets],
            "positions": [dict(r) for r in position_summary],
            "fills_today": dict(fills_today) if fills_today else {},
            "unresolved_incidents": incident_count or 0,
            "active_reservations": dict(active_reservations) if active_reservations else {},
        }

        return snapshot

    async def check_global_limits(self) -> list[str]:
        """
        Check all global hard limits. Returns list of breached limits.
        Any breach triggers protective action.
        """
        breaches: list[str] = []
        pool = await postgres.get_pool()

        async with pool.acquire() as conn:
            budget = await conn.fetchrow(
                "SELECT * FROM risk_budgets WHERE scope = 'global'"
            )
            if not budget:
                return ["no_global_budget_configured"]

            # 1. Gross exposure cap
            current_gross = Decimal(str(budget["current_gross_exposure"]))
            max_gross = Decimal(str(budget["max_gross_exposure"]))
            if current_gross > max_gross:
                breaches.append(
                    f"gross_exposure: {current_gross} > {max_gross}"
                )

            # 2. Daily loss
            current_loss = Decimal(str(budget["current_daily_loss"]))
            max_loss = Decimal(str(budget["max_daily_loss"]))
            if current_loss >= max_loss:
                breaches.append(
                    f"daily_loss: {current_loss} >= {max_loss}"
                )

            # 3. Position count
            pos_count = budget["current_position_count"]
            max_pos = budget["max_position_count"]
            if pos_count > max_pos:
                breaches.append(
                    f"position_count: {pos_count} > {max_pos}"
                )

            # 4. Global drawdown
            total_rpnl = await conn.fetchval(
                "SELECT COALESCE(SUM(realized_pnl), 0) FROM strategy_positions"
            )
            rpnl = Decimal(str(total_rpnl or 0))
            if rpnl > self._high_water_mark:
                self._high_water_mark = rpnl
            drawdown = self._high_water_mark - rpnl
            max_dd = max_gross * Decimal(str(self._cfg.global_max_drawdown_pct))
            if drawdown > max_dd:
                breaches.append(
                    f"drawdown: {drawdown} > {max_dd} (hwm={self._high_water_mark})"
                )

        if breaches:
            await self._handle_breaches(breaches)

        return breaches

    async def check_team_limits(self) -> dict[str, list[str]]:
        """Check per-team limits. Returns team_id -> list of breaches."""
        team_breaches: dict[str, list[str]] = {}
        pool = await postgres.get_pool()

        async with pool.acquire() as conn:
            team_budgets = await conn.fetch(
                "SELECT * FROM risk_budgets WHERE scope LIKE 'team:%'"
            )

            for budget in team_budgets:
                scope = budget["scope"]
                team_id = scope.replace("team:", "")
                issues = []

                current_loss = Decimal(str(budget["current_daily_loss"]))
                max_loss = Decimal(str(budget["max_daily_loss"]))
                if current_loss >= max_loss:
                    issues.append(f"team_daily_loss: {current_loss} >= {max_loss}")

                current_gross = Decimal(str(budget["current_gross_exposure"]))
                max_gross = Decimal(str(budget["max_gross_exposure"]))
                if current_gross > max_gross:
                    issues.append(f"team_gross: {current_gross} > {max_gross}")

                if issues:
                    team_breaches[team_id] = issues
                    ks = get_kill_switch()
                    await ks.activate_team(
                        team_id,
                        f"Risk limit breach: {'; '.join(issues)}",
                        actor="risk_overlord",
                    )

        return team_breaches

    async def update_daily_pnl(self, team_id: str, pnl_delta: Decimal) -> None:
        """Update daily loss tracking for a team."""
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            # Update team budget
            await conn.execute(
                """
                UPDATE risk_budgets
                SET current_daily_loss = current_daily_loss + $1, updated_at = NOW()
                WHERE scope = $2
                """,
                abs(pnl_delta) if pnl_delta < 0 else Decimal("0"),
                f"team:{team_id}",
            )
            # Update global
            await conn.execute(
                """
                UPDATE risk_budgets
                SET current_daily_loss = current_daily_loss + $1, updated_at = NOW()
                WHERE scope = 'global'
                """,
                abs(pnl_delta) if pnl_delta < 0 else Decimal("0"),
            )

    async def reset_daily_counters(self) -> None:
        """Reset daily loss counters — called at start of trading day."""
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            await conn.execute(
                "UPDATE risk_budgets SET current_daily_loss = 0, updated_at = NOW()"
            )
        self._last_daily_reset = datetime.now(timezone.utc)
        logger.info("Daily risk counters reset")

        await postgres.execute(
            """
            INSERT INTO audit_log (log_id, actor, action, entity_type, details)
            VALUES ($1, 'risk_overlord', 'daily_reset', 'risk', '{}')
            """,
            uuid.uuid4(),
        )

    async def initialize_team_budget(
        self,
        team_id: str,
        max_gross: Decimal | None = None,
        max_daily_loss: Decimal | None = None,
        max_positions: int = 20,
    ) -> None:
        """Create or reset a team's risk budget."""
        cfg = self._cfg
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            await conn.execute(
                """
                INSERT INTO risk_budgets (scope, max_gross_exposure, max_notional, max_daily_loss, max_position_count)
                VALUES ($1, $2, $2, $3, $4)
                ON CONFLICT (scope) DO UPDATE SET
                    max_gross_exposure = EXCLUDED.max_gross_exposure,
                    max_notional = EXCLUDED.max_notional,
                    max_daily_loss = EXCLUDED.max_daily_loss,
                    max_position_count = EXCLUDED.max_position_count,
                    updated_at = NOW()
                """,
                f"team:{team_id}",
                max_gross or Decimal(str(cfg.global_gross_exposure_cap)) / Decimal("2"),
                max_daily_loss or Decimal(str(cfg.global_gross_exposure_cap)) * Decimal(str(cfg.per_team_daily_loss_pct)),
                max_positions,
            )
        logger.info("Team budget initialized: %s", team_id)

    async def _handle_breaches(self, breaches: list[str]) -> None:
        """Handle global limit breaches."""
        msg = f"GLOBAL RISK BREACH: {'; '.join(breaches)}"
        logger.critical(msg)

        ks = get_kill_switch()
        if not ks.is_killed:
            await ks.activate(msg, actor="risk_overlord")

    async def run_check_loop(self, interval_seconds: float = 5.0) -> None:
        """Continuous risk monitoring loop."""
        import asyncio
        logger.info("Risk overlord check loop started (interval=%.1fs)", interval_seconds)
        while True:
            try:
                global_breaches = await self.check_global_limits()
                team_breaches = await self.check_team_limits()

                if global_breaches:
                    logger.error("Global breaches: %s", global_breaches)
                if team_breaches:
                    logger.error("Team breaches: %s", team_breaches)
            except asyncio.CancelledError:
                logger.info("Risk overlord shutting down")
                return
            except Exception:
                logger.exception("Risk overlord check error")

            await asyncio.sleep(interval_seconds)
