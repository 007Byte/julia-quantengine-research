"""Tests for shadow mode signal recording and outcome tracking."""

import time
from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest

from src.pipeline.shadow_mode import ShadowSession, ShadowSignal


class TestShadowSignal:
    def test_favorable_buy_move(self):
        sig = ShadowSignal(
            "sig1", "inst1", "BTCUSDT", "buy", 0.8,
            Decimal("50000"), datetime.now(timezone.utc),
        )
        sig.price_after_5m = Decimal("50050")  # 10 bps up
        assert sig.move_5m_bps == pytest.approx(10.0, abs=0.1)
        assert sig.was_correct_5m is True

    def test_unfavorable_buy_move(self):
        sig = ShadowSignal(
            "sig1", "inst1", "BTCUSDT", "buy", 0.8,
            Decimal("50000"), datetime.now(timezone.utc),
        )
        sig.price_after_5m = Decimal("49950")  # 10 bps down
        assert sig.move_5m_bps == pytest.approx(-10.0, abs=0.1)
        assert sig.was_correct_5m is False

    def test_favorable_sell_move(self):
        sig = ShadowSignal(
            "sig1", "inst1", "BTCUSDT", "sell", 0.7,
            Decimal("50000"), datetime.now(timezone.utc),
        )
        sig.price_after_5m = Decimal("49950")  # price down = good for sell
        assert sig.move_5m_bps == pytest.approx(10.0, abs=0.1)  # favorable
        assert sig.was_correct_5m is True

    def test_no_outcome_yet(self):
        sig = ShadowSignal(
            "sig1", "inst1", "BTCUSDT", "buy", 0.8,
            Decimal("50000"), datetime.now(timezone.utc),
        )
        assert sig.move_5m_bps is None
        assert sig.was_correct_5m is None
        assert not sig.outcome_recorded

    def test_to_dict(self):
        sig = ShadowSignal(
            "sig1", "inst1", "BTCUSDT", "buy", 0.8,
            Decimal("50000"), datetime.now(timezone.utc),
        )
        d = sig.to_dict()
        assert d["direction"] == "buy"
        assert d["strength"] == 0.8
        assert d["venue_symbol"] == "BTCUSDT"


class TestShadowSession:
    def test_initial_state(self):
        session = ShadowSession()
        assert session.signal_count == 0
        assert len(session.signals_with_outcomes) == 0

    def test_record_price(self):
        session = ShadowSession()
        session.record_price("BTCUSDT", Decimal("50000"))
        assert session._prices["BTCUSDT"] == Decimal("50000")

    def test_price_history_maintained(self):
        session = ShadowSession()
        session.record_price("BTCUSDT", Decimal("50000"))
        session.record_price("BTCUSDT", Decimal("50010"))
        assert len(session._price_history["BTCUSDT"]) == 2

    def test_get_stats_empty(self):
        session = ShadowSession()
        stats = session.get_stats()
        assert stats["total_signals"] == 0
        assert stats["completed_signals"] == 0

    def test_get_stats_with_signals(self):
        session = ShadowSession()
        sig = ShadowSignal(
            "sig1", "inst1", "BTCUSDT", "buy", 0.8,
            Decimal("50000"), datetime.now(timezone.utc) - timedelta(hours=2),
        )
        sig.price_after_1m = Decimal("50010")
        sig.price_after_5m = Decimal("50025")
        sig.price_after_1h = Decimal("50100")
        sig.outcome_recorded = True
        session._signals.append(sig)

        stats = session.get_stats()
        assert stats["total_signals"] == 1
        assert stats["completed_signals"] == 1
        assert stats["hit_rate_5m"] == 1.0  # buy + price went up

    def test_mixed_signals_stats(self):
        session = ShadowSession()
        now = datetime.now(timezone.utc) - timedelta(hours=2)

        # Correct buy
        s1 = ShadowSignal("s1", "i1", "BTCUSDT", "buy", 0.8, Decimal("50000"), now)
        s1.price_after_5m = Decimal("50050")
        s1.price_after_1h = Decimal("50100")
        s1.outcome_recorded = True

        # Wrong buy
        s2 = ShadowSignal("s2", "i1", "BTCUSDT", "buy", 0.6, Decimal("50000"), now)
        s2.price_after_5m = Decimal("49950")
        s2.price_after_1h = Decimal("49900")
        s2.outcome_recorded = True

        session._signals = [s1, s2]

        stats = session.get_stats()
        assert stats["completed_signals"] == 2
        assert stats["hit_rate_5m"] == 0.5  # 1 of 2

    def test_instruments_default_to_btc_eth(self):
        session = ShadowSession()
        assert session._instruments == ["BTCUSDT", "ETHUSDT"]
