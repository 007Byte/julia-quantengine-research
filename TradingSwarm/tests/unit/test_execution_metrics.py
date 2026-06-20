"""Tests for execution quality metrics."""

import time
from decimal import Decimal

import pytest

from src.monitoring.execution_metrics import ExecutionMetrics, FillMetric


@pytest.fixture
def metrics() -> ExecutionMetrics:
    return ExecutionMetrics(window_size=100)


class TestExecutionMetrics:
    def test_empty_stats(self, metrics: ExecutionMetrics):
        stats = metrics.get_slippage_stats("binance")
        assert stats["count"] == 0

    def test_record_and_query_slippage(self, metrics: ExecutionMetrics):
        for i in range(10):
            metrics.record_fill(FillMetric(
                venue="binance", side="buy",
                expected_price=Decimal("50000"),
                actual_price=Decimal("50005"),  # 1 bps slippage
                quantity=Decimal("1"),
                latency_ms=50.0, timestamp=time.time(),
            ))

        stats = metrics.get_slippage_stats("binance")
        assert stats["count"] == 10
        assert stats["mean_bps"] == pytest.approx(1.0, abs=0.1)

    def test_latency_tracking(self, metrics: ExecutionMetrics):
        for ms in [10, 20, 30, 40, 50]:
            metrics.record_fill(FillMetric(
                venue="binance", side="buy",
                expected_price=Decimal("100"), actual_price=Decimal("100"),
                quantity=Decimal("1"),
                latency_ms=float(ms), timestamp=time.time(),
            ))

        stats = metrics.get_latency_stats("binance")
        assert stats["count"] == 5
        assert stats["mean_ms"] == 30.0
        assert stats["max_ms"] == 50.0

    def test_fill_rate(self, metrics: ExecutionMetrics):
        metrics.record_attempt("binance")
        metrics.record_attempt("binance")
        metrics.record_attempt("binance")
        metrics.record_fill(FillMetric(
            venue="binance", side="buy",
            expected_price=Decimal("100"), actual_price=Decimal("100"),
            quantity=Decimal("1"), latency_ms=10, timestamp=time.time(),
        ))
        metrics.record_fill(FillMetric(
            venue="binance", side="buy",
            expected_price=Decimal("100"), actual_price=Decimal("100"),
            quantity=Decimal("1"), latency_ms=10, timestamp=time.time(),
        ))

        rate = metrics.get_fill_rate("binance")
        assert rate == pytest.approx(2 / 3, abs=0.01)

    def test_rejection_rate(self, metrics: ExecutionMetrics):
        metrics.record_attempt("binance")
        metrics.record_attempt("binance")
        metrics.record_rejection("binance")

        rate = metrics.get_rejection_rate("binance")
        assert rate == 0.5

    def test_quality_acceptable_with_no_data(self, metrics: ExecutionMetrics):
        assert metrics.is_quality_acceptable("unknown_venue")

    def test_quality_degraded(self, metrics: ExecutionMetrics):
        for _ in range(20):
            metrics.record_fill(FillMetric(
                venue="bad_venue", side="buy",
                expected_price=Decimal("100"),
                actual_price=Decimal("101"),  # 100 bps — terrible
                quantity=Decimal("1"),
                latency_ms=10, timestamp=time.time(),
            ))

        assert not metrics.is_quality_acceptable("bad_venue", max_slippage_bps=50)

    def test_summary(self, metrics: ExecutionMetrics):
        metrics.record_attempt("binance")
        metrics.record_fill(FillMetric(
            venue="binance", side="buy",
            expected_price=Decimal("100"), actual_price=Decimal("100"),
            quantity=Decimal("1"), latency_ms=10, timestamp=time.time(),
        ))

        summary = metrics.summary()
        assert "binance" in summary
        assert summary["binance"]["quality_ok"] is True
