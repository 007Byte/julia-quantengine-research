"""Unit tests for OMS state machine transitions."""

import pytest

from src.core.event_schema import OrderIntentState, VenueOrderState
from src.pipeline.oms import INTENT_TRANSITIONS, VENUE_ORDER_TRANSITIONS


class TestIntentStateMachine:
    """Verify parent intent state machine is correctly defined."""

    def test_intent_created_goes_to_risk_pending(self):
        assert OrderIntentState.RISK_PENDING in INTENT_TRANSITIONS[OrderIntentState.INTENT_CREATED]

    def test_risk_pending_can_approve_or_reject(self):
        allowed = INTENT_TRANSITIONS[OrderIntentState.RISK_PENDING]
        assert OrderIntentState.RISK_APPROVED in allowed
        assert OrderIntentState.REJECTED in allowed

    def test_risk_approved_goes_to_reserving(self):
        assert OrderIntentState.RESERVING_BUDGET in INTENT_TRANSITIONS[OrderIntentState.RISK_APPROVED]

    def test_working_can_fill_or_cancel(self):
        allowed = INTENT_TRANSITIONS[OrderIntentState.WORKING]
        assert OrderIntentState.FILLED in allowed
        assert OrderIntentState.PARTIALLY_FILLED in allowed
        assert OrderIntentState.CANCELED in allowed

    def test_partially_filled_can_complete(self):
        allowed = INTENT_TRANSITIONS[OrderIntentState.PARTIALLY_FILLED]
        assert OrderIntentState.FILLED in allowed
        assert OrderIntentState.CANCELED in allowed

    def test_filled_is_terminal(self):
        assert OrderIntentState.FILLED not in INTENT_TRANSITIONS

    def test_rejected_is_terminal(self):
        assert OrderIntentState.REJECTED not in INTENT_TRANSITIONS

    def test_canceled_is_terminal(self):
        assert OrderIntentState.CANCELED not in INTENT_TRANSITIONS

    def test_suspended_can_resume_or_cancel(self):
        allowed = INTENT_TRANSITIONS[OrderIntentState.SUSPENDED]
        assert OrderIntentState.WORKING in allowed
        assert OrderIntentState.CANCELED in allowed

    def test_no_backward_transitions(self):
        """No state should be able to go back to intent_created."""
        for state, targets in INTENT_TRANSITIONS.items():
            if state != OrderIntentState.INTENT_CREATED:
                assert OrderIntentState.INTENT_CREATED not in targets

    def test_all_non_terminal_states_have_transitions(self):
        terminal = {OrderIntentState.FILLED, OrderIntentState.CANCELED,
                    OrderIntentState.REJECTED, OrderIntentState.EXPIRED}
        non_terminal = set(OrderIntentState) - terminal
        for state in non_terminal:
            assert state in INTENT_TRANSITIONS, f"{state} missing from transitions"


class TestVenueOrderStateMachine:
    """Verify child venue order state machine."""

    def test_child_created_goes_to_submitted(self):
        assert VenueOrderState.SUBMITTED in VENUE_ORDER_TRANSITIONS[VenueOrderState.CHILD_CREATED]

    def test_submitted_can_be_acknowledged_or_rejected(self):
        allowed = VENUE_ORDER_TRANSITIONS[VenueOrderState.SUBMITTED]
        assert VenueOrderState.ACKNOWLEDGED in allowed
        assert VenueOrderState.REJECTED in allowed

    def test_unknown_but_open_exists(self):
        """Critical during outages or callback gaps."""
        assert VenueOrderState.UNKNOWN_BUT_OPEN in VENUE_ORDER_TRANSITIONS[VenueOrderState.SUBMITTED]

    def test_cancel_requested_can_still_fill(self):
        """Broker may fill before cancel takes effect."""
        allowed = VENUE_ORDER_TRANSITIONS[VenueOrderState.CANCEL_REQUESTED]
        assert VenueOrderState.FILLED in allowed
        assert VenueOrderState.PARTIALLY_FILLED in allowed
        assert VenueOrderState.CANCELED in allowed

    def test_unknown_but_open_can_resolve(self):
        allowed = VENUE_ORDER_TRANSITIONS[VenueOrderState.UNKNOWN_BUT_OPEN]
        assert VenueOrderState.ACKNOWLEDGED in allowed
        assert VenueOrderState.FILLED in allowed
        assert VenueOrderState.CANCELED in allowed

    def test_filled_is_terminal(self):
        assert VenueOrderState.FILLED not in VENUE_ORDER_TRANSITIONS
