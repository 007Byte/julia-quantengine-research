"""
Postgres connection pool and base operations.

Uses asyncpg for async access. Provides:
- Connection pool lifecycle
- Migration runner
- Common query helpers
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any

import asyncpg

from src.core.config import get_config

logger = logging.getLogger(__name__)

_pool: asyncpg.Pool | None = None

MIGRATIONS_DIR = Path(__file__).parent / "migrations"


async def get_pool() -> asyncpg.Pool:
    """Get or create the connection pool."""
    global _pool
    if _pool is None:
        cfg = get_config().postgres
        _pool = await asyncpg.create_pool(
            dsn=cfg.dsn,
            min_size=cfg.min_connections,
            max_size=cfg.max_connections,
        )
        logger.info("Postgres pool created: %s:%d/%s", cfg.host, cfg.port, cfg.database)
    return _pool


async def close_pool() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None
        logger.info("Postgres pool closed")


async def run_migrations() -> None:
    """Run all .sql migrations in order."""
    pool = await get_pool()
    async with pool.acquire() as conn:
        # Ensure migration tracking table exists
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS _migrations (
                filename TEXT PRIMARY KEY,
                applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        """)

        applied = {row["filename"] for row in await conn.fetch("SELECT filename FROM _migrations")}

        migration_files = sorted(MIGRATIONS_DIR.glob("*.sql"))
        for mf in migration_files:
            if mf.name in applied:
                continue
            logger.info("Applying migration: %s", mf.name)
            sql = mf.read_text()
            async with conn.transaction():
                await conn.execute(sql)
                await conn.execute(
                    "INSERT INTO _migrations (filename) VALUES ($1)", mf.name
                )
            logger.info("Applied: %s", mf.name)


async def execute(query: str, *args: Any) -> str:
    pool = await get_pool()
    async with pool.acquire() as conn:
        return await conn.execute(query, *args)


async def fetch(query: str, *args: Any) -> list[asyncpg.Record]:
    pool = await get_pool()
    async with pool.acquire() as conn:
        return await conn.fetch(query, *args)


async def fetchrow(query: str, *args: Any) -> asyncpg.Record | None:
    pool = await get_pool()
    async with pool.acquire() as conn:
        return await conn.fetchrow(query, *args)


async def fetchval(query: str, *args: Any) -> Any:
    pool = await get_pool()
    async with pool.acquire() as conn:
        return await conn.fetchval(query, *args)
