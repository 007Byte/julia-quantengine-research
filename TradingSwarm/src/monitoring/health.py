"""
Monitoring + Health endpoints.

Provides:
- Health check server (HTTP)
- Prometheus metrics
- Service health aggregation
- Critical alert detection
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any

import orjson
from prometheus_client import Counter, Gauge, Histogram, generate_latest

from src.core.config import get_config
from src.core.julia_bridge import get_bridge
from src.ledger import postgres, redis_streams

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Prometheus metrics
# ---------------------------------------------------------------------------

# Counters
ORDERS_SUBMITTED = Counter("qe_orders_submitted_total", "Orders submitted", ["team", "venue"])
FILLS_PROCESSED = Counter("qe_fills_processed_total", "Fills processed", ["team", "venue"])
RISK_DECISIONS = Counter("qe_risk_decisions_total", "Risk decisions", ["team", "decision"])
RECON_INCIDENTS = Counter("qe_recon_incidents_total", "Reconciliation incidents", ["team", "severity"])
STREAM_MESSAGES = Counter("qe_stream_messages_total", "Stream messages processed", ["stream"])
OUTBOX_PUBLISHED = Counter("qe_outbox_published_total", "Outbox messages published")

# Gauges
ACTIVE_ORDERS = Gauge("qe_active_orders", "Currently active orders", ["team"])
OPEN_POSITIONS = Gauge("qe_open_positions", "Open positions", ["team"])
PENDING_MESSAGES = Gauge("qe_pending_messages", "Pending stream messages", ["stream"])
GROSS_EXPOSURE = Gauge("qe_gross_exposure", "Current gross exposure", ["scope"])
DAILY_PNL = Gauge("qe_daily_pnl", "Daily PnL", ["team"])
JULIA_CIRCUIT = Gauge("qe_julia_circuit_state", "Julia bridge circuit breaker (0=closed, 1=half, 2=open)")
UNRESOLVED_INCIDENTS = Gauge("qe_unresolved_recon_incidents", "Unresolved reconciliation incidents", ["team"])

# Histograms
ORDER_LATENCY = Histogram("qe_order_latency_seconds", "Order submission latency", ["venue"])
JULIA_LATENCY = Histogram("qe_julia_latency_seconds", "Julia bridge request latency", ["request_type"])
RISK_EVAL_LATENCY = Histogram("qe_risk_eval_latency_seconds", "Risk evaluation latency")


# ---------------------------------------------------------------------------
# Health check types
# ---------------------------------------------------------------------------

class HealthStatus:
    def __init__(self) -> None:
        self.checks: dict[str, dict[str, Any]] = {}
        self.start_time = time.time()

    def record(self, name: str, healthy: bool, details: str = "") -> None:
        self.checks[name] = {
            "healthy": healthy,
            "details": details,
            "checked_at": time.time(),
        }

    @property
    def is_healthy(self) -> bool:
        return all(c["healthy"] for c in self.checks.values())

    def to_dict(self) -> dict[str, Any]:
        return {
            "healthy": self.is_healthy,
            "uptime_seconds": time.time() - self.start_time,
            "checks": self.checks,
        }


# ---------------------------------------------------------------------------
# Health check runner
# ---------------------------------------------------------------------------

async def run_health_checks() -> HealthStatus:
    """Run all health checks and return aggregated status."""
    status = HealthStatus()

    # Postgres
    try:
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            result = await conn.fetchval("SELECT 1")
        status.record("postgres", result == 1, "connected")
    except Exception as e:
        status.record("postgres", False, str(e))

    # Redis
    try:
        r = await redis_streams.get_redis()
        pong = await r.ping()
        status.record("redis", pong, "connected")
    except Exception as e:
        status.record("redis", False, str(e))

    # Redis AOF
    try:
        r = await redis_streams.get_redis()
        info = await r.info("persistence")
        aof_on = info.get("aof_enabled", 0)
        cfg = get_config()
        if cfg.is_live and not aof_on:
            status.record("redis_aof", False, "AOF disabled in live mode")
        else:
            status.record("redis_aof", True, f"aof_enabled={aof_on}")
    except Exception as e:
        status.record("redis_aof", False, str(e))

    # Julia bridge
    try:
        bridge = get_bridge()
        status.record("julia_bridge", bridge.is_healthy, f"circuit={bridge.circuit_state.value}")
    except Exception as e:
        status.record("julia_bridge", False, str(e))

    # Pending message backlogs
    try:
        counts = await redis_streams.get_pending_counts("service")
        high_backlog = {k: v for k, v in counts.items() if v > 100}
        if high_backlog:
            status.record("stream_backlog", False, f"high backlog: {high_backlog}")
        else:
            status.record("stream_backlog", True, f"all streams clear")
    except Exception as e:
        status.record("stream_backlog", False, str(e))

    return status


# ---------------------------------------------------------------------------
# HTTP health server
# ---------------------------------------------------------------------------

async def _handle_request(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    request = await reader.read(4096)
    request_line = request.decode().split("\r\n")[0] if request else ""
    path = request_line.split(" ")[1] if " " in request_line else "/"

    if path == "/health":
        status = await run_health_checks()
        body = orjson.dumps(status.to_dict())
        code = 200 if status.is_healthy else 503
        response = (
            f"HTTP/1.1 {code} {'OK' if code == 200 else 'Service Unavailable'}\r\n"
            f"Content-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n\r\n"
        ).encode() + body
    elif path == "/metrics":
        body = generate_latest()
        response = (
            f"HTTP/1.1 200 OK\r\n"
            f"Content-Type: text/plain; version=0.0.4\r\n"
            f"Content-Length: {len(body)}\r\n\r\n"
        ).encode() + body
    elif path == "/ready":
        # Readiness = health + no unresolved critical incidents
        status = await run_health_checks()
        body = orjson.dumps({"ready": status.is_healthy})
        code = 200 if status.is_healthy else 503
        response = (
            f"HTTP/1.1 {code} {'OK' if code == 200 else 'Not Ready'}\r\n"
            f"Content-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n\r\n"
        ).encode() + body
    else:
        body = b'{"error": "not found"}'
        response = (
            f"HTTP/1.1 404 Not Found\r\n"
            f"Content-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n\r\n"
        ).encode() + body

    writer.write(response)
    await writer.drain()
    writer.close()


async def start_health_server() -> asyncio.Server:
    """Start the health check HTTP server."""
    cfg = get_config().monitoring
    server = await asyncio.start_server(
        _handle_request, "0.0.0.0", cfg.health_port
    )
    logger.info("Health server listening on port %d", cfg.health_port)
    return server
