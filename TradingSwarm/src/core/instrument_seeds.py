"""
Instrument seeds — register initial instruments for each team.

Crypto team: BTC, ETH, SOL spots + BTC/ETH perps on Binance
Stock team: liquid US equities on Alpaca
"""

from __future__ import annotations

from decimal import Decimal

from src.core.event_schema import AssetClass, InstrumentType
from src.core.instrument_master import Instrument, InstrumentMaster, SymbolMapping
from src.control.factor_exposure import FactorExposureModel, get_default_factors


def seed_crypto_instruments(im: InstrumentMaster, factor_model: FactorExposureModel) -> list[Instrument]:
    """Register core crypto instruments."""
    instruments = []

    specs = [
        ("BTC", "USDT", InstrumentType.SPOT, "BTCUSDT", Decimal("0.01"), Decimal("0.00001")),
        ("ETH", "USDT", InstrumentType.SPOT, "ETHUSDT", Decimal("0.01"), Decimal("0.0001")),
        ("SOL", "USDT", InstrumentType.SPOT, "SOLUSDT", Decimal("0.01"), Decimal("0.01")),
        ("BNB", "USDT", InstrumentType.SPOT, "BNBUSDT", Decimal("0.01"), Decimal("0.001")),
        ("XRP", "USDT", InstrumentType.SPOT, "XRPUSDT", Decimal("0.0001"), Decimal("0.1")),
    ]

    for base, quote, itype, binance_sym, tick, lot in specs:
        inst = Instrument(
            asset_class=AssetClass.CRYPTO,
            instrument_type=itype,
            base_symbol=base,
            quote_symbol=quote,
            tick_size=tick,
            lot_size=lot,
            trading_calendar="24x7",
            currency_exposure="USD",
        )
        mappings = [
            SymbolMapping(instrument_id=inst.instrument_id, venue="binance", venue_symbol=binance_sym),
            SymbolMapping(instrument_id=inst.instrument_id, venue="paper", venue_symbol=binance_sym),
        ]
        im.register(inst, mappings)
        factor_model.register_instrument_factors(
            inst.instrument_id,
            get_default_factors("crypto_spot"),
        )
        instruments.append(inst)

    return instruments


def seed_stock_instruments(im: InstrumentMaster, factor_model: FactorExposureModel) -> list[Instrument]:
    """Register core US equity instruments for the stock team."""
    instruments = []

    specs = [
        ("AAPL", Decimal("0.01"), Decimal("1"), {"growth_beta": 0.8, "momentum": 0.4}),
        ("MSFT", Decimal("0.01"), Decimal("1"), {"growth_beta": 0.7, "momentum": 0.3}),
        ("GOOGL", Decimal("0.01"), Decimal("1"), {"growth_beta": 0.9, "momentum": 0.5}),
        ("AMZN", Decimal("0.01"), Decimal("1"), {"growth_beta": 0.9, "momentum": 0.4}),
        ("NVDA", Decimal("0.01"), Decimal("1"), {"growth_beta": 1.2, "vol_sensitivity": 0.8, "momentum": 0.7}),
        ("TSLA", Decimal("0.01"), Decimal("1"), {"growth_beta": 1.5, "vol_sensitivity": 1.0, "momentum": 0.9}),
        ("META", Decimal("0.01"), Decimal("1"), {"growth_beta": 0.8, "momentum": 0.5}),
        ("JPM", Decimal("0.01"), Decimal("1"), {"value_beta": 0.7, "rates_sensitivity": 0.6}),
        ("SPY", Decimal("0.01"), Decimal("1"), {"growth_beta": 0.5, "value_beta": 0.5}),
        ("QQQ", Decimal("0.01"), Decimal("1"), {"growth_beta": 0.8, "momentum": 0.4}),
    ]

    for symbol, tick, lot, factors in specs:
        itype = InstrumentType.ETF if symbol in ("SPY", "QQQ") else InstrumentType.EQUITY
        aclass = AssetClass.ETF if symbol in ("SPY", "QQQ") else AssetClass.EQUITY

        inst = Instrument(
            asset_class=aclass,
            instrument_type=itype,
            base_symbol=symbol,
            quote_symbol="USD",
            tick_size=tick,
            lot_size=lot,
            trading_calendar="us_equity",
            currency_exposure="USD",
        )
        full_factors = {"usd_exposure": 1.0, **factors}
        mappings = [
            SymbolMapping(instrument_id=inst.instrument_id, venue="alpaca", venue_symbol=symbol),
            SymbolMapping(instrument_id=inst.instrument_id, venue="paper", venue_symbol=symbol),
        ]
        im.register(inst, mappings)
        factor_model.register_instrument_factors(inst.instrument_id, full_factors)
        instruments.append(inst)

    return instruments
