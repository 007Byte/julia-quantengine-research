"""
Validation Pack — hard acceptance thresholds with measurement code.

This is the bridge between "architecture works" and "ready for capital."
Every metric has a concrete threshold. No threshold = no claim.

Validation levels:
- PLUMBING: infrastructure works (Postgres, Redis, Julia, adapters connect)
- SHADOW: signals are generated and compared against market outcomes
- PAPER: full pipeline with paper fills, reconciliation clean
- PRE_LIVE: all operational gates pass, measured over 30+ days
"""

from __future__ import annotations

import logging
import time
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from enum import StrEnum
from typing import Any

from src.ledger import postgres

logger = logging.getLogger(__name__)


class ValidationLevel(StrEnum):
    PLUMBING = "plumbing"
    SHADOW = "shadow"
    PAPER = "paper"
    PRE_LIVE = "pre_live"


class ValidationThreshold:
    """A single measurable threshold."""

    def __init__(
        self,
        name: str,
        description: str,
        threshold: float,
        comparator: str,  # "gte", "lte", "eq", "gt", "lt"
        unit: str,
        level: ValidationLevel,
    ) -> None:
        self.name = name
        self.description = description
        self.threshold = threshold
        self.comparator = comparator
        self.unit = unit
        self.level = level
        self.measured_value: float | None = None
        self.measured_at: datetime | None = None
        self.passed: bool | None = None

    def evaluate(self, value: float) -> bool:
        self.measured_value = value
        self.measured_at = datetime.now(timezone.utc)

        if self.comparator == "gte":
            self.passed = value >= self.threshold
        elif self.comparator == "lte":
            self.passed = value <= self.threshold
        elif self.comparator == "gt":
            self.passed = value > self.threshold
        elif self.comparator == "lt":
            self.passed = value < self.threshold
        elif self.comparator == "eq":
            self.passed = value == self.threshold
        else:
            self.passed = False

        return self.passed

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "threshold": self.threshold,
            "comparator": self.comparator,
            "unit": self.unit,
            "level": self.level.value,
            "measured_value": self.measured_value,
            "passed": self.passed,
            "measured_at": self.measured_at.isoformat() if self.measured_at else None,
        }


# ============================================================
# THE THRESHOLDS — concrete, measurable, non-negotiable
# ============================================================

THRESHOLDS = [
    # --- PLUMBING level ---
    ValidationThreshold(
        "postgres_connected", "Postgres connection pool healthy",
        1.0, "eq", "bool", ValidationLevel.PLUMBING,
    ),
    ValidationThreshold(
        "redis_connected", "Redis connected with AOF verified",
        1.0, "eq", "bool", ValidationLevel.PLUMBING,
    ),
    ValidationThreshold(
        "julia_bridge_healthy", "Julia ZMQ bridge responds to heartbeat",
        1.0, "eq", "bool", ValidationLevel.PLUMBING,
    ),
    ValidationThreshold(
        "migrations_applied", "All SQL migrations applied",
        1.0, "eq", "bool", ValidationLevel.PLUMBING,
    ),
    ValidationThreshold(
        "instruments_loaded", "At least 2 instruments in master",
        2.0, "gte", "count", ValidationLevel.PLUMBING,
    ),
    ValidationThreshold(
        "adapter_connected", "Primary adapter connected",
        1.0, "eq", "bool", ValidationLevel.PLUMBING,
    ),

    # --- SHADOW level ---
    ValidationThreshold(
        "shadow_signal_count", "Minimum shadow signals generated over 7 days",
        50.0, "gte", "count", ValidationLevel.SHADOW,
    ),
    ValidationThreshold(
        "shadow_hit_rate_5m", "5-minute directional hit rate",
        0.52, "gte", "ratio", ValidationLevel.SHADOW,
    ),
    ValidationThreshold(
        "shadow_mean_move_5m", "Mean favorable 5-min move after signal",
        0.0, "gt", "bps", ValidationLevel.SHADOW,
    ),
    ValidationThreshold(
        "shadow_signal_diversity", "Signals in both directions (min buy OR sell pct)",
        0.2, "gte", "ratio", ValidationLevel.SHADOW,
    ),

    # --- PAPER level ---
    ValidationThreshold(
        "paper_fill_count", "Minimum paper fills over 14 days",
        100.0, "gte", "count", ValidationLevel.PAPER,
    ),
    ValidationThreshold(
        "paper_post_cost_expectancy", "Post-cost expectancy per fill",
        0.0, "gt", "USD", ValidationLevel.PAPER,
    ),
    ValidationThreshold(
        "paper_slippage_p95", "95th percentile slippage",
        15.0, "lte", "bps", ValidationLevel.PAPER,
    ),
    ValidationThreshold(
        "paper_reject_rate", "Order rejection rate",
        0.02, "lte", "ratio", ValidationLevel.PAPER,
    ),
    ValidationThreshold(
        "paper_recon_clean_days", "Consecutive days with zero critical recon incidents",
        7.0, "gte", "days", ValidationLevel.PAPER,
    ),
    ValidationThreshold(
        "paper_restart_recovery_time", "Time from restart to reconciled state",
        30.0, "lte", "seconds", ValidationLevel.PAPER,
    ),
    ValidationThreshold(
        "paper_uninterrupted_session", "Longest uninterrupted session",
        72.0, "gte", "hours", ValidationLevel.PAPER,
    ),

    # --- PRE_LIVE level ---
    ValidationThreshold(
        "live_paper_signal_divergence", "Paper vs shadow signal divergence",
        0.05, "lte", "ratio", ValidationLevel.PRE_LIVE,
    ),
    ValidationThreshold(
        "live_slippage_drift", "Slippage drift from shadow to paper",
        10.0, "lte", "bps", ValidationLevel.PRE_LIVE,
    ),
    ValidationThreshold(
        "live_min_trade_count", "Minimum trade count over 30 days",
        500.0, "gte", "count", ValidationLevel.PRE_LIVE,
    ),
    ValidationThreshold(
        "live_feed_uptime", "Data feed uptime over 30 days",
        0.995, "gte", "ratio", ValidationLevel.PRE_LIVE,
    ),
    ValidationThreshold(
        "live_execution_quality_stable", "Execution quality stable (p95 slippage < 2x median)",
        2.0, "lte", "ratio", ValidationLevel.PRE_LIVE,
    ),
    ValidationThreshold(
        "live_recon_incident_rate", "Recon incidents per day over 30 days",
        0.0, "eq", "count/day", ValidationLevel.PRE_LIVE,
    ),
    ValidationThreshold(
        "live_kill_switch_drill", "Kill switch drill passes",
        1.0, "eq", "bool", ValidationLevel.PRE_LIVE,
    ),
    ValidationThreshold(
        "live_restore_drill", "Postgres restore drill passes",
        1.0, "eq", "bool", ValidationLevel.PRE_LIVE,
    ),
    ValidationThreshold(
        "live_redis_recovery_drill", "Redis restart recovery passes",
        1.0, "eq", "bool", ValidationLevel.PRE_LIVE,
    ),
    ValidationThreshold(
        "live_runbooks_approved", "Operational runbooks reviewed and signed",
        1.0, "eq", "bool", ValidationLevel.PRE_LIVE,
    ),
    ValidationThreshold(
        "live_oncall_assigned", "On-call owner designated",
        1.0, "eq", "bool", ValidationLevel.PRE_LIVE,
    ),
]


class ValidationPack:
    """
    Measures the system against concrete thresholds.

    Run this before advancing to the next validation level.
    """

    def __init__(self) -> None:
        self._thresholds = {t.name: t for t in THRESHOLDS}
        self._manual_overrides: dict[str, float] = {}

    def set_manual(self, name: str, value: float) -> None:
        """Set a manually-measured value (for drill results, approvals, etc.)."""
        self._manual_overrides[name] = value

    async def measure_plumbing(self) -> dict[str, Any]:
        """Measure all PLUMBING-level thresholds."""
        results = {}

        # Postgres
        try:
            pool = await postgres.get_pool()
            async with pool.acquire() as conn:
                val = await conn.fetchval("SELECT 1")
            self._thresholds["postgres_connected"].evaluate(1.0 if val == 1 else 0.0)
        except Exception:
            self._thresholds["postgres_connected"].evaluate(0.0)
        results["postgres_connected"] = self._thresholds["postgres_connected"].to_dict()

        # Redis
        try:
            from src.ledger import redis_streams
            r = await redis_streams.get_redis()
            pong = await r.ping()
            aof = await redis_streams.verify_aof()
            self._thresholds["redis_connected"].evaluate(1.0 if (pong and aof) else 0.0)
        except Exception:
            self._thresholds["redis_connected"].evaluate(0.0)
        results["redis_connected"] = self._thresholds["redis_connected"].to_dict()

        # Julia bridge
        try:
            bridge = get_bridge()
            self._thresholds["julia_bridge_healthy"].evaluate(1.0 if bridge.is_healthy else 0.0)
        except Exception:
            self._thresholds["julia_bridge_healthy"].evaluate(0.0)
        results["julia_bridge_healthy"] = self._thresholds["julia_bridge_healthy"].to_dict()

        # Migrations
        try:
            count = await postgres.fetchval("SELECT COUNT(*) FROM _migrations")
            self._thresholds["migrations_applied"].evaluate(1.0 if (count or 0) > 0 else 0.0)
        except Exception:
            self._thresholds["migrations_applied"].evaluate(0.0)
        results["migrations_applied"] = self._thresholds["migrations_applied"].to_dict()

        # Instruments
        try:
            count = await postgres.fetchval(
                "SELECT COUNT(*) FROM instrument_master WHERE is_active"
            )
            self._thresholds["instruments_loaded"].evaluate(float(count or 0))
        except Exception:
            self._thresholds["instruments_loaded"].evaluate(0.0)
        results["instruments_loaded"] = self._thresholds["instruments_loaded"].to_dict()

        return results

    async def measure_shadow(self) -> dict[str, Any]:
        """Measure SHADOW-level thresholds from shadow signal log."""
        results = {}

        try:
            pool = await postgres.get_pool()
            async with pool.acquire() as conn:
                # Count shadow signals
                rows = await conn.fetch("""
                    SELECT details FROM audit_log
                    WHERE action = 'shadow_signal'
                    AND logged_at >= NOW() - INTERVAL '7 days'
                """)

            signals = []
            for row in rows:
                d = row["details"]
                if isinstance(d, dict):
                    signals.append(d)

            count = len(signals)
            self._thresholds["shadow_signal_count"].evaluate(float(count))
            results["shadow_signal_count"] = self._thresholds["shadow_signal_count"].to_dict()

            if count > 0:
                # Hit rate
                correct = [s for s in signals if s.get("was_correct_5m") is True]
                evaluated = [s for s in signals if s.get("was_correct_5m") is not None]
                hit_rate = len(correct) / max(len(evaluated), 1)
                self._thresholds["shadow_hit_rate_5m"].evaluate(hit_rate)

                # Mean move
                moves = [s["move_5m_bps"] for s in signals if s.get("move_5m_bps") is not None]
                mean_move = sum(moves) / max(len(moves), 1) if moves else 0
                self._thresholds["shadow_mean_move_5m"].evaluate(mean_move)

                # Direction diversity
                buys = len([s for s in signals if s.get("direction") == "buy"])
                sells = len([s for s in signals if s.get("direction") == "sell"])
                min_pct = min(buys, sells) / max(count, 1)
                self._thresholds["shadow_signal_diversity"].evaluate(min_pct)
            else:
                self._thresholds["shadow_hit_rate_5m"].evaluate(0.0)
                self._thresholds["shadow_mean_move_5m"].evaluate(0.0)
                self._thresholds["shadow_signal_diversity"].evaluate(0.0)

            for name in ["shadow_hit_rate_5m", "shadow_mean_move_5m", "shadow_signal_diversity"]:
                results[name] = self._thresholds[name].to_dict()

        except Exception:
            logger.exception("Shadow measurement failed")

        return results

    async def measure_paper(self) -> dict[str, Any]:
        """Measure PAPER-level thresholds from live paper trading data."""
        results = {}

        try:
            pool = await postgres.get_pool()
            async with pool.acquire() as conn:
                # Fill count
                fill_count = await conn.fetchval("""
                    SELECT COUNT(*) FROM fills
                    WHERE fill_time_utc >= NOW() - INTERVAL '14 days'
                """)
                self._thresholds["paper_fill_count"].evaluate(float(fill_count or 0))

                # Post-cost expectancy
                if fill_count and fill_count > 0:
                    rpnl = await conn.fetchval(
                        "SELECT COALESCE(SUM(realized_pnl), 0) FROM strategy_positions"
                    )
                    total_fees = await conn.fetchval(
                        "SELECT COALESCE(SUM(fee), 0) FROM fills WHERE fill_time_utc >= NOW() - INTERVAL '14 days'"
                    )
                    net = Decimal(str(rpnl or 0)) - Decimal(str(total_fees or 0))
                    expectancy = float(net) / max(fill_count, 1)
                    self._thresholds["paper_post_cost_expectancy"].evaluate(expectancy)
                else:
                    self._thresholds["paper_post_cost_expectancy"].evaluate(0.0)

                # Slippage p95
                slippages = await conn.fetch("""
                    SELECT slippage_bps FROM fills
                    WHERE slippage_bps IS NOT NULL
                    AND fill_time_utc >= NOW() - INTERVAL '14 days'
                    ORDER BY slippage_bps
                """)
                if slippages:
                    vals = [float(r["slippage_bps"]) for r in slippages]
                    p95_idx = int(len(vals) * 0.95)
                    p95 = vals[min(p95_idx, len(vals) - 1)]
                    self._thresholds["paper_slippage_p95"].evaluate(abs(p95))
                else:
                    self._thresholds["paper_slippage_p95"].evaluate(0.0)

                # Recon clean days
                latest_critical = await conn.fetchval("""
                    SELECT MAX(detected_at) FROM reconciliation_incidents
                    WHERE severity = 'critical'
                """)
                if latest_critical:
                    clean_days = (datetime.now(timezone.utc) - latest_critical).total_seconds() / 86400
                else:
                    # No critical incidents ever — count from first fill
                    first_fill = await conn.fetchval("SELECT MIN(fill_time_utc) FROM fills")
                    if first_fill:
                        clean_days = (datetime.now(timezone.utc) - first_fill).total_seconds() / 86400
                    else:
                        clean_days = 0
                self._thresholds["paper_recon_clean_days"].evaluate(clean_days)

            # Manual overrides
            for name in ["paper_reject_rate", "paper_restart_recovery_time", "paper_uninterrupted_session"]:
                if name in self._manual_overrides:
                    self._thresholds[name].evaluate(self._manual_overrides[name])

            for t in THRESHOLDS:
                if t.level == ValidationLevel.PAPER:
                    results[t.name] = t.to_dict()

        except Exception:
            logger.exception("Paper measurement failed")

        return results

    def get_report(self, level: ValidationLevel | None = None) -> dict[str, Any]:
        """Generate a validation report."""
        thresholds = THRESHOLDS
        if level:
            thresholds = [t for t in thresholds if t.level == level]

        measured = [t for t in thresholds if t.passed is not None]
        passed = [t for t in measured if t.passed]
        failed = [t for t in measured if not t.passed]
        unmeasured = [t for t in thresholds if t.passed is None]

        return {
            "level": level.value if level else "all",
            "total_thresholds": len(thresholds),
            "measured": len(measured),
            "passed": len(passed),
            "failed": len(failed),
            "unmeasured": len(unmeasured),
            "pass_rate": len(passed) / max(len(measured), 1),
            "ready": len(failed) == 0 and len(unmeasured) == 0,
            "failures": [t.to_dict() for t in failed],
            "unmeasured": [t.to_dict() for t in unmeasured],
            "all_results": [t.to_dict() for t in thresholds],
        }

    def print_report(self, level: ValidationLevel | None = None) -> None:
        """Print human-readable validation report."""
        report = self.get_report(level)

        print(f"\n{'=' * 70}")
        print(f"VALIDATION REPORT — Level: {report['level'].upper()}")
        print(f"{'=' * 70}")
        print(f"Thresholds: {report['total_thresholds']}  "
              f"Measured: {report['measured']}  "
              f"Passed: {report['passed']}  "
              f"Failed: {report['failed']}  "
              f"Unmeasured: {len(report['unmeasured'])}")
        print(f"Ready: {'YES' if report['ready'] else 'NO'}")

        if report["failures"]:
            print(f"\n--- FAILURES ---")
            for t in report["failures"]:
                print(f"  FAIL  {t['name']}: {t['measured_value']} {t['comparator']} {t['threshold']} ({t['unit']})")
                print(f"        {t['description']}")

        if report["unmeasured"]:
            print(f"\n--- UNMEASURED ---")
            for t in report["unmeasured"]:
                print(f"  ???   {t['name']}: {t['description']} ({t['unit']})")

        print(f"{'=' * 70}\n")


def get_bridge():
    from src.core.julia_bridge import get_bridge as _get
    return _get()
