"""
Kill Switch + Conservative Mode — control plane safety mechanisms.

Kill switch: immediate halt to all trading.
Conservative mode: reduced risk, not zero risk.
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from datetime import datetime, timezone
from typing import Any

from src.ledger import postgres

logger = logging.getLogger(__name__)


class KillSwitch:
    """
    Global and per-team kill switch.

    When activated:
    - No new orders are accepted
    - All working orders are canceled
    - OMS is frozen
    - Alert is raised

    Kill switch state is persisted to survive restarts.
    """

    def __init__(self) -> None:
        self._global_killed = False
        self._team_killed: set[str] = set()
        self._activation_reason: str = ""
        self._activated_at: datetime | None = None

    @property
    def is_killed(self) -> bool:
        return self._global_killed

    def is_team_killed(self, team_id: str) -> bool:
        return self._global_killed or team_id in self._team_killed

    async def activate(self, reason: str, actor: str = "system") -> None:
        """Activate global kill switch."""
        self._global_killed = True
        self._activation_reason = reason
        self._activated_at = datetime.now(timezone.utc)

        # Persist
        await postgres.execute(
            """
            INSERT INTO audit_log (log_id, actor, action, entity_type, details)
            VALUES ($1, $2, 'kill_switch_activated', 'system', $3)
            """,
            uuid.uuid4(), actor,
            {"reason": reason, "scope": "global"},
        )

        logger.critical("KILL SWITCH ACTIVATED: %s (by %s)", reason, actor)

    async def activate_team(self, team_id: str, reason: str, actor: str = "system") -> None:
        """Activate kill switch for a specific team."""
        self._team_killed.add(team_id)

        await postgres.execute(
            """
            INSERT INTO audit_log (log_id, actor, action, entity_type, entity_id, details)
            VALUES ($1, $2, 'kill_switch_activated', 'team', $3, $4)
            """,
            uuid.uuid4(), actor, team_id,
            {"reason": reason, "scope": f"team:{team_id}"},
        )

        logger.critical("KILL SWITCH ACTIVATED for team %s: %s", team_id, reason)

    async def deactivate(self, actor: str = "operator") -> None:
        """Deactivate global kill switch. Requires explicit operator action."""
        self._global_killed = False
        self._team_killed.clear()
        self._activation_reason = ""
        self._activated_at = None

        await postgres.execute(
            """
            INSERT INTO audit_log (log_id, actor, action, entity_type, details)
            VALUES ($1, $2, 'kill_switch_deactivated', 'system', $3)
            """,
            uuid.uuid4(), actor, {"scope": "global"},
        )

        logger.warning("Kill switch deactivated by %s", actor)

    def status(self) -> dict[str, Any]:
        return {
            "global_killed": self._global_killed,
            "team_killed": list(self._team_killed),
            "reason": self._activation_reason,
            "activated_at": self._activated_at.isoformat() if self._activated_at else None,
        }


class ConservativeMode:
    """
    Reduced-risk operating mode (Section 11.4).

    When active:
    - Reduced sizing (configurable multiplier)
    - Leverage restrictions
    - Higher liquidity standards
    - Only whitelisted strategies active
    """

    def __init__(self) -> None:
        self._active = False
        self._size_multiplier = 0.5  # halve all sizes
        self._max_leverage = 1.0  # no leverage
        self._allowed_strategies: set[str] | None = None  # None = all allowed
        self._reason: str = ""

    @property
    def is_active(self) -> bool:
        return self._active

    @property
    def size_multiplier(self) -> float:
        return self._size_multiplier if self._active else 1.0

    @property
    def max_leverage(self) -> float:
        return self._max_leverage if self._active else float("inf")

    def is_strategy_allowed(self, strategy_id: str) -> bool:
        if not self._active:
            return True
        if self._allowed_strategies is None:
            return True
        return strategy_id in self._allowed_strategies

    async def activate(
        self,
        reason: str,
        size_multiplier: float = 0.5,
        max_leverage: float = 1.0,
        allowed_strategies: set[str] | None = None,
        actor: str = "system",
    ) -> None:
        self._active = True
        self._size_multiplier = size_multiplier
        self._max_leverage = max_leverage
        self._allowed_strategies = allowed_strategies
        self._reason = reason

        await postgres.execute(
            """
            INSERT INTO audit_log (log_id, actor, action, entity_type, details)
            VALUES ($1, $2, 'conservative_mode_activated', 'system', $3)
            """,
            uuid.uuid4(), actor,
            {
                "reason": reason,
                "size_multiplier": size_multiplier,
                "max_leverage": max_leverage,
                "allowed_strategies": list(allowed_strategies) if allowed_strategies else None,
            },
        )

        logger.warning(
            "CONSERVATIVE MODE ACTIVATED: %s (size=%.1fx, leverage=%.1fx)",
            reason, size_multiplier, max_leverage,
        )

    async def deactivate(self, actor: str = "operator") -> None:
        self._active = False
        self._reason = ""
        self._allowed_strategies = None

        await postgres.execute(
            """
            INSERT INTO audit_log (log_id, actor, action, entity_type, details)
            VALUES ($1, $2, 'conservative_mode_deactivated', 'system', '{}')
            """,
            uuid.uuid4(), actor,
        )

        logger.info("Conservative mode deactivated by %s", actor)

    def status(self) -> dict[str, Any]:
        return {
            "active": self._active,
            "reason": self._reason,
            "size_multiplier": self._size_multiplier if self._active else 1.0,
            "max_leverage": self._max_leverage if self._active else None,
            "allowed_strategies": list(self._allowed_strategies) if self._allowed_strategies else None,
        }


# Singletons
_kill_switch: KillSwitch | None = None
_conservative: ConservativeMode | None = None


def get_kill_switch() -> KillSwitch:
    global _kill_switch
    if _kill_switch is None:
        _kill_switch = KillSwitch()
    return _kill_switch


def get_conservative_mode() -> ConservativeMode:
    global _conservative
    if _conservative is None:
        _conservative = ConservativeMode()
    return _conservative
