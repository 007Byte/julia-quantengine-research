"""Unit tests for canonical event schema types."""

import uuid
from decimal import Decimal

import pytest

from src.core.event_schema import (
    Fill,
    NormalizedBar,
    OrderIntent,
    OrderIntentState,
    OrderIntentType,
    RiskDecision,
    RiskDecisionType,
    RiskReservation,
    ReservationStatus,
    Side,
    SignalEvent,
    StreamEnvelope,
    TimeInForce,
    VenueOrder,
    VenueOrderState,
    _serialize,
)


class TestOrderIntent:
    def test_create_with_defaults(self):
        intent = OrderIntent(
            idempotency_key="test-key-001",
            team_id="crypto",
            strategy_id="mean_reversion",
            instrument_id=uuid.uuid4(),
            side=Side.BUY,
            intent_type=OrderIntentType.LIMIT,
            requested_qty=Decimal("1.5"),
            limit_price=Decimal("50000"),
            model_version="v1",
            feature_version="v1",
            config_hash="abc123",
        )

        assert intent.current_state == OrderIntentState.INTENT_CREATED
        assert intent.time_in_force == TimeInForce.GTC
        assert intent.order_intent_id is not None
        assert intent.correlation_id is not None
        assert intent.created_at is not None

    def test_idempotency_key_required(self):
        with pytest.raises(Exception):
            OrderIntent(
                team_id="crypto",
                strategy_id="test",
                instrument_id=uuid.uuid4(),
                side=Side.BUY,
                intent_type=OrderIntentType.MARKET,
                requested_qty=Decimal("1"),
                model_version="v1",
                feature_version="v1",
                config_hash="abc",
            )


class TestRiskReservation:
    def test_create_reservation(self):
        res = RiskReservation(
            order_intent_id=uuid.uuid4(),
            scope="global",
            reserved_notional=Decimal("50000"),
            reserved_gross=Decimal("50000"),
        )

        assert res.status == ReservationStatus.ACTIVE
        assert res.reserved_notional == Decimal("50000")
        assert res.released_at is None

    def test_reservation_has_unique_id(self):
        r1 = RiskReservation(order_intent_id=uuid.uuid4(), scope="global")
        r2 = RiskReservation(order_intent_id=uuid.uuid4(), scope="global")
        assert r1.reservation_id != r2.reservation_id


class TestVenueOrder:
    def test_create_child(self):
        child = VenueOrder(
            order_intent_id=uuid.uuid4(),
            venue="binance",
            child_seq=1,
            requested_qty=Decimal("0.5"),
        )

        assert child.current_state == VenueOrderState.CHILD_CREATED
        assert child.filled_qty == Decimal("0")


class TestFill:
    def test_create_fill(self):
        fill = Fill(
            order_intent_id=uuid.uuid4(),
            instrument_id=uuid.uuid4(),
            team_id="crypto",
            strategy_id="trend",
            venue="binance",
            side=Side.BUY,
            quantity=Decimal("1.0"),
            price=Decimal("50000"),
            fee=Decimal("5"),
            fee_currency="USDT",
        )

        assert fill.fill_id is not None
        assert fill.slippage_bps is None


class TestSignalEvent:
    def test_create_signal(self):
        signal = SignalEvent(
            team_id="crypto",
            strategy_id="mean_reversion",
            instrument_id=uuid.uuid4(),
            side=Side.SELL,
            strength=0.78,
            model_version="v2",
            feature_version="v1",
            config_hash="xyz",
        )

        assert signal.signal_id is not None
        assert signal.strength == 0.78


class TestStreamEnvelope:
    def test_wrap_and_serialize(self):
        signal = SignalEvent(
            team_id="crypto",
            strategy_id="test",
            instrument_id=uuid.uuid4(),
            side=Side.BUY,
            strength=0.65,
            model_version="v1",
            feature_version="v1",
            config_hash="hash",
        )

        envelope = StreamEnvelope.wrap("signal.generated", signal, idempotency_key="test-key")

        assert envelope.event_type == "signal.generated"
        assert envelope.idempotency_key == "test-key"
        assert len(envelope.payload) > 0

    def test_to_stream_dict(self):
        signal = SignalEvent(
            team_id="crypto",
            strategy_id="test",
            instrument_id=uuid.uuid4(),
            side=Side.BUY,
            strength=0.5,
            model_version="v1",
            feature_version="v1",
            config_hash="h",
        )

        envelope = StreamEnvelope.wrap("test.event", signal)
        d = envelope.to_stream_dict()

        assert "envelope_id" in d
        assert "event_type" in d
        assert "payload" in d
        assert d["event_type"] == "test.event"


class TestRiskDecision:
    def test_approval(self):
        decision = RiskDecision(
            order_intent_id=uuid.uuid4(),
            team_id="crypto",
            decision=RiskDecisionType.APPROVED,
            reason="all checks passed",
            original_qty=Decimal("1.0"),
            approved_qty=Decimal("1.0"),
        )

        assert decision.decision == RiskDecisionType.APPROVED

    def test_rejection(self):
        decision = RiskDecision(
            order_intent_id=uuid.uuid4(),
            team_id="crypto",
            decision=RiskDecisionType.REJECTED,
            reason="gross exposure cap exceeded",
        )

        assert decision.decision == RiskDecisionType.REJECTED
