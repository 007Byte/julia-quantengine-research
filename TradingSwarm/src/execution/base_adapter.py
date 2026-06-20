"""
Base Broker/Venue Adapter — state synchronizer interface.

Adapters are NOT thin wrappers. They are state synchronizers that must:
- Maintain connection lifecycle
- Normalize broker events to canonical schema
- Map internal/external IDs
- Handle rate limits, outages, backoff
- Support reconciliation queries
"""

from __future__ import annotations

import logging
from abc import ABC, abstractmethod
from decimal import Decimal
from enum import StrEnum
from typing import Any

logger = logging.getLogger(__name__)


class ConnectionState(StrEnum):
    DISCONNECTED = "disconnected"
    CONNECTING = "connecting"
    CONNECTED = "connected"
    RECONNECTING = "reconnecting"
    DEGRADED = "degraded"
    FAILED = "failed"


class BaseAdapter(ABC):
    """
    Every venue adapter must implement this interface.

    Section 12 of the architecture plan.
    """

    def __init__(self, venue: str, team_id: str) -> None:
        self.venue = venue
        self.team_id = team_id
        self._state = ConnectionState.DISCONNECTED

    @property
    def connection_state(self) -> ConnectionState:
        return self._state

    @property
    def is_connected(self) -> bool:
        return self._state == ConnectionState.CONNECTED

    # ---- Connection lifecycle ----

    @abstractmethod
    async def connect(self) -> None:
        """Establish connection to the venue."""
        ...

    @abstractmethod
    async def disconnect(self) -> None:
        """Gracefully disconnect."""
        ...

    @abstractmethod
    async def reconnect(self) -> None:
        """Reconnect after a failure."""
        ...

    # ---- Market data ----

    @abstractmethod
    async def subscribe(self, symbols: list[str]) -> None:
        """Subscribe to real-time data for symbols."""
        ...

    # ---- Order operations ----

    @abstractmethod
    async def submit_order(
        self,
        venue_symbol: str,
        side: str,
        order_type: str,
        quantity: Decimal,
        limit_price: Decimal | None = None,
        client_order_id: str | None = None,
    ) -> dict[str, Any]:
        """
        Submit an order to the venue.

        Returns dict with at minimum:
            broker_order_id: str
            status: str
        """
        ...

    @abstractmethod
    async def cancel_order(self, broker_order_id: str) -> dict[str, Any]:
        """Cancel a specific order."""
        ...

    @abstractmethod
    async def cancel_all(self, venue_symbol: str | None = None) -> list[dict[str, Any]]:
        """Cancel all orders, optionally filtered by symbol."""
        ...

    # ---- Reconciliation queries ----

    @abstractmethod
    async def get_open_orders(self) -> list[dict[str, Any]]:
        """Get all open orders from the venue."""
        ...

    @abstractmethod
    async def get_positions(self) -> list[dict[str, Any]]:
        """Get all positions from the venue."""
        ...

    @abstractmethod
    async def get_balances(self) -> dict[str, Any]:
        """Get account balances from the venue."""
        ...

    # ---- REST backfill ----

    @abstractmethod
    async def poll_order_status(self, broker_order_id: str) -> dict[str, Any]:
        """Poll for current status of a specific order."""
        ...

    # ---- Event normalization ----

    @abstractmethod
    def normalize_order_event(self, raw_event: dict[str, Any]) -> dict[str, Any]:
        """Normalize a raw venue event to canonical schema."""
        ...

    @abstractmethod
    def normalize_fill(self, raw_fill: dict[str, Any]) -> dict[str, Any]:
        """Normalize a raw fill to canonical schema."""
        ...
