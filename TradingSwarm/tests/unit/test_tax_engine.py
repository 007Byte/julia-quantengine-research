"""Tests for advisory tax engine."""

from datetime import datetime, timedelta, timezone
from decimal import Decimal

import pytest

from src.tax.tax_engine import AdvisoryTaxEngine, TaxLot, WashSaleDetector, TAX_DISCLAIMER


class TestTaxLot:
    def test_cost_basis(self):
        lot = TaxLot("lot1", "AAPL", Decimal("10"), Decimal("150"), datetime.now(timezone.utc))
        assert lot.cost_basis == Decimal("1500")

    def test_short_term(self):
        lot = TaxLot("lot1", "AAPL", Decimal("10"), Decimal("150"),
                      datetime.now(timezone.utc) - timedelta(days=100))
        assert not lot.is_long_term
        assert lot.holding_days >= 100

    def test_long_term(self):
        lot = TaxLot("lot1", "AAPL", Decimal("10"), Decimal("150"),
                      datetime.now(timezone.utc) - timedelta(days=400))
        assert lot.is_long_term

    def test_unrealized_gain_is_none(self):
        lot = TaxLot("lot1", "AAPL", Decimal("10"), Decimal("150"), datetime.now(timezone.utc))
        assert lot.gain_loss is None

    def test_realized_gain(self):
        lot = TaxLot("lot1", "AAPL", Decimal("10"), Decimal("150"), datetime.now(timezone.utc))
        lot.proceeds_per_unit = Decimal("170")
        lot.closed_at = datetime.now(timezone.utc)
        assert lot.gain_loss == Decimal("200")

    def test_realized_loss(self):
        lot = TaxLot("lot1", "AAPL", Decimal("10"), Decimal("150"), datetime.now(timezone.utc))
        lot.proceeds_per_unit = Decimal("130")
        lot.closed_at = datetime.now(timezone.utc)
        assert lot.gain_loss == Decimal("-200")


class TestWashSaleDetector:
    def test_no_loss_no_wash(self):
        detector = WashSaleDetector()
        result = detector.check(
            datetime.now(timezone.utc), "AAPL", Decimal("100"), []
        )
        assert not result["wash_sale"]

    def test_loss_with_repurchase(self):
        detector = WashSaleDetector()
        sale_time = datetime.now(timezone.utc)
        purchases = [{"instrument_id": "AAPL", "time": sale_time - timedelta(days=10)}]
        result = detector.check(sale_time, "AAPL", Decimal("-500"), purchases)
        assert result["wash_sale"]

    def test_loss_without_repurchase(self):
        detector = WashSaleDetector()
        sale_time = datetime.now(timezone.utc)
        purchases = [{"instrument_id": "MSFT", "time": sale_time - timedelta(days=10)}]
        result = detector.check(sale_time, "AAPL", Decimal("-500"), purchases)
        assert not result["wash_sale"]

    def test_repurchase_outside_window(self):
        detector = WashSaleDetector()
        sale_time = datetime.now(timezone.utc)
        purchases = [{"instrument_id": "AAPL", "time": sale_time - timedelta(days=60)}]
        result = detector.check(sale_time, "AAPL", Decimal("-500"), purchases)
        assert not result["wash_sale"]


class TestAdvisoryTaxEngine:
    def test_add_and_close_fifo(self):
        engine = AdvisoryTaxEngine()
        engine.add_lot(TaxLot("lot1", "AAPL", Decimal("10"), Decimal("100"),
                               datetime.now(timezone.utc) - timedelta(days=50)))
        engine.add_lot(TaxLot("lot2", "AAPL", Decimal("10"), Decimal("120"),
                               datetime.now(timezone.utc) - timedelta(days=10)))

        closed = engine.close_lots_fifo("AAPL", Decimal("10"), Decimal("130"), datetime.now(timezone.utc))
        assert len(closed) == 1
        assert closed[0].lot_id == "lot1"  # FIFO: first lot closed first
        assert closed[0].gain_loss == Decimal("300")

    def test_partial_close(self):
        engine = AdvisoryTaxEngine()
        engine.add_lot(TaxLot("lot1", "AAPL", Decimal("20"), Decimal("100"), datetime.now(timezone.utc)))

        closed = engine.close_lots_fifo("AAPL", Decimal("5"), Decimal("110"), datetime.now(timezone.utc))
        assert len(closed) == 1
        assert closed[0].quantity == Decimal("5")
        assert closed[0].gain_loss == Decimal("50")

    def test_unrealized_summary(self):
        engine = AdvisoryTaxEngine()
        engine.add_lot(TaxLot("lot1", "AAPL", Decimal("10"), Decimal("150"), datetime.now(timezone.utc)))
        summary = engine.get_unrealized_summary()
        assert summary["open_lots"] == 1
        assert TAX_DISCLAIMER in summary["disclaimer"]

    def test_realized_summary_empty(self):
        engine = AdvisoryTaxEngine()
        summary = engine.get_realized_summary()
        assert summary["net_total"] == "0"
        assert TAX_DISCLAIMER in summary["disclaimer"]

    def test_disclaimer_always_present(self):
        assert "tax professional" in TAX_DISCLAIMER.lower()
