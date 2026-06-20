"""
Binance adapter — REST + WebSocket state synchronizer.

Supports spot and futures. Handles:
- Connection lifecycle with reconnect
- Order submission/cancellation
- Fill and order event normalization
- Position and balance queries for reconciliation
- Rate limit handling
- Funding rate awareness
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import logging
import time
from decimal import Decimal
from typing import Any
from urllib.parse import urlencode

import httpx
import websockets

from src.execution.base_adapter import BaseAdapter, ConnectionState

logger = logging.getLogger(__name__)

# Binance REST endpoints
SPOT_BASE = "https://api.binance.us"
FUTURES_BASE = "https://fapi.binance.com"


class BinanceAdapter(BaseAdapter):
    """
    Binance venue adapter.

    Phase 1 target: Binance US spot + Binance futures.
    """

    def __init__(
        self,
        team_id: str,
        api_key: str,
        api_secret: str,
        use_futures: bool = False,
        testnet: bool = False,
    ) -> None:
        super().__init__(venue="binance", team_id=team_id)
        self._api_key = api_key
        self._api_secret = api_secret
        self._use_futures = use_futures
        self._testnet = testnet
        self._base_url = FUTURES_BASE if use_futures else SPOT_BASE
        self._ws: Any = None
        self._ws_task: asyncio.Task | None = None
        self._http: httpx.AsyncClient | None = None
        self._listen_key: str | None = None
        self._handlers: dict[str, Any] = {}

    def _sign(self, params: dict[str, Any]) -> dict[str, Any]:
        params["timestamp"] = int(time.time() * 1000)
        query = urlencode(params)
        signature = hmac.new(
            self._api_secret.encode(),
            query.encode(),
            hashlib.sha256,
        ).hexdigest()
        params["signature"] = signature
        return params

    def _headers(self) -> dict[str, str]:
        return {"X-MBX-APIKEY": self._api_key}

    async def _request(
        self, method: str, path: str, params: dict | None = None, signed: bool = False
    ) -> dict[str, Any]:
        if self._http is None:
            raise RuntimeError("Not connected")
        p = params or {}
        if signed:
            p = self._sign(p)
        url = f"{self._base_url}{path}"
        resp = await self._http.request(method, url, params=p, headers=self._headers())
        resp.raise_for_status()
        return resp.json()

    # ---- Connection lifecycle ----

    async def connect(self) -> None:
        self._state = ConnectionState.CONNECTING
        self._http = httpx.AsyncClient(timeout=30.0)

        # Get listen key for user data stream
        try:
            if self._use_futures:
                data = await self._request("POST", "/fapi/v1/listenKey", signed=True)
            else:
                data = await self._request("POST", "/api/v3/userDataStream")
            self._listen_key = data.get("listenKey")
        except Exception:
            logger.exception("Failed to get listen key")
            self._listen_key = None

        self._state = ConnectionState.CONNECTED
        logger.info("Binance adapter connected (futures=%s)", self._use_futures)

    async def disconnect(self) -> None:
        if self._ws_task and not self._ws_task.done():
            self._ws_task.cancel()
        if self._ws:
            await self._ws.close()
        if self._http:
            await self._http.aclose()
        self._state = ConnectionState.DISCONNECTED
        logger.info("Binance adapter disconnected")

    async def reconnect(self) -> None:
        self._state = ConnectionState.RECONNECTING
        await self.disconnect()
        await asyncio.sleep(1)
        await self.connect()

    # ---- Market data ----

    async def subscribe(self, symbols: list[str]) -> None:
        streams = []
        for s in symbols:
            sym = s.lower()
            streams.append(f"{sym}@trade")
            streams.append(f"{sym}@kline_1m")
        if self._listen_key:
            streams.append(self._listen_key)

        ws_url = f"wss://stream.binance.us:9443/stream?streams={'/'.join(streams)}"
        self._ws_task = asyncio.create_task(self._ws_loop(ws_url))
        logger.info("Subscribed to %d streams for %d symbols", len(streams), len(symbols))

    async def _ws_loop(self, url: str) -> None:
        while self._state in (ConnectionState.CONNECTED, ConnectionState.RECONNECTING):
            try:
                async with websockets.connect(url) as ws:
                    self._ws = ws
                    async for msg in ws:
                        await self._handle_ws_message(msg)
            except asyncio.CancelledError:
                return
            except Exception:
                logger.exception("WebSocket error, reconnecting in 5s")
                await asyncio.sleep(5)

    async def _handle_ws_message(self, raw: str) -> None:
        import orjson
        data = orjson.loads(raw)
        # Dispatch to registered handlers
        stream = data.get("stream", "")
        if stream in self._handlers:
            await self._handlers[stream](data.get("data", {}))

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
        params: dict[str, Any] = {
            "symbol": venue_symbol,
            "side": side.upper(),
            "type": order_type.upper(),
            "quantity": str(quantity),
        }
        if limit_price is not None:
            params["price"] = str(limit_price)
            params["timeInForce"] = "GTC"
        if client_order_id:
            params["newClientOrderId"] = client_order_id

        path = "/fapi/v1/order" if self._use_futures else "/api/v3/order"
        result = await self._request("POST", path, params=params, signed=True)

        logger.info(
            "Order submitted: %s %s %s %s @ %s -> broker_id=%s",
            venue_symbol, side, quantity, order_type,
            limit_price or "market", result.get("orderId"),
        )
        return {
            "broker_order_id": str(result.get("orderId", "")),
            "client_order_id": result.get("clientOrderId", ""),
            "status": result.get("status", "UNKNOWN"),
            "raw": result,
        }

    async def cancel_order(self, broker_order_id: str) -> dict[str, Any]:
        path = "/fapi/v1/order" if self._use_futures else "/api/v3/order"
        # Need symbol — look up from state
        result = await self._request(
            "DELETE", path,
            params={"orderId": broker_order_id},
            signed=True,
        )
        return {"broker_order_id": broker_order_id, "status": result.get("status", "UNKNOWN")}

    async def cancel_all(self, venue_symbol: str | None = None) -> list[dict[str, Any]]:
        if not venue_symbol:
            logger.warning("cancel_all requires a symbol on Binance")
            return []
        path = "/fapi/v1/allOpenOrders" if self._use_futures else "/api/v3/openOrders"
        result = await self._request("DELETE", path, params={"symbol": venue_symbol}, signed=True)
        return result if isinstance(result, list) else []

    # ---- Reconciliation queries ----

    async def get_open_orders(self) -> list[dict[str, Any]]:
        path = "/fapi/v1/openOrders" if self._use_futures else "/api/v3/openOrders"
        result = await self._request("GET", path, signed=True)
        return [
            {
                "broker_order_id": str(o["orderId"]),
                "symbol": o["symbol"],
                "side": o["side"].lower(),
                "quantity": o["origQty"],
                "filled_quantity": o.get("executedQty", "0"),
                "status": o["status"],
                "type": o["type"],
            }
            for o in result
        ]

    async def get_positions(self) -> list[dict[str, Any]]:
        if self._use_futures:
            result = await self._request("GET", "/fapi/v2/positionRisk", signed=True)
            return [
                {
                    "symbol": p["symbol"],
                    "quantity": Decimal(p["positionAmt"]),
                    "entry_price": Decimal(p["entryPrice"]),
                    "unrealized_pnl": Decimal(p["unRealizedProfit"]),
                }
                for p in result
                if Decimal(p["positionAmt"]) != 0
            ]
        else:
            # Spot — derive from account
            acct = await self._request("GET", "/api/v3/account", signed=True)
            return [
                {
                    "symbol": b["asset"],
                    "quantity": Decimal(b["free"]) + Decimal(b["locked"]),
                }
                for b in acct.get("balances", [])
                if Decimal(b["free"]) + Decimal(b["locked"]) > 0
            ]

    async def get_balances(self) -> dict[str, Any]:
        if self._use_futures:
            result = await self._request("GET", "/fapi/v2/balance", signed=True)
            return {
                b["asset"]: {
                    "available": Decimal(b["availableBalance"]),
                    "total": Decimal(b["balance"]),
                }
                for b in result
            }
        else:
            acct = await self._request("GET", "/api/v3/account", signed=True)
            return {
                b["asset"]: {
                    "available": Decimal(b["free"]),
                    "locked": Decimal(b["locked"]),
                    "total": Decimal(b["free"]) + Decimal(b["locked"]),
                }
                for b in acct.get("balances", [])
                if Decimal(b["free"]) + Decimal(b["locked"]) > 0
            }

    async def poll_order_status(self, broker_order_id: str) -> dict[str, Any]:
        path = "/fapi/v1/order" if self._use_futures else "/api/v3/order"
        result = await self._request(
            "GET", path,
            params={"orderId": broker_order_id},
            signed=True,
        )
        return {
            "broker_order_id": str(result["orderId"]),
            "status": result["status"],
            "filled_qty": result.get("executedQty", "0"),
            "avg_price": result.get("avgPrice", "0"),
        }

    # ---- Normalization ----

    def normalize_order_event(self, raw_event: dict[str, Any]) -> dict[str, Any]:
        e = raw_event
        status_map = {
            "NEW": "acknowledged",
            "PARTIALLY_FILLED": "partially_filled",
            "FILLED": "filled",
            "CANCELED": "canceled",
            "REJECTED": "rejected",
            "EXPIRED": "expired",
        }
        return {
            "broker_order_id": str(e.get("i", e.get("orderId", ""))),
            "venue_state": status_map.get(e.get("X", e.get("status", "")), "unknown_but_open"),
            "side": e.get("S", "").lower(),
            "quantity": e.get("q", "0"),
            "filled_qty": e.get("z", "0"),
            "price": e.get("p", "0"),
            "event_time": e.get("T", 0),
        }

    def normalize_fill(self, raw_fill: dict[str, Any]) -> dict[str, Any]:
        return {
            "broker_order_id": str(raw_fill.get("i", raw_fill.get("orderId", ""))),
            "trade_id": str(raw_fill.get("t", "")),
            "price": raw_fill.get("L", raw_fill.get("price", "0")),
            "quantity": raw_fill.get("l", raw_fill.get("qty", "0")),
            "fee": raw_fill.get("n", "0"),
            "fee_currency": raw_fill.get("N", ""),
            "side": raw_fill.get("S", "").lower(),
            "time": raw_fill.get("T", 0),
        }
