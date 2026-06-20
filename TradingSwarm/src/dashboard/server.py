"""
Dashboard — HTTP API for monitoring the pipeline.

Provides JSON endpoints for:
- Pipeline status
- Active orders / positions
- Fill history
- Risk budget state
- Reconciliation incidents
- PnL / performance

Served as a lightweight asyncio HTTP server (no framework dependency).
"""

from __future__ import annotations

import asyncio
import json
import logging
from datetime import datetime, timezone
from typing import Any

import orjson

from src.control.kill_switch import get_conservative_mode, get_kill_switch
from src.core.julia_bridge import get_bridge
from src.ledger import postgres, redis_streams
from src.monitoring.health import run_health_checks

logger = logging.getLogger(__name__)


async def _query_json(query: str, *args: Any) -> list[dict]:
    """Run a query and return results as dicts."""
    rows = await postgres.fetch(query, *args)
    result = []
    for row in rows:
        d = dict(row)
        for k, v in d.items():
            if isinstance(v, datetime):
                d[k] = v.isoformat()
            elif hasattr(v, '__str__') and not isinstance(v, (str, int, float, bool)):
                d[k] = str(v)
        result.append(d)
    return result


# ---- Route handlers ----

async def handle_status() -> dict[str, Any]:
    health = await run_health_checks()
    ks = get_kill_switch()
    cm = get_conservative_mode()
    bridge = get_bridge()
    return {
        "health": health.to_dict(),
        "kill_switch": ks.status(),
        "conservative_mode": cm.status(),
        "julia_bridge": {
            "healthy": bridge.is_healthy,
            "circuit": bridge.circuit_state.value,
        },
    }


async def handle_orders(team_id: str | None = None) -> list[dict]:
    query = """
        SELECT order_intent_id, team_id, strategy_id, instrument_id,
               side, intent_type, requested_qty, current_state, created_at
        FROM order_intents
        WHERE current_state NOT IN ('filled', 'canceled', 'rejected', 'expired')
    """
    args: list[Any] = []
    if team_id:
        query += " AND team_id = $1"
        args.append(team_id)
    query += " ORDER BY created_at DESC LIMIT 100"
    return await _query_json(query, *args)


async def handle_fills(team_id: str | None = None, limit: int = 50) -> list[dict]:
    query = """
        SELECT fill_id, order_intent_id, instrument_id, team_id, strategy_id,
               venue, side, quantity, price, fee, slippage_bps, fill_time_utc
        FROM fills
    """
    args: list[Any] = []
    if team_id:
        query += " WHERE team_id = $1"
        args.append(team_id)
    query += f" ORDER BY fill_time_utc DESC LIMIT {limit}"
    return await _query_json(query, *args)


async def handle_positions(team_id: str | None = None) -> list[dict]:
    query = """
        SELECT team_id, strategy_id, instrument_id, quantity,
               avg_entry_price, realized_pnl, cost_basis, updated_at
        FROM strategy_positions
        WHERE quantity != 0
    """
    args: list[Any] = []
    if team_id:
        query += " AND team_id = $1"
        args.append(team_id)
    return await _query_json(query, *args)


async def handle_risk_budgets() -> list[dict]:
    return await _query_json(
        "SELECT * FROM risk_budgets ORDER BY scope"
    )


async def handle_incidents(status: str = "open") -> list[dict]:
    return await _query_json(
        """
        SELECT incident_id, team_id, venue, incident_type, severity,
               expected_state, actual_state, status, detected_at
        FROM reconciliation_incidents
        WHERE status = $1
        ORDER BY detected_at DESC LIMIT 50
        """,
        status,
    )


async def handle_pnl(team_id: str) -> dict[str, Any]:
    row = await postgres.fetchrow("""
        SELECT
            COALESCE(SUM(realized_pnl), 0) as total_realized_pnl,
            COUNT(*) as position_count
        FROM strategy_positions
        WHERE team_id = $1
    """, team_id)

    fills_today = await postgres.fetchrow("""
        SELECT
            COUNT(*) as fill_count,
            COALESCE(SUM(quantity * price), 0) as volume,
            COALESCE(SUM(fee), 0) as fees
        FROM fills
        WHERE team_id = $1 AND fill_time_utc >= CURRENT_DATE
    """, team_id)

    return {
        "team_id": team_id,
        "total_realized_pnl": str(row["total_realized_pnl"]) if row else "0",
        "position_count": row["position_count"] if row else 0,
        "fills_today": fills_today["fill_count"] if fills_today else 0,
        "volume_today": str(fills_today["volume"]) if fills_today else "0",
        "fees_today": str(fills_today["fees"]) if fills_today else "0",
    }


async def handle_streams() -> dict[str, Any]:
    lengths = await redis_streams.get_stream_lengths()
    return {"stream_lengths": lengths}


# ---- HTTP Server ----

ROUTES = {
    "/api/status": handle_status,
    "/api/orders": handle_orders,
    "/api/fills": handle_fills,
    "/api/positions": handle_positions,
    "/api/risk": handle_risk_budgets,
    "/api/incidents": handle_incidents,
    "/api/streams": handle_streams,
}


async def _handle_request(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        request = await reader.read(4096)
        request_line = request.decode().split("\r\n")[0] if request else ""
        parts = request_line.split(" ")
        path = parts[1] if len(parts) > 1 else "/"
        base_path = path.split("?")[0]

        # Parse query params
        params: dict[str, str] = {}
        if "?" in path:
            qs = path.split("?")[1]
            for pair in qs.split("&"):
                if "=" in pair:
                    k, v = pair.split("=", 1)
                    params[k] = v

        # Route
        if base_path in ROUTES:
            handler = ROUTES[base_path]
            if base_path == "/api/pnl" and "team" in params:
                result = await handle_pnl(params["team"])
            elif "team" in params:
                result = await handler(team_id=params["team"])
            else:
                result = await handler()

            body = orjson.dumps(result)
            code = 200
        elif base_path == "/api/pnl" and "team" in params:
            result = await handle_pnl(params["team"])
            body = orjson.dumps(result)
            code = 200
        elif base_path == "/":
            body = orjson.dumps({
                "service": "QuantEngine Dashboard",
                "endpoints": list(ROUTES.keys()) + ["/api/pnl?team=<id>"],
            })
            code = 200
        else:
            body = orjson.dumps({"error": "not found"})
            code = 404

        response = (
            f"HTTP/1.1 {code} OK\r\n"
            f"Content-Type: application/json\r\n"
            f"Access-Control-Allow-Origin: *\r\n"
            f"Content-Length: {len(body)}\r\n\r\n"
        ).encode() + body

        writer.write(response)
        await writer.drain()
    except Exception:
        logger.exception("Dashboard request error")
    finally:
        writer.close()


async def start_dashboard(port: int = 8080) -> asyncio.Server:
    """Start the dashboard HTTP server."""
    server = await asyncio.start_server(_handle_request, "0.0.0.0", port)
    logger.info("Dashboard listening on port %d", port)
    return server
