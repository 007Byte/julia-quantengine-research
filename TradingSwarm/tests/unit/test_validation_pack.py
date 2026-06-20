"""Tests for validation pack thresholds and measurement logic."""

import pytest

from src.pipeline.validation_pack import (
    THRESHOLDS,
    ValidationLevel,
    ValidationThreshold,
)


class TestThresholdEvaluation:
    def test_gte_passes(self):
        t = ValidationThreshold("test", "desc", 10.0, "gte", "count", ValidationLevel.PLUMBING)
        assert t.evaluate(10.0) is True
        assert t.evaluate(15.0) is True

    def test_gte_fails(self):
        t = ValidationThreshold("test", "desc", 10.0, "gte", "count", ValidationLevel.PLUMBING)
        assert t.evaluate(9.0) is False

    def test_lte_passes(self):
        t = ValidationThreshold("test", "desc", 15.0, "lte", "bps", ValidationLevel.PAPER)
        assert t.evaluate(10.0) is True
        assert t.evaluate(15.0) is True

    def test_lte_fails(self):
        t = ValidationThreshold("test", "desc", 15.0, "lte", "bps", ValidationLevel.PAPER)
        assert t.evaluate(16.0) is False

    def test_gt_boundary(self):
        t = ValidationThreshold("test", "desc", 0.0, "gt", "USD", ValidationLevel.PAPER)
        assert t.evaluate(0.0) is False
        assert t.evaluate(0.01) is True

    def test_eq(self):
        t = ValidationThreshold("test", "desc", 1.0, "eq", "bool", ValidationLevel.PLUMBING)
        assert t.evaluate(1.0) is True
        assert t.evaluate(0.0) is False

    def test_measured_value_recorded(self):
        t = ValidationThreshold("test", "desc", 10.0, "gte", "count", ValidationLevel.PLUMBING)
        t.evaluate(42.0)
        assert t.measured_value == 42.0
        assert t.measured_at is not None

    def test_to_dict(self):
        t = ValidationThreshold("test_metric", "A test", 5.0, "gte", "count", ValidationLevel.SHADOW)
        t.evaluate(7.0)
        d = t.to_dict()
        assert d["name"] == "test_metric"
        assert d["passed"] is True
        assert d["measured_value"] == 7.0


class TestThresholdRegistry:
    def test_all_thresholds_have_names(self):
        names = [t.name for t in THRESHOLDS]
        assert len(names) == len(set(names)), "Duplicate threshold names"

    def test_plumbing_thresholds_exist(self):
        plumbing = [t for t in THRESHOLDS if t.level == ValidationLevel.PLUMBING]
        assert len(plumbing) >= 5

    def test_shadow_thresholds_exist(self):
        shadow = [t for t in THRESHOLDS if t.level == ValidationLevel.SHADOW]
        assert len(shadow) >= 4

    def test_paper_thresholds_exist(self):
        paper = [t for t in THRESHOLDS if t.level == ValidationLevel.PAPER]
        assert len(paper) >= 5

    def test_pre_live_thresholds_exist(self):
        pre_live = [t for t in THRESHOLDS if t.level == ValidationLevel.PRE_LIVE]
        assert len(pre_live) >= 8

    def test_critical_thresholds_present(self):
        names = {t.name for t in THRESHOLDS}
        assert "shadow_hit_rate_5m" in names
        assert "paper_post_cost_expectancy" in names
        assert "paper_recon_clean_days" in names
        assert "live_kill_switch_drill" in names
        assert "live_runbooks_approved" in names

    def test_post_cost_expectancy_must_be_positive(self):
        t = next(t for t in THRESHOLDS if t.name == "paper_post_cost_expectancy")
        assert t.comparator == "gt"
        assert t.threshold == 0.0

    def test_hit_rate_threshold_is_above_coin_flip(self):
        t = next(t for t in THRESHOLDS if t.name == "shadow_hit_rate_5m")
        assert t.threshold >= 0.52  # must beat random


class TestScopeEnforcement:
    def test_allowed_scopes(self):
        from src.pipeline.runner import ALLOWED_SCOPES
        assert ("crypto", "binance") in ALLOWED_SCOPES
        assert ("crypto", "paper") in ALLOWED_SCOPES
        # Nothing else is allowed yet
        assert ("stocks", "alpaca") not in ALLOWED_SCOPES
        assert ("fx", "oanda") not in ALLOWED_SCOPES
        assert ("prediction", "polymarket") not in ALLOWED_SCOPES

    def test_allowed_instruments(self):
        from src.pipeline.runner import ALLOWED_INSTRUMENTS
        assert "crypto" in ALLOWED_INSTRUMENTS
        assert "BTCUSDT" in ALLOWED_INSTRUMENTS["crypto"]
        assert "ETHUSDT" in ALLOWED_INSTRUMENTS["crypto"]
        # Narrow lane — only 2 instruments
        assert len(ALLOWED_INSTRUMENTS["crypto"]) == 2
