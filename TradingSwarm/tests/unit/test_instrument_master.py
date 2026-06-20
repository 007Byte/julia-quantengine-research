"""Unit tests for instrument master and symbology."""

import uuid
from decimal import Decimal

import pytest

from src.core.event_schema import AssetClass, InstrumentType
from src.core.instrument_master import Instrument, InstrumentMaster, SymbolMapping


@pytest.fixture
def im() -> InstrumentMaster:
    return InstrumentMaster()


@pytest.fixture
def btc_instrument() -> Instrument:
    return Instrument(
        asset_class=AssetClass.CRYPTO,
        instrument_type=InstrumentType.SPOT,
        base_symbol="BTC",
        quote_symbol="USDT",
        tick_size=Decimal("0.01"),
        lot_size=Decimal("0.00001"),
    )


@pytest.fixture
def eth_instrument() -> Instrument:
    return Instrument(
        asset_class=AssetClass.CRYPTO,
        instrument_type=InstrumentType.PERPETUAL,
        base_symbol="ETH",
        quote_symbol="USDT",
        tick_size=Decimal("0.01"),
        lot_size=Decimal("0.001"),
    )


class TestInstrumentMaster:
    def test_register_and_lookup(self, im: InstrumentMaster, btc_instrument: Instrument):
        im.register(btc_instrument)
        result = im.get(btc_instrument.instrument_id)
        assert result is not None
        assert result.base_symbol == "BTC"

    def test_resolve_venue_symbol(self, im: InstrumentMaster, btc_instrument: Instrument):
        mapping = SymbolMapping(
            instrument_id=btc_instrument.instrument_id,
            venue="binance",
            venue_symbol="BTCUSDT",
        )
        im.register(btc_instrument, [mapping])

        resolved = im.resolve_venue_symbol("binance", "BTCUSDT")
        assert resolved == btc_instrument.instrument_id

    def test_get_venue_symbol(self, im: InstrumentMaster, btc_instrument: Instrument):
        mapping = SymbolMapping(
            instrument_id=btc_instrument.instrument_id,
            venue="binance",
            venue_symbol="BTCUSDT",
        )
        im.register(btc_instrument, [mapping])

        sym = im.get_venue_symbol(btc_instrument.instrument_id, "binance")
        assert sym == "BTCUSDT"

    def test_unknown_symbol_returns_none(self, im: InstrumentMaster):
        assert im.resolve_venue_symbol("binance", "FAKECOIN") is None

    def test_list_active(self, im: InstrumentMaster, btc_instrument: Instrument, eth_instrument: Instrument):
        im.register(btc_instrument)
        im.register(eth_instrument)

        all_active = im.list_active()
        assert len(all_active) == 2

        crypto_only = im.list_active(AssetClass.CRYPTO)
        assert len(crypto_only) == 2

        equity = im.list_active(AssetClass.EQUITY)
        assert len(equity) == 0

    def test_multiple_venue_mappings(self, im: InstrumentMaster, btc_instrument: Instrument):
        binance_map = SymbolMapping(
            instrument_id=btc_instrument.instrument_id,
            venue="binance",
            venue_symbol="BTCUSDT",
        )
        alpaca_map = SymbolMapping(
            instrument_id=btc_instrument.instrument_id,
            venue="alpaca",
            venue_symbol="BTC/USD",
        )
        im.register(btc_instrument, [binance_map, alpaca_map])

        assert im.resolve_venue_symbol("binance", "BTCUSDT") == btc_instrument.instrument_id
        assert im.resolve_venue_symbol("alpaca", "BTC/USD") == btc_instrument.instrument_id
        assert im.get_venue_symbol(btc_instrument.instrument_id, "binance") == "BTCUSDT"
        assert im.get_venue_symbol(btc_instrument.instrument_id, "alpaca") == "BTC/USD"

    def test_add_mapping_fails_for_unknown_instrument(self, im: InstrumentMaster):
        mapping = SymbolMapping(
            instrument_id=uuid.uuid4(),
            venue="binance",
            venue_symbol="UNKNOWN",
        )
        with pytest.raises(ValueError):
            im.add_mapping(mapping)

    def test_list_for_venue(self, im: InstrumentMaster, btc_instrument: Instrument, eth_instrument: Instrument):
        im.register(btc_instrument, [
            SymbolMapping(instrument_id=btc_instrument.instrument_id, venue="binance", venue_symbol="BTCUSDT"),
        ])
        im.register(eth_instrument, [
            SymbolMapping(instrument_id=eth_instrument.instrument_id, venue="binance", venue_symbol="ETHUSDT"),
        ])

        binance_instruments = im.list_for_venue("binance")
        assert len(binance_instruments) == 2

        oanda_instruments = im.list_for_venue("oanda")
        assert len(oanda_instruments) == 0
