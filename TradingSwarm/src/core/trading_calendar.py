"""
Trading Calendar + Session Logic.

Handles:
- US equity market hours (9:30-16:00 ET)
- Crypto 24/7
- FX sessions (Sydney, Tokyo, London, New York)
- Holiday calendars
- Pre/post market awareness
- Blackout periods
"""

from __future__ import annotations

import logging
from datetime import date, datetime, time, timedelta, timezone
from enum import StrEnum
from typing import Any
from zoneinfo import ZoneInfo

logger = logging.getLogger(__name__)

ET = ZoneInfo("America/New_York")
UTC = timezone.utc

# US market holidays for 2026 (update annually)
US_HOLIDAYS_2026 = {
    date(2026, 1, 1),    # New Year's
    date(2026, 1, 19),   # MLK
    date(2026, 2, 16),   # Presidents' Day
    date(2026, 4, 3),    # Good Friday
    date(2026, 5, 25),   # Memorial Day
    date(2026, 7, 3),    # Independence Day (observed)
    date(2026, 9, 7),    # Labor Day
    date(2026, 11, 26),  # Thanksgiving
    date(2026, 12, 25),  # Christmas
}


class MarketSession(StrEnum):
    PRE_MARKET = "pre_market"
    REGULAR = "regular"
    POST_MARKET = "post_market"
    CLOSED = "closed"


class FXSession(StrEnum):
    SYDNEY = "sydney"
    TOKYO = "tokyo"
    LONDON = "london"
    NEW_YORK = "new_york"
    OVERLAP_LONDON_NY = "overlap_london_ny"


class TradingCalendar:
    """
    Calendar for a specific market type.

    Determines whether trading is allowed, what session we're in,
    and provides session boundaries for scheduling.
    """

    def __init__(self, calendar_type: str = "24x7") -> None:
        self.calendar_type = calendar_type

    def is_trading_allowed(self, now: datetime | None = None) -> bool:
        """Whether new orders can be submitted right now."""
        now = now or datetime.now(UTC)

        if self.calendar_type == "24x7":
            return True
        elif self.calendar_type == "us_equity":
            return self._us_equity_is_open(now)
        elif self.calendar_type == "fx":
            # FX trades Sun 5PM ET to Fri 5PM ET
            return self._fx_is_open(now)
        return True

    def get_session(self, now: datetime | None = None) -> str:
        """Get the current market session name."""
        now = now or datetime.now(UTC)

        if self.calendar_type == "24x7":
            return "always_open"
        elif self.calendar_type == "us_equity":
            return self._us_equity_session(now).value
        elif self.calendar_type == "fx":
            return self._fx_session(now).value
        return "unknown"

    def next_open(self, now: datetime | None = None) -> datetime | None:
        """When does the market next open?"""
        now = now or datetime.now(UTC)

        if self.calendar_type == "24x7":
            return now  # always open
        elif self.calendar_type == "us_equity":
            return self._next_us_equity_open(now)
        return None

    def next_close(self, now: datetime | None = None) -> datetime | None:
        """When does the market next close?"""
        now = now or datetime.now(UTC)

        if self.calendar_type == "24x7":
            return None  # never closes
        elif self.calendar_type == "us_equity":
            return self._next_us_equity_close(now)
        return None

    # ---- US Equity ----

    def _us_equity_is_open(self, now: datetime) -> bool:
        et_now = now.astimezone(ET)

        # Weekend
        if et_now.weekday() >= 5:
            return False

        # Holiday
        if et_now.date() in US_HOLIDAYS_2026:
            return False

        # Regular hours: 9:30 - 16:00 ET
        market_open = time(9, 30)
        market_close = time(16, 0)
        return market_open <= et_now.time() < market_close

    def _us_equity_session(self, now: datetime) -> MarketSession:
        et_now = now.astimezone(ET)

        if et_now.weekday() >= 5 or et_now.date() in US_HOLIDAYS_2026:
            return MarketSession.CLOSED

        t = et_now.time()
        if time(4, 0) <= t < time(9, 30):
            return MarketSession.PRE_MARKET
        elif time(9, 30) <= t < time(16, 0):
            return MarketSession.REGULAR
        elif time(16, 0) <= t < time(20, 0):
            return MarketSession.POST_MARKET
        else:
            return MarketSession.CLOSED

    def _next_us_equity_open(self, now: datetime) -> datetime:
        et_now = now.astimezone(ET)
        d = et_now.date()

        # If before market open today and it's a trading day
        if et_now.time() < time(9, 30) and d.weekday() < 5 and d not in US_HOLIDAYS_2026:
            return datetime.combine(d, time(9, 30), tzinfo=ET)

        # Find next trading day
        d += timedelta(days=1)
        while d.weekday() >= 5 or d in US_HOLIDAYS_2026:
            d += timedelta(days=1)
        return datetime.combine(d, time(9, 30), tzinfo=ET)

    def _next_us_equity_close(self, now: datetime) -> datetime:
        et_now = now.astimezone(ET)
        d = et_now.date()

        if et_now.time() < time(16, 0) and d.weekday() < 5 and d not in US_HOLIDAYS_2026:
            return datetime.combine(d, time(16, 0), tzinfo=ET)

        d += timedelta(days=1)
        while d.weekday() >= 5 or d in US_HOLIDAYS_2026:
            d += timedelta(days=1)
        return datetime.combine(d, time(16, 0), tzinfo=ET)

    # ---- FX ----

    def _fx_is_open(self, now: datetime) -> bool:
        et_now = now.astimezone(ET)
        weekday = et_now.weekday()  # 0=Mon, 6=Sun

        # Closed Sat all day, Sun until 5 PM ET, Fri after 5 PM ET
        if weekday == 5:  # Saturday
            return False
        if weekday == 6 and et_now.time() < time(17, 0):  # Sunday before 5PM
            return False
        if weekday == 4 and et_now.time() >= time(17, 0):  # Friday after 5PM
            return False
        return True

    def _fx_session(self, now: datetime) -> FXSession:
        utc_hour = now.hour if now.tzinfo == UTC else now.astimezone(UTC).hour

        # Approximate session times (UTC)
        if 22 <= utc_hour or utc_hour < 7:
            return FXSession.SYDNEY if utc_hour < 3 else FXSession.TOKYO
        elif 7 <= utc_hour < 12:
            return FXSession.LONDON
        elif 12 <= utc_hour < 16:
            return FXSession.OVERLAP_LONDON_NY
        else:
            return FXSession.NEW_YORK


# Pre-built calendars
CALENDARS = {
    "24x7": TradingCalendar("24x7"),
    "us_equity": TradingCalendar("us_equity"),
    "fx": TradingCalendar("fx"),
}


def get_calendar(calendar_type: str) -> TradingCalendar:
    return CALENDARS.get(calendar_type, TradingCalendar(calendar_type))
