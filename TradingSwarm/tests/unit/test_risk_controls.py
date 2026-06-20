"""Unit tests for risk control logic and state machine invariants."""

import uuid

import pytest

from src.control.kill_switch import ConservativeMode, KillSwitch


class TestKillSwitch:
    def test_initial_state(self):
        ks = KillSwitch()
        assert not ks.is_killed
        assert not ks.is_team_killed("crypto")

    def test_global_kill(self):
        ks = KillSwitch()
        ks._global_killed = True

        assert ks.is_killed
        assert ks.is_team_killed("crypto")
        assert ks.is_team_killed("stocks")

    def test_team_kill_only(self):
        ks = KillSwitch()
        ks._team_killed.add("crypto")

        assert not ks.is_killed
        assert ks.is_team_killed("crypto")
        assert not ks.is_team_killed("stocks")

    def test_status(self):
        ks = KillSwitch()
        status = ks.status()
        assert status["global_killed"] is False
        assert status["team_killed"] == []

    def test_global_kill_overrides_team(self):
        ks = KillSwitch()
        ks._global_killed = True
        # Even if team is not in team_killed set, global overrides
        assert ks.is_team_killed("any_team")


class TestConservativeMode:
    def test_initial_state(self):
        cm = ConservativeMode()
        assert not cm.is_active
        assert cm.size_multiplier == 1.0
        assert cm.is_strategy_allowed("anything")

    def test_active_mode(self):
        cm = ConservativeMode()
        cm._active = True
        cm._size_multiplier = 0.5
        cm._max_leverage = 1.0

        assert cm.is_active
        assert cm.size_multiplier == 0.5
        assert cm.max_leverage == 1.0

    def test_strategy_filter(self):
        cm = ConservativeMode()
        cm._active = True
        cm._allowed_strategies = {"mean_reversion", "trend"}

        assert cm.is_strategy_allowed("mean_reversion")
        assert cm.is_strategy_allowed("trend")
        assert not cm.is_strategy_allowed("aggressive_scalp")

    def test_inactive_allows_all(self):
        cm = ConservativeMode()
        cm._active = False
        cm._allowed_strategies = {"mean_reversion"}

        # When inactive, all strategies allowed
        assert cm.is_strategy_allowed("aggressive_scalp")

    def test_none_allowed_strategies_means_all(self):
        cm = ConservativeMode()
        cm._active = True
        cm._allowed_strategies = None  # all allowed

        assert cm.is_strategy_allowed("anything")

    def test_status(self):
        cm = ConservativeMode()
        cm._active = True
        cm._reason = "high volatility"
        cm._size_multiplier = 0.3

        status = cm.status()
        assert status["active"] is True
        assert status["reason"] == "high volatility"
        assert status["size_multiplier"] == 0.3


class TestRiskGateInvariants:
    """Test invariants from Section 11 of the architecture plan."""

    def test_reservation_statuses_cover_lifecycle(self):
        from src.core.event_schema import ReservationStatus
        statuses = set(ReservationStatus)
        assert ReservationStatus.ACTIVE in statuses
        assert ReservationStatus.CONSUMED in statuses
        assert ReservationStatus.RELEASED in statuses
        assert ReservationStatus.EXPIRED in statuses

    def test_risk_decision_types(self):
        from src.core.event_schema import RiskDecisionType
        assert RiskDecisionType.APPROVED.value == "approved"
        assert RiskDecisionType.REJECTED.value == "rejected"
        assert RiskDecisionType.SIZE_REDUCED.value == "size_reduced"

    def test_order_cannot_skip_risk(self):
        """Intent must go through risk_pending before accepted_by_oms."""
        from src.pipeline.oms import INTENT_TRANSITIONS
        from src.core.event_schema import OrderIntentState

        # intent_created can only go to risk_pending
        assert INTENT_TRANSITIONS[OrderIntentState.INTENT_CREATED] == {OrderIntentState.RISK_PENDING}

        # accepted_by_oms is not reachable from intent_created directly
        assert OrderIntentState.ACCEPTED_BY_OMS not in INTENT_TRANSITIONS[OrderIntentState.INTENT_CREATED]

    def test_no_trading_without_reservation(self):
        """risk_approved must go to reserving_budget before OMS."""
        from src.pipeline.oms import INTENT_TRANSITIONS
        from src.core.event_schema import OrderIntentState

        # risk_approved can only go to reserving_budget
        assert INTENT_TRANSITIONS[OrderIntentState.RISK_APPROVED] == {OrderIntentState.RESERVING_BUDGET}

    def test_oms_starts_frozen(self):
        """OMS must start in frozen state."""
        from src.pipeline.oms import OrderManagementSystem
        oms = OrderManagementSystem()
        assert oms.is_frozen
