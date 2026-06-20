"""Unit tests for factor exposure model."""

import uuid
from decimal import Decimal

import pytest

from src.control.factor_exposure import (
    DEFAULT_FACTORS,
    FACTORS,
    FactorExposureModel,
    InstrumentFactors,
    get_default_factors,
)


class TestInstrumentFactors:
    def test_get_known_factor(self):
        f = InstrumentFactors(uuid.uuid4(), {"crypto_beta": 1.0, "usd_exposure": 0.5})
        assert f.get("crypto_beta") == 1.0
        assert f.get("usd_exposure") == 0.5

    def test_get_unknown_factor_returns_zero(self):
        f = InstrumentFactors(uuid.uuid4(), {"crypto_beta": 1.0})
        assert f.get("nonexistent") == 0.0


class TestDefaultFactors:
    def test_crypto_spot(self):
        factors = get_default_factors("crypto_spot")
        assert "crypto_beta" in factors
        assert factors["crypto_beta"] == 1.0

    def test_equity(self):
        factors = get_default_factors("equity")
        assert "usd_exposure" in factors

    def test_unknown_type(self):
        factors = get_default_factors("unknown_type")
        assert "usd_exposure" in factors  # fallback


class TestFactorExposureModel:
    def test_register_and_retrieve(self):
        model = FactorExposureModel()
        iid = uuid.uuid4()
        model.register_instrument_factors(iid, {"crypto_beta": 1.0, "vol_sensitivity": 0.8})

        factors = model._instrument_factors.get(iid)
        assert factors is not None
        assert factors.get("crypto_beta") == 1.0
        assert factors.get("vol_sensitivity") == 0.8

    def test_set_factor_limit(self):
        model = FactorExposureModel()
        model.set_factor_limit("crypto_beta", Decimal("1000000"))
        assert model._factor_limits["crypto_beta"] == Decimal("1000000")

    def test_all_standard_factors_exist(self):
        assert len(FACTORS) >= 8
        assert "crypto_beta" in FACTORS
        assert "usd_exposure" in FACTORS
        assert "growth_beta" in FACTORS
        assert "rates_sensitivity" in FACTORS


class TestCrossTeamOverlap:
    """Tests for detecting instruments held by multiple teams."""

    def test_default_factors_cover_all_types(self):
        for asset_type in DEFAULT_FACTORS:
            factors = DEFAULT_FACTORS[asset_type]
            # Every type should have at least one factor
            assert len(factors) >= 1
