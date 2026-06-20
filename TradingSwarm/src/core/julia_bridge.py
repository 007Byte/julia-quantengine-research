"""
Julia ZMQ bridge client — Lazy Pirate reliability pattern.

Provides:
- Request/reply with timeout and bounded retries
- Heartbeat monitoring
- Circuit breaker (opens after N failures, no new trades)
- Exponential backoff with jitter
"""

from __future__ import annotations

import asyncio
import logging
import random
import time
from enum import StrEnum
from typing import Any

import orjson
import zmq
import zmq.asyncio

from src.core.config import get_config

logger = logging.getLogger(__name__)


class CircuitState(StrEnum):
    CLOSED = "closed"      # normal operation
    OPEN = "open"          # failing, no requests
    HALF_OPEN = "half_open"  # testing recovery


class JuliaBridge:
    """
    Lazy Pirate client for Julia QuantEngine ZMQ server.

    Thread-safe via asyncio. Circuit breaker prevents cascading failures.
    """

    def __init__(self) -> None:
        cfg = get_config().julia
        self._endpoint = cfg.endpoint
        self._timeout_ms = cfg.request_timeout_ms
        self._heavy_timeout_ms = cfg.heavy_timeout_ms
        self._max_retries = cfg.max_retries
        self._hb_interval = cfg.heartbeat_interval_ms / 1000.0
        self._hb_timeout = cfg.heartbeat_timeout_ms / 1000.0

        # Circuit breaker
        self._circuit = CircuitState.CLOSED
        self._failure_count = 0
        self._failure_threshold = 5
        self._circuit_open_until = 0.0
        self._circuit_cooldown = 30.0  # seconds before half-open

        # ZMQ context
        self._ctx = zmq.asyncio.Context()
        self._socket: zmq.asyncio.Socket | None = None
        self._lock = asyncio.Lock()

    def _create_socket(self) -> zmq.asyncio.Socket:
        sock = self._ctx.socket(zmq.REQ)
        sock.setsockopt(zmq.LINGER, 0)
        sock.setsockopt(zmq.RCVTIMEO, self._timeout_ms)
        sock.setsockopt(zmq.SNDTIMEO, self._timeout_ms)
        sock.connect(self._endpoint)
        return sock

    def _close_socket(self) -> None:
        if self._socket is not None:
            self._socket.close()
            self._socket = None

    def _get_socket(self) -> zmq.asyncio.Socket:
        if self._socket is None:
            self._socket = self._create_socket()
        return self._socket

    def _record_success(self) -> None:
        self._failure_count = 0
        if self._circuit != CircuitState.CLOSED:
            logger.info("Circuit breaker CLOSED — Julia bridge recovered")
            self._circuit = CircuitState.CLOSED

    def _record_failure(self) -> None:
        self._failure_count += 1
        if self._failure_count >= self._failure_threshold:
            self._circuit = CircuitState.OPEN
            self._circuit_open_until = time.monotonic() + self._circuit_cooldown
            logger.warning(
                "Circuit breaker OPEN — Julia bridge failed %d times, "
                "cooldown %.0fs",
                self._failure_count, self._circuit_cooldown,
            )

    def _check_circuit(self) -> bool:
        """Returns True if request is allowed."""
        if self._circuit == CircuitState.CLOSED:
            return True
        if self._circuit == CircuitState.OPEN:
            if time.monotonic() > self._circuit_open_until:
                self._circuit = CircuitState.HALF_OPEN
                logger.info("Circuit breaker HALF_OPEN — testing Julia bridge")
                return True
            return False
        # HALF_OPEN — allow one request
        return True

    @property
    def is_healthy(self) -> bool:
        return self._circuit != CircuitState.OPEN

    @property
    def circuit_state(self) -> CircuitState:
        return self._circuit

    async def request(
        self,
        payload: dict[str, Any],
        timeout_ms: int | None = None,
    ) -> dict[str, Any]:
        """
        Send a request to Julia with Lazy Pirate retry logic.

        Raises RuntimeError if circuit is open or all retries exhausted.
        """
        if not self._check_circuit():
            raise RuntimeError(
                f"Julia bridge circuit breaker is OPEN — no new signals. "
                f"Reopens at {self._circuit_open_until:.0f}"
            )

        timeout = timeout_ms or self._timeout_ms
        data = orjson.dumps(payload)

        async with self._lock:
            for attempt in range(1, self._max_retries + 1):
                try:
                    sock = self._get_socket()
                    sock.setsockopt(zmq.RCVTIMEO, timeout)

                    await sock.send(data)
                    reply = await sock.recv()

                    result = orjson.loads(reply)
                    if result.get("type") == "error":
                        logger.warning("Julia returned error: %s", result.get("error"))

                    self._record_success()
                    return result

                except zmq.Again:
                    logger.warning(
                        "Julia bridge timeout (attempt %d/%d, %dms)",
                        attempt, self._max_retries, timeout,
                    )
                    # Destroy and recreate socket (Lazy Pirate pattern)
                    self._close_socket()
                    self._record_failure()

                    if attempt < self._max_retries:
                        # Exponential backoff with jitter
                        backoff = min(2 ** attempt, 8) + random.random()
                        await asyncio.sleep(backoff)

                except Exception as e:
                    logger.exception("Julia bridge error (attempt %d)", attempt)
                    self._close_socket()
                    self._record_failure()

                    if attempt < self._max_retries:
                        backoff = min(2 ** attempt, 8) + random.random()
                        await asyncio.sleep(backoff)

        raise RuntimeError(
            f"Julia bridge exhausted {self._max_retries} retries"
        )

    # ---- Typed request helpers ----

    async def heartbeat(self) -> dict[str, Any]:
        return await self.request({"type": "heartbeat"})

    async def compute_features(
        self,
        instrument_id: str,
        prices: list[float],
        volumes: list[float] | None = None,
        highs: list[float] | None = None,
        lows: list[float] | None = None,
        timeframe: str = "1d",
    ) -> dict[str, Any]:
        return await self.request({
            "type": "features",
            "instrument_id": instrument_id,
            "prices": prices,
            "volumes": volumes or [0.0] * len(prices),
            "highs": highs or prices,
            "lows": lows or prices,
            "timeframe": timeframe,
        })

    async def score_models(
        self,
        instrument_id: str,
        features: list[list[float]],
        model_ids: list[str],
        regime: str = "unknown",
    ) -> dict[str, Any]:
        return await self.request(
            {
                "type": "model_score",
                "instrument_id": instrument_id,
                "features": features,
                "model_ids": model_ids,
                "regime": regime,
            },
            timeout_ms=self._heavy_timeout_ms,
        )

    async def run_ensemble(
        self,
        instrument_id: str,
        features: list[list[float]],
        strategy_id: str = "default",
    ) -> dict[str, Any]:
        return await self.request(
            {
                "type": "ensemble",
                "instrument_id": instrument_id,
                "features": features,
                "strategy_id": strategy_id,
            },
            timeout_ms=self._heavy_timeout_ms,
        )

    async def close(self) -> None:
        async with self._lock:
            self._close_socket()
            self._ctx.term()


# Singleton
_bridge: JuliaBridge | None = None


def get_bridge() -> JuliaBridge:
    global _bridge
    if _bridge is None:
        _bridge = JuliaBridge()
    return _bridge
