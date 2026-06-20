"""
DB-first + Outbox pattern for trade-critical transitions.

Flow:
1. Service writes business entity + outbox row in same Postgres transaction
2. Outbox worker polls unpublished rows
3. Publishes to Redis Stream
4. Marks outbox row as published

This gives stronger auditability and easier replay than stream-first.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

import asyncpg

from src.core.event_schema import StreamEnvelope
from src.ledger import postgres, redis_streams

logger = logging.getLogger(__name__)


async def write_with_outbox(
    conn: asyncpg.Connection,
    business_sql: str,
    business_args: tuple[Any, ...],
    stream_name: str,
    envelope: StreamEnvelope,
) -> None:
    """
    Execute business SQL and insert outbox row in the same transaction.

    MUST be called within an existing transaction context:
        async with conn.transaction():
            await write_with_outbox(conn, sql, args, stream, envelope)
    """
    await conn.execute(business_sql, *business_args)
    await conn.execute(
        """
        INSERT INTO outbox (stream_name, envelope_data)
        VALUES ($1, $2)
        """,
        stream_name,
        envelope.to_stream_dict(),
    )


async def publish_pending(batch_size: int = 100) -> int:
    """
    Publish unpublished outbox rows to Redis Streams.
    Returns count of published messages.
    """
    pool = await postgres.get_pool()
    published = 0

    async with pool.acquire() as conn:
        rows = await conn.fetch(
            """
            SELECT outbox_id, stream_name, envelope_data
            FROM outbox
            WHERE NOT published
            ORDER BY outbox_id
            LIMIT $1
            FOR UPDATE SKIP LOCKED
            """,
            batch_size,
        )

        for row in rows:
            try:
                stream = row["stream_name"]
                data = row["envelope_data"]

                # Reconstruct envelope fields for XADD
                r = await redis_streams.get_redis()
                # data is already a dict matching stream format
                await r.xadd(stream, {k: str(v) for k, v in data.items()})

                await conn.execute(
                    "UPDATE outbox SET published = TRUE, published_at = NOW() WHERE outbox_id = $1",
                    row["outbox_id"],
                )
                published += 1
            except Exception:
                logger.exception("Failed to publish outbox row %d", row["outbox_id"])

    return published


async def run_outbox_worker(poll_interval: float = 0.5) -> None:
    """
    Continuously poll and publish outbox rows.
    Run this as a background task.
    """
    logger.info("Outbox worker started (interval=%.1fs)", poll_interval)
    while True:
        try:
            count = await publish_pending()
            if count:
                logger.debug("Outbox worker published %d messages", count)
        except asyncio.CancelledError:
            logger.info("Outbox worker shutting down")
            return
        except Exception:
            logger.exception("Outbox worker error")
        await asyncio.sleep(poll_interval)


async def cleanup_published(retention_hours: int = 72) -> int:
    """Remove old published outbox rows."""
    pool = await postgres.get_pool()
    async with pool.acquire() as conn:
        result = await conn.execute(
            """
            DELETE FROM outbox
            WHERE published AND published_at < NOW() - $1 * INTERVAL '1 hour'
            """,
            retention_hours,
        )
        count = int(result.split()[-1]) if result else 0
        if count:
            logger.info("Cleaned %d published outbox rows", count)
        return count
