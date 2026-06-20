"""Unit tests for trading calendar and session logic."""

from datetime import date, datetime, time, timezone
from zoneinfo import ZoneInfo

import pytest

from src.core.trading_calendar import (
    MarketSession,
    TradingCalendar,
    US_HOLIDAYS_2026,
    get_calendar,
)

ET = ZoneInfo("America/New_York")


class TestCryptoCalendar:
    def test_always_open(self):
        cal = TradingCalendar("24x7")
        assert cal.is_trading_allowed()

    def test_session_is_always_open(self):
        cal = TradingCalendar("24x7")
        assert cal.get_session() == "always_open"

    def test_should_trade_always(self):
        cal = TradingCalendar("24x7")
        # Saturday midnight
        sat = datetime(2026, 3, 14, 0, 0, tzinfo=timezone.utc)
        assert cal.is_trading_allowed(sat)


class TestUSEquityCalendar:
    def test_regular_hours_open(self):
        cal = TradingCalendar("us_equity")
        # Wednesday 10:00 AM ET = regular hours
        dt = datetime(2026, 3, 18, 10, 0, tzinfo=ET)
        assert cal.is_trading_allowed(dt)

    def test_pre_market_not_trading(self):
        cal = TradingCalendar("us_equity")
        # 8:00 AM ET = pre-market
        dt = datetime(2026, 3, 18, 8, 0, tzinfo=ET)
        assert not cal.is_trading_allowed(dt)

    def test_session_pre_market(self):
        cal = TradingCalendar("us_equity")
        dt = datetime(2026, 3, 18, 8, 0, tzinfo=ET)
        assert cal.get_session(dt) == "pre_market"

    def test_session_regular(self):
        cal = TradingCalendar("us_equity")
        dt = datetime(2026, 3, 18, 12, 0, tzinfo=ET)
        assert cal.get_session(dt) == "regular"

    def test_session_post_market(self):
        cal = TradingCalendar("us_equity")
        dt = datetime(2026, 3, 18, 17, 0, tzinfo=ET)
        assert cal.get_session(dt) == "post_market"

    def test_weekend_closed(self):
        cal = TradingCalendar("us_equity")
        # Saturday
        dt = datetime(2026, 3, 14, 12, 0, tzinfo=ET)
        assert not cal.is_trading_allowed(dt)
        assert cal.get_session(dt) == "closed"

    def test_holiday_closed(self):
        cal = TradingCalendar("us_equity")
        # Christmas 2026
        dt = datetime(2026, 12, 25, 12, 0, tzinfo=ET)
        assert not cal.is_trading_allowed(dt)

    def test_next_open_from_weekend(self):
        cal = TradingCalendar("us_equity")
        sat = datetime(2026, 3, 14, 12, 0, tzinfo=ET)
        next_open = cal.next_open(sat)
        assert next_open is not None
        # Should be Monday 9:30 ET
        assert next_open.weekday() == 0  # Monday

    def test_overnight_closed(self):
        cal = TradingCalendar("us_equity")
        # 2:00 AM ET = closed
        dt = datetime(2026, 3, 18, 2, 0, tzinfo=ET)
        assert not cal.is_trading_allowed(dt)


class TestFXCalendar:
    def test_weekday_open(self):
        cal = TradingCalendar("fx")
        # Wednesday noon UTC
        dt = datetime(2026, 3, 18, 12, 0, tzinfo=timezone.utc)
        assert cal.is_trading_allowed(dt)

    def test_saturday_closed(self):
        cal = TradingCalendar("fx")
        # Saturday
        dt = datetime(2026, 3, 14, 12, 0, tzinfo=timezone.utc)
        assert not cal.is_trading_allowed(dt)

    def test_sunday_before_open_closed(self):
        cal = TradingCalendar("fx")
        # Sunday 10 AM ET (before 5 PM open)
        dt = datetime(2026, 3, 15, 10, 0, tzinfo=ET)
        assert not cal.is_trading_allowed(dt)

    def test_sunday_after_open(self):
        cal = TradingCalendar("fx")
        # Sunday 6 PM ET (after 5 PM open)
        dt = datetime(2026, 3, 15, 18, 0, tzinfo=ET)
        assert cal.is_trading_allowed(dt)


class TestCalendarFactory:
    def test_get_calendar(self):
        cal = get_calendar("us_equity")
        assert cal.calendar_type == "us_equity"

    def test_get_unknown_calendar(self):
        cal = get_calendar("martian_exchange")
        assert cal.calendar_type == "martian_exchange"

    def test_holidays_list(self):
        assert len(US_HOLIDAYS_2026) >= 9
        assert date(2026, 12, 25) in US_HOLIDAYS_2026
