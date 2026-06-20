"""
Data Ingest + Normalization — Service A.

Responsibilities:
- Connect to market/broker feeds
- Normalize payloads to canonical event schema
- Resolve venue symbols into canonical instrument_id
- Detect gaps/staleness
- Publish normalized events to durable event log
"""

from __future__ import annotations

import asyncio
import logging
import time
from decimal import Decimal
from typing import Any

from src.core.event_schema import NormalizedBar, NormalizedTrade, StreamEnvelope
from src.core.instrument_master import InstrumentMaster
from src.execution.base_adapter import BaseAdapter
from src.ledger import redis_streams

logger = logging.getLogger(__name__)


class DataIngestService:
    """
    Normalizes raw venue data into canonical events and publishes to Redis Streams.
    """

    def __init__(
        self,
        team_id: str,
        instrument_master: InstrumentMaster,
    ) -> None:
        self.team_id = team_id
        self._im = instrument_master
        self._adapters: dict[str, BaseAdapter] = {}
        self._last_event_time: dict[str, float] = {}  # instrument_id -> timestamp
        self._stale_threshold_seconds = 60.0

    def register_adapter(self, adapter: BaseAdapter) -> None:
        self._adapters[adapter.venue] = adapter

    async def start(self) -> None:
        """Connect all adapters and begin data flow."""
        for venue, adapter in self._adapters.items():
            await adapter.connect()
            instruments = self._im.list_for_venue(venue)
            symbols = [sym for _, sym in instruments]
            if symbols:
                await adapter.subscribe(symbols)
                logger.info(
                    "Ingest started: %s with %d symbols",
                    venue, len(symbols),
                )

    async def publish_bar(
        self,
        venue: str,
        venue_symbol: str,
        timeframe: str,
        time_val: str,
        open_: Decimal,
        high: Decimal,
        low: Decimal,
        close: Decimal,
        volume: Decimal,
    ) -> None:
        """Normalize and publish a bar event."""
        instrument_id = self._im.resolve_venue_symbol(venue, venue_symbol)
        if instrument_id is None:
            logger.warning("Unknown symbol: %s/%s", venue, venue_symbol)
            return

        from datetime import datetime, timezone
        bar = NormalizedBar(
            instrument_id=instrument_id,
            venue=venue,
            timeframe=timeframe,
            time=datetime.fromisoformat(time_val) if isinstance(time_val, str) else time_val,
            open=open_,
            high=high,
            low=low,
            close=close,
            volume=volume,
        )

        envelope = StreamEnvelope.wrap(
            "market.bar",
            bar,
            idempotency_key=f"bar:{instrument_id}:{venue}:{timeframe}:{time_val}",
        )
        await redis_streams.publish("market.normalized", envelope)

        self._last_event_time[str(instrument_id)] = time.time()

    async def publish_trade(
        self,
        venue: str,
        venue_symbol: str,
        price: Decimal,
        quantity: Decimal,
        trade_time: str,
        side: str | None = None,
    ) -> None:
        """Normalize and publish a trade event."""
        instrument_id = self._im.resolve_venue_symbol(venue, venue_symbol)
        if instrument_id is None:
            return

        from datetime import datetime, timezone
        from src.core.event_schema import Side

        trade = NormalizedTrade(
            instrument_id=instrument_id,
            venue=venue,
            time=datetime.fromisoformat(trade_time) if isinstance(trade_time, str) else trade_time,
            price=price,
            quantity=quantity,
            side=Side(side) if side else None,
        )

        envelope = StreamEnvelope.wrap("market.trade", trade)
        await redis_streams.publish("market.normalized", envelope)
        self._last_event_time[str(instrument_id)] = time.time()

    def detect_stale_feeds(self) -> list[str]:
        """Return instrument_ids with stale data."""
        now = time.time()
        stale = []
        for iid, last_time in self._last_event_time.items():
            if now - last_time > self._stale_threshold_seconds:
                stale.append(iid)
        if stale:
            logger.warning("Stale feeds detected: %s", stale)
        return stale

    async def stop(self) -> None:
        for adapter in self._adapters.values():
            await adapter.disconnect()
        logger.info("Data ingest stopped")
