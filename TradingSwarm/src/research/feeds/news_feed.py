"""
News Feed Ingestor — fetches and normalizes news articles.

Sources: RSS feeds, news APIs, filings.
Outputs: normalized articles with metadata for LLM processing.

Warm-path rules:
- Bounded timeout per fetch
- Cached outputs
- Ignorable if unavailable
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
from datetime import datetime, timezone
from typing import Any

import httpx

logger = logging.getLogger(__name__)


class NewsArticle:
    """Normalized news article."""

    def __init__(
        self,
        source: str,
        title: str,
        content: str,
        url: str,
        published_at: datetime,
        symbols: list[str] | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> None:
        self.source = source
        self.title = title
        self.content = content
        self.url = url
        self.published_at = published_at
        self.symbols = symbols or []
        self.metadata = metadata or {}
        self.article_id = hashlib.sha256(f"{source}:{url}".encode()).hexdigest()[:16]

    def to_dict(self) -> dict[str, Any]:
        return {
            "article_id": self.article_id,
            "source": self.source,
            "title": self.title,
            "content": self.content[:2000],  # truncate for LLM
            "url": self.url,
            "published_at": self.published_at.isoformat(),
            "symbols": self.symbols,
        }


class NewsFeed:
    """
    Fetches news from configurable sources.

    All fetches are bounded by timeout and budget.
    Failures are logged but do not affect the hot path.
    """

    def __init__(self, timeout_seconds: float = 10.0) -> None:
        self._timeout = timeout_seconds
        self._cache: dict[str, NewsArticle] = {}

    async def fetch_from_url(self, url: str, source: str) -> list[NewsArticle]:
        """Fetch articles from a JSON news API endpoint."""
        articles = []
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                resp = await client.get(url)
                resp.raise_for_status()
                data = resp.json()

                for item in data.get("articles", data.get("results", [])):
                    article = NewsArticle(
                        source=source,
                        title=item.get("title", ""),
                        content=item.get("content", item.get("description", "")),
                        url=item.get("url", ""),
                        published_at=datetime.now(timezone.utc),
                        symbols=item.get("symbols", []),
                    )
                    if article.article_id not in self._cache:
                        self._cache[article.article_id] = article
                        articles.append(article)

        except Exception:
            logger.warning("News fetch failed for %s (non-fatal)", source)

        return articles

    async def fetch_all_sources(self, sources: dict[str, str]) -> list[NewsArticle]:
        """Fetch from multiple sources concurrently with individual timeouts."""
        tasks = [
            self.fetch_from_url(url, name)
            for name, url in sources.items()
        ]
        results = await asyncio.gather(*tasks, return_exceptions=True)

        all_articles = []
        for result in results:
            if isinstance(result, list):
                all_articles.extend(result)
            elif isinstance(result, Exception):
                logger.warning("Source fetch error: %s", result)

        logger.info("Fetched %d new articles from %d sources", len(all_articles), len(sources))
        return all_articles

    def get_cached(self, max_age_seconds: int = 3600) -> list[NewsArticle]:
        """Get recently cached articles."""
        now = datetime.now(timezone.utc)
        return [
            a for a in self._cache.values()
            if (now - a.published_at).total_seconds() < max_age_seconds
        ]
