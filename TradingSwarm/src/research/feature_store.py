"""
Research Feature Store — cached weak-signal features for the signal engine.

Features are:
- Versioned by prompt/model/template
- Bounded by timeout and budget
- Confidence-scored
- Cached (not computed per-tick)
- Ignorable without breaking the system

If the feature store is down, the signal engine still works.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from typing import Any

from src.ledger import postgres

logger = logging.getLogger(__name__)


class ResearchFeature:
    """A single cached research feature."""

    def __init__(
        self,
        feature_name: str,
        instrument_id: str,
        value: Any,
        confidence: float,
        source: str,
        version: str,
        computed_at: datetime,
        ttl_seconds: int = 3600,
    ) -> None:
        self.feature_name = feature_name
        self.instrument_id = instrument_id
        self.value = value
        self.confidence = confidence
        self.source = source
        self.version = version
        self.computed_at = computed_at
        self._ttl = ttl_seconds

    @property
    def is_stale(self) -> bool:
        age = (datetime.now(timezone.utc) - self.computed_at).total_seconds()
        return age > self._ttl

    def to_dict(self) -> dict[str, Any]:
        return {
            "feature_name": self.feature_name,
            "instrument_id": self.instrument_id,
            "value": self.value,
            "confidence": self.confidence,
            "source": self.source,
            "version": self.version,
            "computed_at": self.computed_at.isoformat(),
            "is_stale": self.is_stale,
        }


class FeatureStore:
    """
    In-memory cache of research features backed by Postgres.

    The signal engine reads from here as weak, non-authoritative inputs.
    If empty or stale, the signal engine continues without them.
    """

    def __init__(self, default_ttl: int = 3600) -> None:
        self._cache: dict[str, dict[str, ResearchFeature]] = {}
        self._default_ttl = default_ttl

    def get(self, instrument_id: str, feature_name: str) -> ResearchFeature | None:
        """Get a non-stale feature or None."""
        features = self._cache.get(instrument_id, {})
        feature = features.get(feature_name)
        if feature and not feature.is_stale:
            return feature
        return None

    def get_all(self, instrument_id: str) -> list[ResearchFeature]:
        """Get all non-stale features for an instrument."""
        return [
            f for f in self._cache.get(instrument_id, {}).values()
            if not f.is_stale
        ]

    def get_vector(self, instrument_id: str, feature_names: list[str]) -> dict[str, float | None]:
        """Get a named feature vector. Missing/stale features return None."""
        result: dict[str, float | None] = {}
        for name in feature_names:
            f = self.get(instrument_id, name)
            if f is not None:
                result[name] = f.value if isinstance(f.value, (int, float)) else None
            else:
                result[name] = None
        return result

    def put(self, feature: ResearchFeature) -> None:
        """Insert or update a feature in the cache."""
        self._cache.setdefault(feature.instrument_id, {})[feature.feature_name] = feature

    def put_batch(self, features: list[ResearchFeature]) -> int:
        """Insert multiple features. Returns count stored."""
        for f in features:
            self.put(f)
        return len(features)

    def evict_stale(self) -> int:
        """Remove stale features from cache."""
        evicted = 0
        for instrument_id in list(self._cache.keys()):
            features = self._cache[instrument_id]
            stale_keys = [k for k, v in features.items() if v.is_stale]
            for k in stale_keys:
                del features[k]
                evicted += 1
            if not features:
                del self._cache[instrument_id]
        if evicted:
            logger.debug("Evicted %d stale research features", evicted)
        return evicted

    def stats(self) -> dict[str, int]:
        """Cache statistics."""
        total = sum(len(v) for v in self._cache.values())
        stale = sum(
            1 for feats in self._cache.values()
            for f in feats.values() if f.is_stale
        )
        return {
            "instruments": len(self._cache),
            "total_features": total,
            "stale_features": stale,
            "fresh_features": total - stale,
        }

    async def persist_to_db(self) -> int:
        """Write cached features to Postgres for durability."""
        count = 0
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            for instrument_id, features in self._cache.items():
                for feature in features.values():
                    if feature.is_stale:
                        continue
                    await conn.execute("""
                        INSERT INTO audit_log (log_id, actor, action, entity_type, entity_id, details)
                        VALUES (gen_random_uuid(), 'feature_store', 'cache_feature', 'research_feature', $1, $2)
                    """, instrument_id, feature.to_dict())
                    count += 1
        return count

    async def load_from_db(self, max_age_hours: int = 24) -> int:
        """Load recent features from Postgres into cache."""
        try:
            pool = await postgres.get_pool()
            async with pool.acquire() as conn:
                rows = await conn.fetch("""
                    SELECT entity_id, details FROM audit_log
                    WHERE action = 'cache_feature'
                    AND logged_at >= NOW() - $1 * INTERVAL '1 hour'
                    ORDER BY logged_at DESC
                """, max_age_hours)

                for row in rows:
                    details = row["details"]
                    if isinstance(details, dict):
                        feature = ResearchFeature(
                            feature_name=details.get("feature_name", ""),
                            instrument_id=details.get("instrument_id", row["entity_id"]),
                            value=details.get("value"),
                            confidence=details.get("confidence", 0.5),
                            source=details.get("source", "db"),
                            version=details.get("version", ""),
                            computed_at=datetime.fromisoformat(details["computed_at"])
                            if "computed_at" in details else datetime.now(timezone.utc),
                        )
                        if not feature.is_stale:
                            self.put(feature)
        except Exception:
            logger.warning("Feature store DB load failed (non-fatal)")

        count = sum(len(v) for v in self._cache.values())
        logger.info("Feature store loaded: %d features", count)
        return count
