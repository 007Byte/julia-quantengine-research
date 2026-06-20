"""Unit tests for paper trading adapter."""

import asyncio
from decimal import Decimal

import pytest

from src.core.event_schema import AssetClass, InstrumentType
from src.core.instrument_master import Instrument, InstrumentMaster, SymbolMapping
from src.execution.paper_adapter import PaperAdapter


@pytest.fixture
def im() -> InstrumentMaster:
    master = InstrumentMaster()
    btc = Instrument(
        asset_class=AssetClass.CRYPTO,
        instrument_type=InstrumentType.SPOT,
        base_symbol="BTC",
        quote_symbol="USDT",
    )
    master.register(btc, [
        SymbolMapping(instrument_id=btc.instrument_id, venue="paper", venue_symbol="BTCUSDT"),
    ])
    return master


@pytest.fixture
def adapter(im: InstrumentMaster) -> PaperAdapter:
    return PaperAdapter(
        team_id="crypto",
        instrument_master=im,
        initial_balance=Decimal("100000"),
        slippage_bps=5,
    )


class TestPaperAdapter:
    @pytest.mark.asyncio
    async def test_connect(self, adapter: PaperAdapter):
        await adapter.connect()
        assert adapter.is_connected

    @pytest.mark.asyncio
    async def test_initial_balance(self, adapter: PaperAdapter):
        await adapter.connect()
        balances = await adapter.get_balances()
        assert balances["USD"]["total"] == Decimal("100000")

    @pytest.mark.asyncio
    async def test_market_buy(self, adapter: PaperAdapter):
        await adapter.connect()
        adapter.set_price("BTCUSDT", Decimal("50000"))

        result = await adapter.submit_order(
            venue_symbol="BTCUSDT",
            side="buy",
            order_type="MARKET",
            quantity=Decimal("1"),
        )

        assert result["status"] == "FILLED"
        positions = await adapter.get_positions()
        assert len(positions) == 1
        assert positions[0]["quantity"] == Decimal("1")

    @pytest.mark.asyncio
    async def test_market_sell(self, adapter: PaperAdapter):
        await adapter.connect()
        adapter.set_price("BTCUSDT", Decimal("50000"))

        # Buy first
        await adapter.submit_order("BTCUSDT", "buy", "MARKET", Decimal("1"))

        # Then sell
        adapter.set_price("BTCUSDT", Decimal("51000"))
        result = await adapter.submit_order("BTCUSDT", "sell", "MARKET", Decimal("1"))

        assert result["status"] == "FILLED"
        positions = await adapter.get_positions()
        assert len(positions) == 0  # flat

    @pytest.mark.asyncio
    async def test_slippage_applied(self, adapter: PaperAdapter):
        await adapter.connect()
        adapter.set_price("BTCUSDT", Decimal("50000"))

        result = await adapter.submit_order("BTCUSDT", "buy", "MARKET", Decimal("1"))

        fill_price = Decimal(result["fill_price"])
        # Buy slippage should be above market
        assert fill_price > Decimal("50000")
        # But not by much (5 bps = 0.05%)
        assert fill_price < Decimal("50050")

    @pytest.mark.asyncio
    async def test_limit_order_resting(self, adapter: PaperAdapter):
        await adapter.connect()
        adapter.set_price("BTCUSDT", Decimal("50000"))

        # Limit buy below market — should rest
        result = await adapter.submit_order(
            "BTCUSDT", "buy", "LIMIT", Decimal("1"),
            limit_price=Decimal("49000"),
        )

        assert result["status"] == "NEW"
        open_orders = await adapter.get_open_orders()
        assert len(open_orders) == 1

    @pytest.mark.asyncio
    async def test_limit_order_immediate_fill(self, adapter: PaperAdapter):
        await adapter.connect()
        adapter.set_price("BTCUSDT", Decimal("50000"))

        # Limit buy above market — should fill immediately
        result = await adapter.submit_order(
            "BTCUSDT", "buy", "LIMIT", Decimal("1"),
            limit_price=Decimal("51000"),
        )

        assert result["status"] == "FILLED"

    @pytest.mark.asyncio
    async def test_cancel_order(self, adapter: PaperAdapter):
        await adapter.connect()
        adapter.set_price("BTCUSDT", Decimal("50000"))

        result = await adapter.submit_order(
            "BTCUSDT", "buy", "LIMIT", Decimal("1"),
            limit_price=Decimal("49000"),
        )

        cancel = await adapter.cancel_order(result["broker_order_id"])
        assert cancel["status"] == "CANCELED"

        open_orders = await adapter.get_open_orders()
        assert len(open_orders) == 0

    @pytest.mark.asyncio
    async def test_cancel_all(self, adapter: PaperAdapter):
        await adapter.connect()
        adapter.set_price("BTCUSDT", Decimal("50000"))

        await adapter.submit_order("BTCUSDT", "buy", "LIMIT", Decimal("1"), Decimal("49000"))
        await adapter.submit_order("BTCUSDT", "buy", "LIMIT", Decimal("1"), Decimal("48000"))

        results = await adapter.cancel_all("BTCUSDT")
        assert len(results) == 2

    @pytest.mark.asyncio
    async def test_balance_decreases_on_buy(self, adapter: PaperAdapter):
        await adapter.connect()
        adapter.set_price("BTCUSDT", Decimal("50000"))

        await adapter.submit_order("BTCUSDT", "buy", "MARKET", Decimal("1"))

        balances = await adapter.get_balances()
        assert balances["USD"]["total"] < Decimal("100000")

    @pytest.mark.asyncio
    async def test_poll_order_status(self, adapter: PaperAdapter):
        await adapter.connect()
        adapter.set_price("BTCUSDT", Decimal("50000"))

        result = await adapter.submit_order("BTCUSDT", "buy", "MARKET", Decimal("1"))

        status = await adapter.poll_order_status(result["broker_order_id"])
        assert status["status"] == "FILLED"
