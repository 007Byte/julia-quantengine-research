"""Tests for Polymarket adapter — geoblock and key handling."""

import pytest

from src.execution.polymarket_adapter import (
    BLOCKED_REGIONS,
    GeoblockViolation,
    PolymarketAdapter,
    SigningError,
)


class TestGeoblock:
    def test_us_blocked(self):
        adapter = PolymarketAdapter(
            team_id="prediction", api_key="key", signing_key="sk", region_code="US"
        )
        with pytest.raises(GeoblockViolation, match="US"):
            adapter.verify_geoblock()

    def test_iran_blocked(self):
        adapter = PolymarketAdapter(
            team_id="prediction", api_key="key", signing_key="sk", region_code="IR"
        )
        with pytest.raises(GeoblockViolation):
            adapter.verify_geoblock()

    def test_north_korea_blocked(self):
        adapter = PolymarketAdapter(
            team_id="prediction", api_key="key", signing_key="sk", region_code="KP"
        )
        with pytest.raises(GeoblockViolation):
            adapter.verify_geoblock()

    def test_allowed_region_passes(self):
        adapter = PolymarketAdapter(
            team_id="prediction", api_key="key", signing_key="sk", region_code="GB"
        )
        adapter.verify_geoblock()
        assert adapter._geoblock_verified

    def test_empty_region_passes(self):
        adapter = PolymarketAdapter(
            team_id="prediction", api_key="key", signing_key="sk", region_code=""
        )
        adapter.verify_geoblock()

    def test_all_blocked_regions_defined(self):
        assert "US" in BLOCKED_REGIONS
        assert "CU" in BLOCKED_REGIONS
        assert "SY" in BLOCKED_REGIONS
        assert "BY" in BLOCKED_REGIONS
        assert len(BLOCKED_REGIONS) >= 6

    @pytest.mark.asyncio
    async def test_connect_fails_for_blocked_region(self):
        adapter = PolymarketAdapter(
            team_id="prediction", api_key="key", signing_key="sk", region_code="US"
        )
        with pytest.raises(GeoblockViolation):
            await adapter.connect()

    @pytest.mark.asyncio
    async def test_submit_order_enforces_geoblock(self):
        from decimal import Decimal
        adapter = PolymarketAdapter(
            team_id="prediction", api_key="key", signing_key="sk", region_code="US"
        )
        adapter._geoblock_verified = False
        with pytest.raises(GeoblockViolation):
            await adapter.submit_order("token123", "buy", "LIMIT", Decimal("10"), Decimal("0.55"))


class TestEIP712Signing:
    def test_signing_produces_hex(self):
        adapter = PolymarketAdapter(
            team_id="prediction", api_key="key", signing_key="my_secret_key"
        )
        order = {"tokenID": "abc", "side": "BUY", "price": "0.55", "size": "100"}
        sig = adapter._sign_order(order)
        assert sig.startswith("0x")
        assert len(sig) == 66  # 0x + 64 hex chars

    def test_signing_is_deterministic(self):
        adapter = PolymarketAdapter(
            team_id="prediction", api_key="key", signing_key="same_key"
        )
        order = {"tokenID": "abc", "side": "BUY", "price": "0.55", "size": "100"}
        sig1 = adapter._sign_order(order)
        sig2 = adapter._sign_order(order)
        assert sig1 == sig2

    def test_different_orders_different_signatures(self):
        adapter = PolymarketAdapter(
            team_id="prediction", api_key="key", signing_key="same_key"
        )
        sig1 = adapter._sign_order({"tokenID": "abc", "side": "BUY"})
        sig2 = adapter._sign_order({"tokenID": "xyz", "side": "SELL"})
        assert sig1 != sig2

    def test_no_signing_key_raises(self):
        adapter = PolymarketAdapter(
            team_id="prediction", api_key="key", signing_key=""
        )
        with pytest.raises(SigningError):
            adapter._sign_order({"tokenID": "abc"})

    @pytest.mark.asyncio
    async def test_submit_requires_limit_price(self):
        from decimal import Decimal
        adapter = PolymarketAdapter(
            team_id="prediction", api_key="key", signing_key="sk", region_code="GB"
        )
        adapter._geoblock_verified = True
        adapter._http = True  # fake connected
        with pytest.raises(ValueError, match="limit"):
            await adapter.submit_order("token123", "buy", "MARKET", Decimal("10"))
