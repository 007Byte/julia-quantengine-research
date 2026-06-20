"""
Polymarket adapter — CLOB-based prediction market execution.

Operationally distinct from other adapters:
- EIP-712 typed data signing for order placement
- Key custody / signing flow (non-custodial)
- Polygon chain settlement awareness
- Geoblock checks BEFORE order placement
- Binary YES/NO share model
- Fee zone awareness (spread near 0/1 boundaries)
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import time
from decimal import Decimal
from typing import Any

import httpx

from src.execution.base_adapter import BaseAdapter, ConnectionState

logger = logging.getLogger(__name__)

POLYMARKET_API = "https://clob.polymarket.com"
GAMMA_API = "https://gamma-api.polymarket.com"

# US and restricted geoblock regions
BLOCKED_REGIONS = {
    "US", "UM",  # United States + minor outlying islands
    "BY",  # Belarus
    "CU",  # Cuba
    "IR",  # Iran
    "KP",  # North Korea
    "SY",  # Syria
}


class GeoblockViolation(Exception):
    """Raised when order would violate geographic restrictions."""
    pass


class SigningError(Exception):
    """Raised when EIP-712 signing fails."""
    pass


class PolymarketAdapter(BaseAdapter):
    """
    Polymarket CLOB venue adapter.

    Non-custodial: orders are signed client-side using EIP-712.
    Settlement occurs on Polygon chain.
    """

    def __init__(
        self,
        team_id: str,
        api_key: str,
        signing_key: str,
        api_secret: str = "",
        passphrase: str = "",
        region_code: str = "",
    ) -> None:
        super().__init__(venue="polymarket", team_id=team_id)
        self._api_key = api_key
        self._signing_key = signing_key
        self._api_secret = api_secret
        self._passphrase = passphrase
        self._region_code = region_code
        self._http: httpx.AsyncClient | None = None
        self._geoblock_verified = False

    def _headers(self) -> dict[str, str]:
        h: dict[str, str] = {"POLY_API_KEY": self._api_key}
        if self._api_secret:
            h["POLY_API_SECRET"] = self._api_secret
        if self._passphrase:
            h["POLY_PASSPHRASE"] = self._passphrase
        return h

    async def _request(
        self, method: str, path: str, params: dict | None = None, json_body: dict | None = None
    ) -> Any:
        if self._http is None:
            raise RuntimeError("Not connected")
        url = f"{POLYMARKET_API}{path}"
        resp = await self._http.request(
            method, url, params=params, json=json_body, headers=self._headers()
        )
        resp.raise_for_status()
        return resp.json()

    # ---- Geoblock enforcement ----

    def verify_geoblock(self) -> None:
        """
        Check region before ANY order placement.
        Must be called at startup and before each order.
        """
        if self._region_code in BLOCKED_REGIONS:
            raise GeoblockViolation(
                f"Region '{self._region_code}' is blocked from Polymarket trading. "
                f"Blocked regions: {BLOCKED_REGIONS}"
            )
        self._geoblock_verified = True

    def _enforce_geoblock(self) -> None:
        if not self._geoblock_verified:
            self.verify_geoblock()
        if self._region_code in BLOCKED_REGIONS:
            raise GeoblockViolation(f"Region blocked: {self._region_code}")

    # ---- EIP-712 signing ----

    def _sign_order(self, order_data: dict[str, Any]) -> str:
        """
        Sign order using EIP-712 typed data.

        In production this uses eth_account + the actual EIP-712 domain/types.
        For now: deterministic HMAC placeholder that will be replaced
        with proper eth_account signing in deployment.
        """
        if not self._signing_key:
            raise SigningError("No signing key configured")

        # Canonical serialization for signing
        canonical = json.dumps(order_data, sort_keys=True, separators=(",", ":"))
        signature = hashlib.sha256(
            (self._signing_key + canonical).encode()
        ).hexdigest()

        return f"0x{signature}"

    # ---- Connection lifecycle ----

    async def connect(self) -> None:
        self._state = ConnectionState.CONNECTING
        self._http = httpx.AsyncClient(timeout=30.0)

        # Verify geoblock at connection time
        try:
            self.verify_geoblock()
        except GeoblockViolation:
            logger.error("Geoblock check failed — cannot connect to Polymarket")
            self._state = ConnectionState.FAILED
            raise

        # Verify API connectivity
        try:
            result = await self._request("GET", "/time")
            logger.info("Polymarket connected. Server time: %s", result)
        except Exception as e:
            logger.warning("Polymarket connection check: %s (may be OK for paper)", e)

        self._state = ConnectionState.CONNECTED
        logger.info("Polymarket adapter connected (region=%s)", self._region_code or "unset")

    async def disconnect(self) -> None:
        if self._http:
            await self._http.aclose()
        self._state = ConnectionState.DISCONNECTED

    async def reconnect(self) -> None:
        self._state = ConnectionState.RECONNECTING
        await self.disconnect()
        await asyncio.sleep(1)
        await self.connect()

    async def subscribe(self, symbols: list[str]) -> None:
        # Polymarket uses condition_id / token_id, not traditional symbols
        logger.info("Polymarket: tracking %d markets", len(symbols))

    # ---- Order operations ----

    async def submit_order(
        self,
        venue_symbol: str,
        side: str,
        order_type: str,
        quantity: Decimal,
        limit_price: Decimal | None = None,
        client_order_id: str | None = None,
    ) -> dict[str, Any]:
        # Enforce geoblock on EVERY order
        self._enforce_geoblock()

        if limit_price is None:
            raise ValueError("Polymarket requires limit orders (CLOB)")

        # Build order payload
        order_data = {
            "tokenID": venue_symbol,
            "side": "BUY" if side.lower() == "buy" else "SELL",
            "price": str(limit_price),
            "size": str(quantity),
            "type": "GTC",
        }

        # Sign the order
        signature = self._sign_order(order_data)
        order_data["signature"] = signature

        result = await self._request("POST", "/order", json_body=order_data)

        logger.info(
            "Polymarket order: %s %s %s @ %s -> id=%s",
            venue_symbol, side, quantity, limit_price,
            result.get("id", result.get("orderID", "?")),
        )
        return {
            "broker_order_id": result.get("id", result.get("orderID", "")),
            "status": result.get("status", "LIVE"),
            "raw": result,
        }

    async def cancel_order(self, broker_order_id: str) -> dict[str, Any]:
        try:
            result = await self._request("DELETE", f"/order/{broker_order_id}")
            return {"broker_order_id": broker_order_id, "status": "CANCELED"}
        except httpx.HTTPStatusError as e:
            return {"broker_order_id": broker_order_id, "status": "CANCEL_FAILED", "error": str(e)}

    async def cancel_all(self, venue_symbol: str | None = None) -> list[dict[str, Any]]:
        try:
            result = await self._request("DELETE", "/orders")
            return result if isinstance(result, list) else []
        except Exception:
            return []

    # ---- Reconciliation queries ----

    async def get_open_orders(self) -> list[dict[str, Any]]:
        result = await self._request("GET", "/orders", params={"state": "LIVE"})
        orders = result if isinstance(result, list) else result.get("orders", [])
        return [
            {
                "broker_order_id": o.get("id", o.get("orderID", "")),
                "symbol": o.get("tokenID", o.get("asset_id", "")),
                "side": o.get("side", "").lower(),
                "quantity": o.get("original_size", o.get("size", "0")),
                "filled_quantity": o.get("size_matched", "0"),
                "status": o.get("status", "LIVE"),
                "type": "LIMIT",
            }
            for o in orders
        ]

    async def get_positions(self) -> list[dict[str, Any]]:
        # Polymarket positions are token balances
        try:
            result = await self._request("GET", "/positions")
            positions = result if isinstance(result, list) else result.get("positions", [])
            return [
                {
                    "symbol": p.get("asset_id", p.get("tokenID", "")),
                    "quantity": Decimal(str(p.get("size", 0))),
                    "avg_price": Decimal(str(p.get("avg_price", 0))),
                    "market_id": p.get("market", p.get("condition_id", "")),
                    "outcome": p.get("outcome", ""),
                }
                for p in positions
                if Decimal(str(p.get("size", 0))) != 0
            ]
        except Exception:
            return []

    async def get_balances(self) -> dict[str, Any]:
        try:
            result = await self._request("GET", "/balance")
            return {
                "USDC": {
                    "available": Decimal(str(result.get("balance", 0))),
                    "total": Decimal(str(result.get("balance", 0))),
                }
            }
        except Exception:
            return {"USDC": {"available": Decimal("0"), "total": Decimal("0")}}

    async def poll_order_status(self, broker_order_id: str) -> dict[str, Any]:
        result = await self._request("GET", f"/order/{broker_order_id}")
        return {
            "broker_order_id": broker_order_id,
            "status": result.get("status", "UNKNOWN"),
            "filled_qty": result.get("size_matched", "0"),
        }

    # ---- Market data helpers ----

    async def get_markets(self, limit: int = 100) -> list[dict[str, Any]]:
        """Get active prediction markets from Gamma API."""
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.get(
                f"{GAMMA_API}/markets",
                params={"limit": limit, "active": True, "closed": False},
            )
            resp.raise_for_status()
            return resp.json()

    async def get_market_price(self, token_id: str) -> dict[str, Any]:
        """Get current mid price for a token."""
        result = await self._request("GET", "/midpoint", params={"token_id": token_id})
        return result

    # ---- Normalization ----

    def normalize_order_event(self, raw_event: dict[str, Any]) -> dict[str, Any]:
        status_map = {
            "LIVE": "acknowledged",
            "MATCHED": "filled",
            "CANCELLED": "canceled",
            "EXPIRED": "expired",
        }
        return {
            "broker_order_id": raw_event.get("id", ""),
            "venue_state": status_map.get(raw_event.get("status", ""), "unknown_but_open"),
            "side": raw_event.get("side", "").lower(),
            "quantity": raw_event.get("original_size", "0"),
            "filled_qty": raw_event.get("size_matched", "0"),
            "price": raw_event.get("price", "0"),
        }

    def normalize_fill(self, raw_fill: dict[str, Any]) -> dict[str, Any]:
        return {
            "broker_order_id": raw_fill.get("order_id", ""),
            "trade_id": raw_fill.get("id", ""),
            "price": raw_fill.get("price", "0"),
            "quantity": raw_fill.get("size", "0"),
            "fee": raw_fill.get("fee", "0"),
            "fee_currency": "USDC",
            "side": raw_fill.get("side", "").lower(),
            "time": raw_fill.get("created_at", ""),
        }
