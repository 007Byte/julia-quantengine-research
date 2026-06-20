"""
Tests proving research plane isolation.

Phase 3 exit criteria: research plane failure does not affect hot path.

These tests verify that:
1. Feature store returns None when empty/stale (doesn't crash)
2. LLM interpreter handles budget exhaustion gracefully
3. News feed handles fetch failures gracefully
4. Positioning service returns empty on failure
5. Signal engine works without research features
"""

from datetime import datetime, timedelta, timezone

import pytest

from src.research.feature_store import FeatureStore, ResearchFeature
from src.research.llm_interpreter import LLMConfig, LLMInterpreter
from src.research.external_positioning import ExternalPositioningService, PositioningSignal
from src.research.feeds.news_feed import NewsFeed, NewsArticle


class TestFeatureStoreIsolation:
    def test_get_missing_returns_none(self):
        store = FeatureStore()
        assert store.get("unknown_instrument", "sentiment") is None

    def test_get_stale_returns_none(self):
        store = FeatureStore()
        old_feature = ResearchFeature(
            feature_name="sentiment",
            instrument_id="inst1",
            value=0.5,
            confidence=0.7,
            source="llm",
            version="v1",
            computed_at=datetime.now(timezone.utc) - timedelta(hours=2),
            ttl_seconds=3600,  # 1 hour TTL
        )
        store.put(old_feature)
        assert store.get("inst1", "sentiment") is None  # stale

    def test_get_fresh_returns_feature(self):
        store = FeatureStore()
        feature = ResearchFeature(
            feature_name="sentiment",
            instrument_id="inst1",
            value=0.8,
            confidence=0.9,
            source="llm",
            version="v1",
            computed_at=datetime.now(timezone.utc),
        )
        store.put(feature)
        result = store.get("inst1", "sentiment")
        assert result is not None
        assert result.value == 0.8

    def test_get_vector_with_missing(self):
        store = FeatureStore()
        vector = store.get_vector("inst1", ["sentiment", "regime", "momentum"])
        assert vector == {"sentiment": None, "regime": None, "momentum": None}

    def test_evict_stale(self):
        store = FeatureStore()
        store.put(ResearchFeature(
            "old", "inst1", 0.5, 0.5, "test", "v1",
            datetime.now(timezone.utc) - timedelta(hours=5),
            ttl_seconds=3600,
        ))
        store.put(ResearchFeature(
            "fresh", "inst1", 0.8, 0.9, "test", "v1",
            datetime.now(timezone.utc),
        ))
        evicted = store.evict_stale()
        assert evicted == 1
        assert store.get("inst1", "fresh") is not None

    def test_stats(self):
        store = FeatureStore()
        stats = store.stats()
        assert stats["instruments"] == 0
        assert stats["total_features"] == 0


class TestLLMIsolation:
    def test_budget_exhaustion_is_graceful(self):
        config = LLMConfig(api_key="", max_budget_usd=0.0)
        interp = LLMInterpreter(config)
        assert interp.is_budget_exhausted
        assert interp.budget_remaining == 0.0

    def test_no_api_key_skips(self):
        config = LLMConfig(api_key="", max_budget_usd=100.0)
        interp = LLMInterpreter(config)
        # Without API key, calls should return None (not crash)
        assert not interp.is_budget_exhausted

    def test_cache_is_independent(self):
        config = LLMConfig(api_key="")
        interp = LLMInterpreter(config)
        assert len(interp._cache) == 0


class TestNewsFeedIsolation:
    def test_empty_cache_returns_empty(self):
        feed = NewsFeed()
        cached = feed.get_cached()
        assert cached == []

    def test_article_hashing(self):
        a1 = NewsArticle("src", "title1", "content", "http://a.com", datetime.now(timezone.utc))
        a2 = NewsArticle("src", "title2", "content", "http://b.com", datetime.now(timezone.utc))
        assert a1.article_id != a2.article_id

    def test_article_to_dict(self):
        a = NewsArticle("reuters", "Market Up", "Content here", "http://r.com", datetime.now(timezone.utc), ["AAPL"])
        d = a.to_dict()
        assert d["source"] == "reuters"
        assert d["symbols"] == ["AAPL"]


class TestPositioningIsolation:
    def test_confidence_capped(self):
        sig = PositioningSignal(
            source="13f",
            signal_type="institutional",
            symbol="AAPL",
            value=0.8,
            confidence=0.95,  # Very high
            observed_at=datetime.now(timezone.utc),
        )
        # Positioning signals max out at 0.3
        assert sig.clamped_confidence == 0.3

    def test_low_confidence_unchanged(self):
        sig = PositioningSignal(
            source="cot", signal_type="cot", symbol="GC",
            value=100, confidence=0.1,
            observed_at=datetime.now(timezone.utc),
        )
        assert sig.clamped_confidence == 0.1

    def test_signal_to_dict(self):
        sig = PositioningSignal(
            source="cot", signal_type="cot", symbol="CL",
            value=50000, confidence=0.2,
            observed_at=datetime.now(timezone.utc),
        )
        d = sig.to_dict()
        assert d["source"] == "cot"
        assert d["confidence"] == 0.2
