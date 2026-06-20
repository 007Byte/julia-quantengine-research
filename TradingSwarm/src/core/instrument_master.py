"""
Instrument Master + Symbology — canonical instrument registry.

Every tradable instrument gets a canonical instrument_id (UUID).
Symbol mapping resolves venue-specific symbols to/from canonical IDs.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

from pydantic import BaseModel, Field

from src.core.event_schema import AssetClass, InstrumentType


class Instrument(BaseModel):
    instrument_id: uuid.UUID = Field(default_factory=uuid.uuid4)
    asset_class: AssetClass
    instrument_type: InstrumentType
    base_symbol: str
    quote_symbol: str = ""
    underlier_instrument_id: uuid.UUID | None = None
    multiplier: Decimal = Decimal("1")
    tick_size: Decimal = Decimal("0.01")
    lot_size: Decimal = Decimal("1")
    min_order_size: Decimal | None = None
    max_order_size: Decimal | None = None
    expiry_date: datetime | None = None
    strike: Decimal | None = None
    option_type: str | None = None  # "call" | "put"
    settlement_type: str | None = None  # "cash" | "physical"
    trading_calendar: str = "24x7"
    currency_exposure: str = "USD"
    is_active: bool = True
    metadata: dict[str, Any] = Field(default_factory=dict)
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    updated_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


class SymbolMapping(BaseModel):
    instrument_id: uuid.UUID
    venue: str
    venue_symbol: str
    venue_metadata: dict[str, Any] = Field(default_factory=dict)


class InstrumentMaster:
    """
    In-memory instrument registry backed by Postgres.

    Provides:
    - canonical instrument lookup by ID
    - venue symbol <-> canonical ID resolution
    - instrument creation and updates
    """

    def __init__(self) -> None:
        self._instruments: dict[uuid.UUID, Instrument] = {}
        self._by_venue: dict[tuple[str, str], uuid.UUID] = {}  # (venue, venue_symbol) -> id
        self._venue_symbols: dict[uuid.UUID, dict[str, str]] = {}  # id -> {venue: symbol}

    # ----- Registration -----

    def register(self, instrument: Instrument, mappings: list[SymbolMapping] | None = None) -> None:
        self._instruments[instrument.instrument_id] = instrument
        for m in mappings or []:
            self._by_venue[(m.venue, m.venue_symbol)] = instrument.instrument_id
            self._venue_symbols.setdefault(instrument.instrument_id, {})[m.venue] = m.venue_symbol

    def add_mapping(self, mapping: SymbolMapping) -> None:
        if mapping.instrument_id not in self._instruments:
            raise ValueError(f"Unknown instrument: {mapping.instrument_id}")
        self._by_venue[(mapping.venue, mapping.venue_symbol)] = mapping.instrument_id
        self._venue_symbols.setdefault(mapping.instrument_id, {})[mapping.venue] = mapping.venue_symbol

    # ----- Lookups -----

    def get(self, instrument_id: uuid.UUID) -> Instrument | None:
        return self._instruments.get(instrument_id)

    def resolve_venue_symbol(self, venue: str, venue_symbol: str) -> uuid.UUID | None:
        """Venue symbol -> canonical instrument_id."""
        return self._by_venue.get((venue, venue_symbol))

    def get_venue_symbol(self, instrument_id: uuid.UUID, venue: str) -> str | None:
        """Canonical instrument_id -> venue symbol."""
        return self._venue_symbols.get(instrument_id, {}).get(venue)

    def list_active(self, asset_class: AssetClass | None = None) -> list[Instrument]:
        result = [i for i in self._instruments.values() if i.is_active]
        if asset_class:
            result = [i for i in result if i.asset_class == asset_class]
        return result

    def list_for_venue(self, venue: str) -> list[tuple[Instrument, str]]:
        """All active instruments mapped to a given venue."""
        result = []
        for (v, sym), iid in self._by_venue.items():
            if v == venue:
                inst = self._instruments.get(iid)
                if inst and inst.is_active:
                    result.append((inst, sym))
        return result

    # ----- Persistence helpers -----

    async def load_from_db(self, pool: Any) -> None:
        """Load instruments and mappings from Postgres into memory."""
        async with pool.acquire() as conn:
            rows = await conn.fetch("SELECT * FROM instrument_master WHERE is_active = true")
            for row in rows:
                inst = Instrument(
                    instrument_id=row["instrument_id"],
                    asset_class=row["asset_class"],
                    instrument_type=row["instrument_type"],
                    base_symbol=row["base_symbol"],
                    quote_symbol=row["quote_symbol"] or "",
                    underlier_instrument_id=row["underlier_instrument_id"],
                    multiplier=row["multiplier"] or Decimal("1"),
                    tick_size=row["tick_size"] or Decimal("0.01"),
                    lot_size=row["lot_size"] or Decimal("1"),
                    min_order_size=row["min_order_size"],
                    max_order_size=row["max_order_size"],
                    expiry_date=row["expiry_date"],
                    strike=row["strike"],
                    option_type=row["option_type"],
                    settlement_type=row["settlement_type"],
                    trading_calendar=row["trading_calendar"] or "24x7",
                    currency_exposure=row.get("currency_exposure", "USD"),
                    is_active=row["is_active"],
                    metadata=row["metadata"] or {},
                )
                self._instruments[inst.instrument_id] = inst

            mapping_rows = await conn.fetch("""
                SELECT sm.* FROM symbol_mapping sm
                JOIN instrument_master im ON sm.instrument_id = im.instrument_id
                WHERE im.is_active = true
            """)
            for row in mapping_rows:
                iid = row["instrument_id"]
                venue = row["venue"]
                sym = row["venue_symbol"]
                self._by_venue[(venue, sym)] = iid
                self._venue_symbols.setdefault(iid, {})[venue] = sym

    async def save_instrument(self, pool: Any, instrument: Instrument, mappings: list[SymbolMapping] | None = None) -> None:
        """Persist instrument + mappings to Postgres and register in memory."""
        async with pool.acquire() as conn:
            async with conn.transaction():
                await conn.execute("""
                    INSERT INTO instrument_master (
                        instrument_id, asset_class, instrument_type, base_symbol,
                        quote_symbol, underlier_instrument_id, multiplier, tick_size,
                        lot_size, min_order_size, max_order_size, expiry_date,
                        strike, option_type, settlement_type, trading_calendar,
                        metadata, is_active
                    ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18)
                    ON CONFLICT (instrument_id) DO UPDATE SET
                        is_active = EXCLUDED.is_active,
                        metadata = EXCLUDED.metadata,
                        updated_at = NOW()
                """,
                    instrument.instrument_id,
                    instrument.asset_class.value,
                    instrument.instrument_type.value,
                    instrument.base_symbol,
                    instrument.quote_symbol,
                    instrument.underlier_instrument_id,
                    instrument.multiplier,
                    instrument.tick_size,
                    instrument.lot_size,
                    instrument.min_order_size,
                    instrument.max_order_size,
                    instrument.expiry_date,
                    instrument.strike,
                    instrument.option_type,
                    instrument.settlement_type,
                    instrument.trading_calendar,
                    instrument.metadata,
                    instrument.is_active,
                )

                for m in mappings or []:
                    await conn.execute("""
                        INSERT INTO symbol_mapping (instrument_id, venue, venue_symbol, venue_metadata)
                        VALUES ($1, $2, $3, $4)
                        ON CONFLICT (instrument_id, venue) DO UPDATE SET
                            venue_symbol = EXCLUDED.venue_symbol,
                            venue_metadata = EXCLUDED.venue_metadata
                    """, m.instrument_id, m.venue, m.venue_symbol, m.venue_metadata)

        self.register(instrument, mappings)
