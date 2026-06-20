"""
LLM Interpreter — structured feature extraction from unstructured data.

Uses Claude API for:
- Sentiment extraction from news/articles
- Regime classification from multi-source context
- Structured fact extraction from filings
- Narrative labeling

Rules (Section 15.1):
- LLMs may summarize, extract, classify, assist with reports
- LLMs may NOT place trades, override risk, mutate strategies, bypass durability

All outputs are:
- Versioned by prompt template + model
- Bounded by timeout and API budget
- Confidence-scored
- Cached
"""

from __future__ import annotations

import hashlib
import logging
import time
from datetime import datetime, timezone
from typing import Any

import httpx

logger = logging.getLogger(__name__)


class LLMConfig:
    """Configuration for LLM feature extraction."""

    def __init__(
        self,
        api_key: str = "",
        model: str = "claude-sonnet-4-20250514",
        max_budget_usd: float = 50.0,
        timeout_seconds: float = 30.0,
        max_tokens: int = 1024,
    ) -> None:
        self.api_key = api_key
        self.model = model
        self.max_budget_usd = max_budget_usd
        self.timeout_seconds = timeout_seconds
        self.max_tokens = max_tokens


class LLMResult:
    """Result from an LLM extraction."""

    def __init__(
        self,
        feature_name: str,
        value: Any,
        confidence: float,
        model: str,
        prompt_version: str,
        computed_at: datetime,
        input_hash: str,
        cost_usd: float = 0.0,
    ) -> None:
        self.feature_name = feature_name
        self.value = value
        self.confidence = confidence
        self.model = model
        self.prompt_version = prompt_version
        self.computed_at = computed_at
        self.input_hash = input_hash
        self.cost_usd = cost_usd

    def to_dict(self) -> dict[str, Any]:
        return {
            "feature_name": self.feature_name,
            "value": self.value,
            "confidence": self.confidence,
            "model": self.model,
            "prompt_version": self.prompt_version,
            "computed_at": self.computed_at.isoformat(),
            "input_hash": self.input_hash,
            "cost_usd": self.cost_usd,
        }


# Versioned prompt templates
PROMPT_TEMPLATES = {
    "sentiment_v1": {
        "version": "v1",
        "system": "You are a financial sentiment analyst. Respond with JSON only.",
        "template": (
            "Analyze the sentiment of the following text about {symbol}.\n\n"
            "Text: {text}\n\n"
            "Respond with JSON: {{\"sentiment\": float (-1 to 1), "
            "\"confidence\": float (0 to 1), \"key_topics\": [str]}}"
        ),
    },
    "regime_v1": {
        "version": "v1",
        "system": "You are a macro regime classifier. Respond with JSON only.",
        "template": (
            "Based on the following market context, classify the current regime.\n\n"
            "Context: {context}\n\n"
            "Respond with JSON: {{\"regime\": str (risk_on|risk_off|transitional|crisis), "
            "\"confidence\": float, \"reasoning\": str}}"
        ),
    },
    "event_extraction_v1": {
        "version": "v1",
        "system": "You are an event extraction model. Respond with JSON only.",
        "template": (
            "Extract key events and their market impact from:\n\n"
            "{text}\n\n"
            "Respond with JSON: {{\"events\": [{{\"event\": str, \"impact\": str, "
            "\"affected_symbols\": [str], \"severity\": float (0-1)}}]}}"
        ),
    },
}


class LLMInterpreter:
    """
    Extracts structured features from unstructured data via Claude API.

    All requests are:
    - Bounded by timeout and budget
    - Cached by input hash + prompt version
    - Confidence-scored
    """

    def __init__(self, config: LLMConfig) -> None:
        self._cfg = config
        self._spent_usd = 0.0
        self._cache: dict[str, LLMResult] = {}
        self._call_count = 0

    @property
    def budget_remaining(self) -> float:
        return self._cfg.max_budget_usd - self._spent_usd

    @property
    def is_budget_exhausted(self) -> bool:
        return self._spent_usd >= self._cfg.max_budget_usd

    def _cache_key(self, prompt_name: str, input_hash: str) -> str:
        return f"{prompt_name}:{input_hash}"

    def _hash_input(self, text: str) -> str:
        return hashlib.sha256(text.encode()).hexdigest()[:12]

    async def extract_sentiment(
        self, text: str, symbol: str
    ) -> LLMResult | None:
        """Extract sentiment from text about a specific symbol."""
        if self.is_budget_exhausted:
            logger.warning("LLM budget exhausted — skipping sentiment extraction")
            return None

        prompt_cfg = PROMPT_TEMPLATES["sentiment_v1"]
        input_hash = self._hash_input(f"{symbol}:{text}")
        cache_key = self._cache_key("sentiment_v1", input_hash)

        if cache_key in self._cache:
            return self._cache[cache_key]

        prompt = prompt_cfg["template"].format(symbol=symbol, text=text[:3000])

        raw = await self._call_api(prompt_cfg["system"], prompt)
        if raw is None:
            return None

        result = LLMResult(
            feature_name=f"sentiment:{symbol}",
            value=raw,
            confidence=raw.get("confidence", 0.5) if isinstance(raw, dict) else 0.5,
            model=self._cfg.model,
            prompt_version=prompt_cfg["version"],
            computed_at=datetime.now(timezone.utc),
            input_hash=input_hash,
        )
        self._cache[cache_key] = result
        return result

    async def classify_regime(self, context: str) -> LLMResult | None:
        """Classify the current market regime."""
        if self.is_budget_exhausted:
            return None

        prompt_cfg = PROMPT_TEMPLATES["regime_v1"]
        input_hash = self._hash_input(context)
        cache_key = self._cache_key("regime_v1", input_hash)

        if cache_key in self._cache:
            return self._cache[cache_key]

        prompt = prompt_cfg["template"].format(context=context[:5000])

        raw = await self._call_api(prompt_cfg["system"], prompt)
        if raw is None:
            return None

        result = LLMResult(
            feature_name="regime_classification",
            value=raw,
            confidence=raw.get("confidence", 0.5) if isinstance(raw, dict) else 0.5,
            model=self._cfg.model,
            prompt_version=prompt_cfg["version"],
            computed_at=datetime.now(timezone.utc),
            input_hash=input_hash,
        )
        self._cache[cache_key] = result
        return result

    async def extract_events(self, text: str) -> LLMResult | None:
        """Extract structured events from text."""
        if self.is_budget_exhausted:
            return None

        prompt_cfg = PROMPT_TEMPLATES["event_extraction_v1"]
        input_hash = self._hash_input(text)
        cache_key = self._cache_key("event_extraction_v1", input_hash)

        if cache_key in self._cache:
            return self._cache[cache_key]

        prompt = prompt_cfg["template"].format(text=text[:5000])

        raw = await self._call_api(prompt_cfg["system"], prompt)
        if raw is None:
            return None

        result = LLMResult(
            feature_name="event_extraction",
            value=raw,
            confidence=0.7,
            model=self._cfg.model,
            prompt_version=prompt_cfg["version"],
            computed_at=datetime.now(timezone.utc),
            input_hash=input_hash,
        )
        self._cache[cache_key] = result
        return result

    async def _call_api(self, system_prompt: str, user_prompt: str) -> dict[str, Any] | None:
        """Call Claude API with timeout and budget tracking."""
        if not self._cfg.api_key:
            logger.debug("No API key — LLM extraction skipped")
            return None

        try:
            async with httpx.AsyncClient(timeout=self._cfg.timeout_seconds) as client:
                resp = await client.post(
                    "https://api.anthropic.com/v1/messages",
                    headers={
                        "x-api-key": self._cfg.api_key,
                        "anthropic-version": "2023-06-01",
                        "content-type": "application/json",
                    },
                    json={
                        "model": self._cfg.model,
                        "max_tokens": self._cfg.max_tokens,
                        "system": system_prompt,
                        "messages": [{"role": "user", "content": user_prompt}],
                    },
                )
                resp.raise_for_status()
                data = resp.json()

                # Track costs (approximate)
                input_tokens = data.get("usage", {}).get("input_tokens", 0)
                output_tokens = data.get("usage", {}).get("output_tokens", 0)
                cost = (input_tokens * 3 + output_tokens * 15) / 1_000_000  # Sonnet pricing approx
                self._spent_usd += cost
                self._call_count += 1

                # Parse response
                content = data.get("content", [{}])[0].get("text", "{}")
                import orjson
                try:
                    return orjson.loads(content)
                except Exception:
                    return {"raw_text": content}

        except Exception:
            logger.warning("LLM API call failed (non-fatal — warm path)")
            return None
