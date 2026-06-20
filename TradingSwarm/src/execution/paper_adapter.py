"""
Paper Trading Adapter — simulated execution for dev/paper modes.

Provides realistic behavior:
- Simulated fills with configurable slippage
- Latency simulation
- Position and balance tracking
- Full reconciliation interface
"""

from __future__ import annotations

import asyncio
import logging
import random
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

from src.core.instrument_master import InstrumentMaster
from src.execution.base_adapter import BaseAdapter, ConnectionState

logger = logging.getLogger(__name__)


class PaperAdapter(BaseAdapter):
    """
    Paper trading adapter with simulated fills.

    Tracks positions and balances in memory.
    Provides the same reconciliation interface as real adapters.
    """

    def __init__(
        self,
        team_id: str,
        instrument_master: InstrumentMaster,
        initial_balance: Decimal = Decimal("100000"),
        slippage_bps: int = 5,
        fill_latency_ms: int = 50,
    ) -> None:
        super().__init__(venue="paper", team_id=team_id)
        self._im = instrument_master
        self._balance: dict[str, Decimal] = {"USD": initial_balance}
        self._positions: dict[str, Decimal] = {}  # symbol -> qty
        self._open_orders: dict[str, dict[str, Any]] = {}  # broker_id -> order
        self._order_counter = 0
        self._slippage_bps = slippage_bps
        self._fill_latency_ms = fill_latency_ms
        self._last_prices: dict[str, Decimal] = {}
        self._fill_history: list[dict[str, Any]] = []
        self._subscribers: list[str] = []

    # ---- Connection lifecycle ----

    async def connect(self) -> None:
        self._state = ConnectionState.CONNECTED
        logger.info("Paper adapter connected (balance: %s USD)", self._balance["USD"])

    async def disconnect(self) -> None:
        self._state = ConnectionState.DISCONNECTED

    async def reconnect(self) -> None:
        self._state = ConnectionState.CONNECTED

    async def subscribe(self, symbols: list[str]) -> None:
        self._subscribers = symbols
        logger.info("Paper adapter subscribed to %d symbols", len(symbols))

    # ---- Price simulation ----

    def set_price(self, symbol: str, price: Decimal) -> None:
        """Set the current market price for a symbol."""
        self._last_prices[symbol] = price

    def _get_fill_price(self, symbol: str, side: str) -> Decimal:
        """Get simulated fill price with slippage."""
        base_price = self._last_prices.get(symbol, Decimal("100"))
        slippage = base_price * Decimal(self._slippage_bps) / Decimal("10000")

        if side == "buy":
            return base_price + slippage
        else:
            return base_price - slippage

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
        # Simulate latency
        await asyncio.sleep(self._fill_latency_ms / 1000.0)

        self._order_counter += 1
        broker_order_id = f"PAPER-{self._order_counter:08d}"

        if order_type.upper() == "MARKET":
            # Immediate fill
            fill_price = self._get_fill_price(venue_symbol, side)
            return await self._immediate_fill(
                broker_order_id, venue_symbol, side, quantity, fill_price
            )

        elif order_type.upper() == "LIMIT" and limit_price is not None:
            # Check if limit would fill immediately
            current = self._last_prices.get(venue_symbol)
            if current:
                if (side == "buy" and limit_price >= current) or \
                   (side == "sell" and limit_price <= current):
                    fill_price = self._get_fill_price(venue_symbol, side)
                    return await self._immediate_fill(
                        broker_order_id, venue_symbol, side, quantity, fill_price
                    )

            # Otherwise, add as resting order
            self._open_orders[broker_order_id] = {
                "broker_order_id": broker_order_id,
                "client_order_id": client_order_id or "",
                "symbol": venue_symbol,
                "side": side,
                "type": order_type,
                "quantity": quantity,
                "limit_price": limit_price,
                "filled_quantity": Decimal("0"),
                "status": "NEW",
                "created_at": datetime.now(timezone.utc).isoformat(),
            }
            return {
                "broker_order_id": broker_order_id,
                "client_order_id": client_order_id or "",
                "status": "NEW",
            }

        return {
            "broker_order_id": broker_order_id,
            "status": "NEW",
        }

    async def _immediate_fill(
        self,
        broker_order_id: str,
        symbol: str,
        side: str,
        quantity: Decimal,
        fill_price: Decimal,
    ) -> dict[str, Any]:
        # Update positions
        current_qty = self._positions.get(symbol, Decimal("0"))
        if side == "buy":
            self._positions[symbol] = current_qty + quantity
            cost = fill_price * quantity
            self._balance["USD"] -= cost
        else:
            self._positions[symbol] = current_qty - quantity
            proceeds = fill_price * quantity
            self._balance["USD"] += proceeds

        # Clean up zero positions
        if self._positions.get(symbol) == Decimal("0"):
            del self._positions[symbol]

        fill = {
            "broker_order_id": broker_order_id,
            "trade_id": f"PAPER-FILL-{uuid.uuid4().hex[:8]}",
            "symbol": symbol,
            "side": side,
            "quantity": str(quantity),
            "price": str(fill_price),
            "fee": str(fill_price * quantity * Decimal("0.001")),
            "fee_currency": "USD",
            "time": datetime.now(timezone.utc).isoformat(),
        }
        self._fill_history.append(fill)

        logger.info(
            "Paper fill: %s %s %s @ %s (bal: %s USD)",
            side, quantity, symbol, fill_price, self._balance["USD"],
        )

        return {
            "broker_order_id": broker_order_id,
            "status": "FILLED",
            "fill_price": str(fill_price),
            "fill_quantity": str(quantity),
        }

    async def cancel_order(self, broker_order_id: str) -> dict[str, Any]:
        order = self._open_orders.pop(broker_order_id, None)
        if order:
            return {"broker_order_id": broker_order_id, "status": "CANCELED"}
        return {"broker_order_id": broker_order_id, "status": "NOT_FOUND"}

    async def cancel_all(self, venue_symbol: str | None = None) -> list[dict[str, Any]]:
        to_cancel = list(self._open_orders.keys())
        if venue_symbol:
            to_cancel = [
                k for k, v in self._open_orders.items()
                if v["symbol"] == venue_symbol
            ]
        results = []
        for oid in to_cancel:
            results.append(await self.cancel_order(oid))
        return results

    # ---- Reconciliation queries ----

    async def get_open_orders(self) -> list[dict[str, Any]]:
        return [
            {
                "broker_order_id": o["broker_order_id"],
                "symbol": o["symbol"],
                "side": o["side"],
                "quantity": str(o["quantity"]),
                "filled_quantity": str(o["filled_quantity"]),
                "status": o["status"],
                "type": o["type"],
            }
            for o in self._open_orders.values()
        ]

    async def get_positions(self) -> list[dict[str, Any]]:
        return [
            {"symbol": sym, "quantity": qty}
            for sym, qty in self._positions.items()
            if qty != Decimal("0")
        ]

    async def get_balances(self) -> dict[str, Any]:
        return {
            currency: {"available": amount, "total": amount}
            for currency, amount in self._balance.items()
        }

    async def poll_order_status(self, broker_order_id: str) -> dict[str, Any]:
        order = self._open_orders.get(broker_order_id)
        if order:
            return {
                "broker_order_id": broker_order_id,
                "status": order["status"],
                "filled_qty": str(order["filled_quantity"]),
            }
        # Check fill history
        for fill in self._fill_history:
            if fill["broker_order_id"] == broker_order_id:
                return {
                    "broker_order_id": broker_order_id,
                    "status": "FILLED",
                    "filled_qty": fill["quantity"],
                    "avg_price": fill["price"],
                }
        return {"broker_order_id": broker_order_id, "status": "UNKNOWN"}

    def normalize_order_event(self, raw_event: dict[str, Any]) -> dict[str, Any]:
        return raw_event

    def normalize_fill(self, raw_fill: dict[str, Any]) -> dict[str, Any]:
        return raw_fill
