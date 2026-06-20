"""
Redis Streams infrastructure — durable event bus for the hot path.

Provides:
- Stream producer (XADD with envelope)
- Consumer group management (XREADGROUP + XACK)
- Pending message recovery (XAUTOCLAIM)
- Dead letter queue
- Health metrics
"""

from __future__ import annotations

import asyncio
import logging
import time
from typing import Any, Callable, Coroutine

import redis.asyncio as aioredis

from src.core.config import get_config
from src.core.event_schema import StreamEnvelope

logger = logging.getLogger(__name__)

# Trade-critical stream names
STREAMS = {
    "market.normalized": "market.normalized",
    "signal.generated": "signal.generated",
    "risk.decisions": "risk.decisions",
    "risk.reservations": "risk.reservations",
    "oms.intents": "oms.intents",
    "oms.events": "oms.events",
    "broker.events": "broker.events",
    "fills.events": "fills.events",
    "reconciliation.incidents": "reconciliation.incidents",
    "alerts.critical": "alerts.critical",
}

# Dead letter queue suffix
DLQ_SUFFIX = ".dlq"

_client: aioredis.Redis | None = None


async def get_redis() -> aioredis.Redis:
    global _client
    if _client is None:
        cfg = get_config().redis
        _client = aioredis.from_url(
            cfg.url,
            decode_responses=True,
            max_connections=20,
        )
        logger.info("Redis connected: %s:%d", cfg.host, cfg.port)
    return _client


async def close_redis() -> None:
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None


async def verify_aof() -> bool:
    """Verify AOF is enabled. Required for live."""
    r = await get_redis()
    info = await r.info("persistence")
    aof_enabled = info.get("aof_enabled", 0)
    if not aof_enabled:
        logger.warning("Redis AOF is DISABLED — not safe for live trading")
        return False
    logger.info("Redis AOF verified: enabled")
    return True


# ---------------------------------------------------------------------------
# Consumer group setup
# ---------------------------------------------------------------------------

async def ensure_consumer_groups(service_name: str) -> None:
    """Create consumer groups for all trade-critical streams."""
    r = await get_redis()
    for stream_name in STREAMS.values():
        try:
            await r.xgroup_create(stream_name, service_name, id="0", mkstream=True)
            logger.info("Consumer group '%s' created on '%s'", service_name, stream_name)
        except aioredis.ResponseError as e:
            if "BUSYGROUP" in str(e):
                pass  # already exists
            else:
                raise


# ---------------------------------------------------------------------------
# Producer
# ---------------------------------------------------------------------------

async def publish(stream: str, envelope: StreamEnvelope) -> str:
    """Publish an event to a Redis Stream. Returns the message ID."""
    r = await get_redis()
    msg_id = await r.xadd(stream, envelope.to_stream_dict())
    logger.debug("Published to %s: %s (envelope=%s)", stream, msg_id, envelope.envelope_id)
    return msg_id


# ---------------------------------------------------------------------------
# Consumer
# ---------------------------------------------------------------------------

MessageHandler = Callable[[str, str, dict[str, str]], Coroutine[Any, Any, None]]


async def consume(
    stream: str,
    group: str,
    consumer: str,
    handler: MessageHandler,
    batch_size: int = 10,
) -> None:
    """
    Consume messages from a stream using consumer groups.

    handler(stream, message_id, fields) is called for each message.
    XACK is sent only after handler completes successfully.
    """
    cfg = get_config().redis
    r = await get_redis()

    while True:
        try:
            results = await r.xreadgroup(
                groupname=group,
                consumername=consumer,
                streams={stream: ">"},
                count=batch_size,
                block=cfg.block_ms,
            )

            if not results:
                continue

            for stream_name, messages in results:
                for msg_id, fields in messages:
                    try:
                        await handler(stream_name, msg_id, fields)
                        await r.xack(stream_name, group, msg_id)
                    except Exception:
                        logger.exception(
                            "Handler failed for %s/%s — will retry via XAUTOCLAIM",
                            stream_name, msg_id,
                        )
        except asyncio.CancelledError:
            logger.info("Consumer %s/%s shutting down", group, consumer)
            return
        except Exception:
            logger.exception("Consumer loop error, reconnecting in 1s")
            await asyncio.sleep(1)


# ---------------------------------------------------------------------------
# Pending message recovery
# ---------------------------------------------------------------------------

async def reclaim_pending(
    stream: str,
    group: str,
    consumer: str,
    handler: MessageHandler,
) -> int:
    """
    Reclaim idle pending messages using XAUTOCLAIM.
    Returns count of reclaimed messages.
    """
    cfg = get_config().redis
    r = await get_redis()
    reclaimed = 0

    start_id = "0-0"
    while True:
        result = await r.xautoclaim(
            name=stream,
            groupname=group,
            consumername=consumer,
            min_idle_time=cfg.reclaim_idle_ms,
            start_id=start_id,
            count=100,
        )

        next_id, messages, _deletions = result
        if not messages:
            break

        for msg_id, fields in messages:
            # Check retry count
            pending_info = await r.xpending_range(stream, group, min=msg_id, max=msg_id, count=1)
            if pending_info:
                delivery_count = pending_info[0].get("times_delivered", 0)
                if delivery_count > cfg.max_retries:
                    await _move_to_dlq(r, stream, group, msg_id, fields)
                    continue

            try:
                await handler(stream, msg_id, fields)
                await r.xack(stream, group, msg_id)
                reclaimed += 1
            except Exception:
                logger.exception("Reclaim handler failed for %s/%s", stream, msg_id)

        start_id = next_id
        if next_id == "0-0":
            break

    if reclaimed:
        logger.info("Reclaimed %d pending messages from %s", reclaimed, stream)
    return reclaimed


async def _move_to_dlq(
    r: aioredis.Redis,
    stream: str,
    group: str,
    msg_id: str,
    fields: dict[str, str],
) -> None:
    """Move a poison message to the dead letter queue."""
    dlq_stream = stream + DLQ_SUFFIX
    fields["_original_stream"] = stream
    fields["_original_msg_id"] = msg_id
    fields["_dlq_time"] = str(time.time())
    await r.xadd(dlq_stream, fields)
    await r.xack(stream, group, msg_id)
    logger.warning("Moved to DLQ: %s/%s -> %s", stream, msg_id, dlq_stream)


# ---------------------------------------------------------------------------
# Health / metrics
# ---------------------------------------------------------------------------

async def get_pending_counts(group: str) -> dict[str, int]:
    """Get pending message counts for all trade-critical streams."""
    r = await get_redis()
    counts = {}
    for stream_name in STREAMS.values():
        try:
            info = await r.xpending(stream_name, group)
            counts[stream_name] = info.get("pending", 0) if isinstance(info, dict) else (info[0] if info else 0)
        except Exception:
            counts[stream_name] = -1
    return counts


async def get_stream_lengths() -> dict[str, int]:
    """Get current length of all trade-critical streams."""
    r = await get_redis()
    lengths = {}
    for stream_name in STREAMS.values():
        try:
            lengths[stream_name] = await r.xlen(stream_name)
        except Exception:
            lengths[stream_name] = -1
    return lengths
