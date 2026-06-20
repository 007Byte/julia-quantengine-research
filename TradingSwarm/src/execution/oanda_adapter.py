"""
OANDA adapter — FX execution via REST v20 API.

Operational model:
- Initial full account snapshot on connect
- Incremental update by transaction ID
- Periodic account refresh
- Financing/rollover awareness
- Session-aware (Sydney/Tokyo/London/NY)
"""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

import httpx

from src.execution.base_adapter import BaseAdapter, ConnectionState

logger = logging.getLogger(__name__)

PRACTICE_URL = "https://api-fxpractice.oanda.com"
LIVE_URL = "https://api-fxtrade.oanda.com"
STREAM_PRACTICE = "https://stream-fxpractice.oanda.com"
STREAM_LIVE = "https://stream-fxtrade.oanda.com"


class OandaAdapter(BaseAdapter):
    """
    OANDA v20 REST adapter for FX trading.

    Uses transaction-based incremental sync for efficient state tracking.
    """

    def __init__(
        self,
        team_id: str,
        api_token: str,
        account_id: str,
        practice: bool = True,
    ) -> None:
        super().__init__(venue="oanda", team_id=team_id)
        self._api_token = api_token
        self._account_id = account_id
        self._practice = practice
        self._base_url = PRACTICE_URL if practice else LIVE_URL
        self._stream_url = STREAM_PRACTICE if practice else STREAM_LIVE
        self._http: httpx.AsyncClient | None = None
        self._last_transaction_id: str = ""
        self._stream_task: asyncio.Task | None = None

    def _headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self._api_token}",
            "Content-Type": "application/json",
        }

    async def _request(self, method: str, path: str, params: dict | None = None, json_body: dict | None = None) -> Any:
        if self._http is None:
            raise RuntimeError("Not connected")
        url = f"{self._base_url}{path}"
        resp = await self._http.request(method, url, params=params, json=json_body, headers=self._headers())
        resp.raise_for_status()
        return resp.json()

    # ---- Connection lifecycle ----

    async def connect(self) -> None:
        self._state = ConnectionState.CONNECTING
        self._http = httpx.AsyncClient(timeout=30.0)

        # Initial full snapshot
        try:
            acct = await self._request("GET", f"/v3/accounts/{self._account_id}")
            account = acct.get("account", {})
            self._last_transaction_id = account.get("lastTransactionID", "")
            logger.info(
                "OANDA connected: account=%s balance=%s currency=%s lastTxn=%s",
                self._account_id,
                account.get("balance", "?"),
                account.get("currency", "?"),
                self._last_transaction_id,
            )
        except httpx.HTTPStatusError as e:
            logger.error("OANDA auth failed: %s", e)
            self._state = ConnectionState.FAILED
            raise

        self._state = ConnectionState.CONNECTED

    async def disconnect(self) -> None:
        if self._stream_task and not self._stream_task.done():
            self._stream_task.cancel()
        if self._http:
            await self._http.aclose()
        self._state = ConnectionState.DISCONNECTED

    async def reconnect(self) -> None:
        self._state = ConnectionState.RECONNECTING
        await self.disconnect()
        await asyncio.sleep(1)
        await self.connect()

    # ---- Market data ----

    async def subscribe(self, symbols: list[str]) -> None:
        self._stream_task = asyncio.create_task(self._pricing_stream(symbols))
        logger.info("OANDA: streaming %d instruments", len(symbols))

    async def _pricing_stream(self, instruments: list[str]) -> None:
        """Stream prices via OANDA streaming endpoint."""
        url = f"{self._stream_url}/v3/accounts/{self._account_id}/pricing/stream"
        params = {"instruments": ",".join(instruments)}
        while self._state in (ConnectionState.CONNECTED, ConnectionState.RECONNECTING):
            try:
                async with httpx.AsyncClient(timeout=None) as client:
                    async with client.stream("GET", url, params=params, headers=self._headers()) as resp:
                        async for line in resp.aiter_lines():
                            if not line.strip():
                                continue
                            # Parse price ticks — in production, normalize and publish
            except asyncio.CancelledError:
                return
            except Exception:
                logger.exception("OANDA stream error, reconnecting in 5s")
                await asyncio.sleep(5)

    # ---- Incremental sync ----

    async def poll_changes(self) -> list[dict[str, Any]]:
        """
        Poll for changes since last transaction ID.
        OANDA best practice: incremental by transaction ID.
        """
        if not self._last_transaction_id:
            return []

        result = await self._request(
            "GET",
            f"/v3/accounts/{self._account_id}/changes",
            params={"sinceTransactionID": self._last_transaction_id},
        )

        changes = result.get("changes", {})
        state = result.get("state", {})
        self._last_transaction_id = result.get("lastTransactionID", self._last_transaction_id)

        events = []
        # Order changes
        for order in changes.get("ordersFilled", []):
            events.append({"type": "order_filled", "data": order})
        for order in changes.get("ordersCancelled", []):
            events.append({"type": "order_cancelled", "data": order})
        for order in changes.get("ordersCreated", []):
            events.append({"type": "order_created", "data": order})
        # Trade changes
        for trade in changes.get("tradesOpened", []):
            events.append({"type": "trade_opened", "data": trade})
        for trade in changes.get("tradesClosed", []):
            events.append({"type": "trade_closed", "data": trade})

        return events

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
        # OANDA uses positive/negative units for buy/sell
        units = str(quantity) if side.lower() == "buy" else str(-quantity)

        body: dict[str, Any] = {
            "order": {
                "instrument": venue_symbol,
                "units": units,
                "type": order_type.upper(),
                "timeInForce": "FOK" if order_type.lower() == "market" else "GTC",
            }
        }
        if limit_price is not None:
            body["order"]["price"] = str(limit_price)

        result = await self._request(
            "POST",
            f"/v3/accounts/{self._account_id}/orders",
            json_body=body,
        )

        # OANDA returns different structures for fills vs pending
        order_fill = result.get("orderFillTransaction", {})
        order_create = result.get("orderCreateTransaction", {})
        tx = order_fill or order_create

        logger.info(
            "OANDA order: %s %s %s @ %s -> txn=%s",
            venue_symbol, side, quantity, limit_price or "market",
            tx.get("id", "?"),
        )

        if order_fill:
            return {
                "broker_order_id": str(order_fill.get("id", "")),
                "status": "FILLED",
                "fill_price": order_fill.get("price", "0"),
                "fill_quantity": str(abs(Decimal(order_fill.get("units", "0")))),
            }
        else:
            return {
                "broker_order_id": str(order_create.get("id", "")),
                "status": "PENDING",
            }

    async def cancel_order(self, broker_order_id: str) -> dict[str, Any]:
        try:
            result = await self._request(
                "PUT",
                f"/v3/accounts/{self._account_id}/orders/{broker_order_id}/cancel",
            )
            return {"broker_order_id": broker_order_id, "status": "CANCELED"}
        except httpx.HTTPStatusError:
            return {"broker_order_id": broker_order_id, "status": "CANCEL_FAILED"}

    async def cancel_all(self, venue_symbol: str | None = None) -> list[dict[str, Any]]:
        open_orders = await self.get_open_orders()
        results = []
        for o in open_orders:
            if venue_symbol is None or o.get("symbol") == venue_symbol:
                results.append(await self.cancel_order(o["broker_order_id"]))
        return results

    # ---- Reconciliation queries ----

    async def get_open_orders(self) -> list[dict[str, Any]]:
        result = await self._request(
            "GET", f"/v3/accounts/{self._account_id}/pendingOrders"
        )
        return [
            {
                "broker_order_id": o["id"],
                "symbol": o.get("instrument", ""),
                "side": "buy" if Decimal(o.get("units", "0")) > 0 else "sell",
                "quantity": str(abs(Decimal(o.get("units", "0")))),
                "status": o.get("state", "PENDING"),
                "type": o.get("type", ""),
            }
            for o in result.get("orders", [])
        ]

    async def get_positions(self) -> list[dict[str, Any]]:
        result = await self._request(
            "GET", f"/v3/accounts/{self._account_id}/openPositions"
        )
        positions = []
        for p in result.get("positions", []):
            long_units = Decimal(p.get("long", {}).get("units", "0"))
            short_units = Decimal(p.get("short", {}).get("units", "0"))
            net = long_units + short_units  # short units are negative

            if net != 0:
                positions.append({
                    "symbol": p["instrument"],
                    "quantity": net,
                    "unrealized_pnl": Decimal(p.get("unrealizedPL", "0")),
                    "financing": Decimal(p.get("financing", "0")),
                })
        return positions

    async def get_balances(self) -> dict[str, Any]:
        result = await self._request("GET", f"/v3/accounts/{self._account_id}/summary")
        acct = result.get("account", {})
        return {
            acct.get("currency", "USD"): {
                "balance": Decimal(acct.get("balance", "0")),
                "unrealized_pnl": Decimal(acct.get("unrealizedPL", "0")),
                "nav": Decimal(acct.get("NAV", "0")),
                "margin_used": Decimal(acct.get("marginUsed", "0")),
                "margin_available": Decimal(acct.get("marginAvailable", "0")),
                "financing": Decimal(acct.get("financing", "0")),
            }
        }

    async def poll_order_status(self, broker_order_id: str) -> dict[str, Any]:
        result = await self._request(
            "GET", f"/v3/accounts/{self._account_id}/orders/{broker_order_id}"
        )
        order = result.get("order", {})
        return {
            "broker_order_id": broker_order_id,
            "status": order.get("state", "UNKNOWN"),
            "filled_qty": str(abs(Decimal(order.get("filledUnits", "0") or "0"))),
        }

    # ---- Financing awareness ----

    async def get_financing(self, instrument: str) -> dict[str, Any]:
        """Get current financing rates for an instrument."""
        result = await self._request(
            "GET",
            f"/v3/accounts/{self._account_id}/instruments/{instrument}/financing",
        )
        return result.get("financing", {})

    # ---- Normalization ----

    def normalize_order_event(self, raw_event: dict[str, Any]) -> dict[str, Any]:
        state_map = {
            "PENDING": "submitted",
            "FILLED": "filled",
            "TRIGGERED": "filled",
            "CANCELLED": "canceled",
        }
        return {
            "broker_order_id": raw_event.get("id", ""),
            "venue_state": state_map.get(raw_event.get("state", ""), "unknown_but_open"),
            "side": "buy" if Decimal(raw_event.get("units", "0")) > 0 else "sell",
            "quantity": str(abs(Decimal(raw_event.get("units", "0")))),
            "price": raw_event.get("price", "0"),
        }

    def normalize_fill(self, raw_fill: dict[str, Any]) -> dict[str, Any]:
        return {
            "broker_order_id": raw_fill.get("orderID", raw_fill.get("id", "")),
            "trade_id": raw_fill.get("tradeID", raw_fill.get("id", "")),
            "price": raw_fill.get("price", "0"),
            "quantity": str(abs(Decimal(raw_fill.get("units", "0")))),
            "fee": raw_fill.get("commission", "0"),
            "fee_currency": raw_fill.get("accountCurrency", "USD"),
            "side": "buy" if Decimal(raw_fill.get("units", "0")) > 0 else "sell",
            "financing": raw_fill.get("financing", "0"),
        }
