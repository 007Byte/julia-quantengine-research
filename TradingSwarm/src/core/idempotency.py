"""
Idempotency enforcement for trade-critical handlers.

Every handler that processes trade-critical events must be safe under
replay and retry. This module provides the dedup infrastructure.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from typing import Any

import orjson

from src.ledger import postgres

logger = logging.getLogger(__name__)


async def check_and_claim(
    idempotency_key: str,
    ttl_hours: int = 24,
) -> dict[str, Any] | None:
    """
    Check if an idempotency key has been seen before.

    Returns:
        Previous result dict if duplicate, None if this is the first time.
    """
    pool = await postgres.get_pool()
    async with pool.acquire() as conn:
        row = await conn.fetchrow(
            """
            SELECT result_data, expires_at FROM idempotency_keys
            WHERE idempotency_key = $1
            """,
            idempotency_key,
        )

        if row is not None:
            expires = row["expires_at"]
            if expires and expires > datetime.now(timezone.utc):
                logger.debug("Duplicate idempotency key: %s", idempotency_key)
                return row["result_data"]
            # Expired — delete and allow retry
            await conn.execute(
                "DELETE FROM idempotency_keys WHERE idempotency_key = $1",
                idempotency_key,
            )

        # Claim the key
        expires_at = datetime.now(timezone.utc) + timedelta(hours=ttl_hours)
        await conn.execute(
            """
            INSERT INTO idempotency_keys (idempotency_key, expires_at)
            VALUES ($1, $2)
            ON CONFLICT (idempotency_key) DO NOTHING
            """,
            idempotency_key,
            expires_at,
        )
        return None


async def record_result(
    idempotency_key: str,
    result: dict[str, Any],
) -> None:
    """Record the result of processing for an idempotency key."""
    pool = await postgres.get_pool()
    async with pool.acquire() as conn:
        await conn.execute(
            """
            UPDATE idempotency_keys
            SET result_data = $2
            WHERE idempotency_key = $1
            """,
            idempotency_key,
            orjson.dumps(result).decode(),
        )


async def cleanup_expired() -> int:
    """Remove expired idempotency keys."""
    pool = await postgres.get_pool()
    async with pool.acquire() as conn:
        result = await conn.execute(
            "DELETE FROM idempotency_keys WHERE expires_at < NOW()"
        )
        count = int(result.split()[-1]) if result else 0
        if count:
            logger.info("Cleaned %d expired idempotency keys", count)
        return count
