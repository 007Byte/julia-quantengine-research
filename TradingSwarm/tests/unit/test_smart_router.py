"""Tests for smart order router."""

import uuid
from decimal import Decimal
from unittest.mock import MagicMock

import pytest

from src.core.event_schema import AssetClass, InstrumentType
from src.core.instrument_master import Instrument, InstrumentMaster, SymbolMapping
from src.execution.base_adapter import ConnectionState
from src.monitoring.execution_metrics import ExecutionMetrics
from src.pipeline.smart_router import SmartRouter


@pytest.fixture
def im() -> InstrumentMaster:
    master = InstrumentMaster()
    btc = Instrument(
        instrument_id=uuid.UUID("00000000-0000-0000-0000-000000000001"),
        asset_class=AssetClass.CRYPTO,
        instrument_type=InstrumentType.SPOT,
        base_symbol="BTC",
        quote_symbol="USDT",
    )
    master.register(btc, [
        SymbolMapping(instrument_id=btc.instrument_id, venue="binance", venue_symbol="BTCUSDT"),
        SymbolMapping(instrument_id=btc.instrument_id, venue="paper", venue_symbol="BTCUSDT"),
    ])
    return master


@pytest.fixture
def metrics() -> ExecutionMetrics:
    return ExecutionMetrics()


class TestSmartRouter:
    def test_selects_connected_venue(self, im, metrics):
        adapter1 = MagicMock()
        adapter1.connection_state = ConnectionState.CONNECTED
        adapter2 = MagicMock()
        adapter2.connection_state = ConnectionState.DISCONNECTED

        router = SmartRouter(
            adapters={"binance": adapter1, "paper": adapter2},
            instrument_master=im,
            metrics=metrics,
        )

        venue = router.select_venue("00000000-0000-0000-0000-000000000001", "buy", Decimal("1"))
        assert venue == "binance"

    def test_no_venue_if_all_disconnected(self, im, metrics):
        adapter = MagicMock()
        adapter.connection_state = ConnectionState.DISCONNECTED

        router = SmartRouter(
            adapters={"binance": adapter},
            instrument_master=im,
            metrics=metrics,
        )

        venue = router.select_venue("00000000-0000-0000-0000-000000000001", "buy", Decimal("1"))
        assert venue is None

    def test_no_venue_for_unmapped_instrument(self, im, metrics):
        adapter = MagicMock()
        adapter.connection_state = ConnectionState.CONNECTED

        router = SmartRouter(
            adapters={"oanda": adapter},  # BTC not mapped to oanda
            instrument_master=im,
            metrics=metrics,
        )

        venue = router.select_venue("00000000-0000-0000-0000-000000000001", "buy", Decimal("1"))
        assert venue is None

    def test_available_venues(self, im, metrics):
        adapter1 = MagicMock()
        adapter1.connection_state = ConnectionState.CONNECTED
        adapter2 = MagicMock()
        adapter2.connection_state = ConnectionState.CONNECTED

        router = SmartRouter(
            adapters={"binance": adapter1, "paper": adapter2},
            instrument_master=im,
            metrics=metrics,
        )

        venues = router.get_available_venues("00000000-0000-0000-0000-000000000001")
        assert "binance" in venues
        assert "paper" in venues


class TestOrderSlicing:
    def test_small_order_no_slice(self):
        router = SmartRouter({}, InstrumentMaster(), ExecutionMetrics())
        slices = router.compute_slices(Decimal("10"))
        assert slices == [Decimal("10")]

    def test_large_order_splits(self):
        router = SmartRouter({}, InstrumentMaster(), ExecutionMetrics())
        slices = router.compute_slices(Decimal("100"), max_slice_pct=Decimal("0.25"), min_slices=4)
        assert len(slices) >= 4
        assert sum(slices) == Decimal("100")

    def test_slices_sum_to_total(self):
        router = SmartRouter({}, InstrumentMaster(), ExecutionMetrics())
        total = Decimal("1000")
        slices = router.compute_slices(total, max_slice_pct=Decimal("0.1"), min_slices=1)
        assert sum(slices) == total
