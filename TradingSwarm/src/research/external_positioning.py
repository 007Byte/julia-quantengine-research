"""
External Positioning Features — weak signals from public data.

Section 15.2: these are delayed, noisy, survivorship-biased,
potentially hedged, and never a primary execution authority.

Sources:
- 13F filings (SEC EDGAR)
- COT reports (CFTC)
- Whale tracking (on-chain)
- Public crowd forecasts
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any

import httpx

logger = logging.getLogger(__name__)


class PositioningSignal:
    """A single positioning data point."""

    def __init__(
        self,
        source: str,
        signal_type: str,
        symbol: str,
        value: float,
        confidence: float,
        observed_at: datetime,
        metadata: dict[str, Any] | None = None,
    ) -> None:
        self.source = source
        self.signal_type = signal_type
        self.symbol = symbol
        self.value = value
        self.confidence = confidence
        self.observed_at = observed_at
        self.metadata = metadata or {}
        # Positioning signals are inherently weak
        self.max_confidence = 0.3

    @property
    def clamped_confidence(self) -> float:
        """Confidence capped — positioning signals are never high-confidence."""
        return min(self.confidence, self.max_confidence)

    def to_dict(self) -> dict[str, Any]:
        return {
            "source": self.source,
            "signal_type": self.signal_type,
            "symbol": self.symbol,
            "value": self.value,
            "confidence": self.clamped_confidence,
            "observed_at": self.observed_at.isoformat(),
        }


class ExternalPositioningService:
    """
    Fetches and normalizes external positioning data.

    All fetches are:
    - Bounded by timeout
    - Cached
    - Return empty on failure (warm path)
    """

    def __init__(self, timeout_seconds: float = 15.0) -> None:
        self._timeout = timeout_seconds
        self._cache: dict[str, list[PositioningSignal]] = {}

    async def fetch_13f_holdings(self, cik: str) -> list[PositioningSignal]:
        """Fetch 13F filings from SEC EDGAR."""
        signals = []
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                # SEC EDGAR JSON API
                resp = await client.get(
                    f"https://data.sec.gov/submissions/CIK{cik.zfill(10)}.json",
                    headers={"User-Agent": "QuantEngine research@example.com"},
                )
                if resp.status_code == 200:
                    data = resp.json()
                    name = data.get("name", "unknown")
                    logger.info("Fetched 13F for %s (%s)", name, cik)
                    # Parse recent filings for position changes
                    # In production: parse the actual XML holdings files
                    signals.append(PositioningSignal(
                        source="13f",
                        signal_type="institutional_filing",
                        symbol=cik,
                        value=0.0,
                        confidence=0.1,
                        observed_at=datetime.now(timezone.utc),
                        metadata={"filer": name},
                    ))
        except Exception:
            logger.warning("13F fetch failed for CIK %s (non-fatal)", cik)

        return signals

    async def fetch_cot_report(self, symbol: str) -> list[PositioningSignal]:
        """Fetch Commitment of Traders data from CFTC."""
        # CFTC publishes weekly — this is inherently delayed
        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                resp = await client.get(
                    "https://publicreporting.cftc.gov/resource/6dca-aqww.json",
                    params={"$limit": 10, "commodity_name": symbol},
                )
                if resp.status_code == 200:
                    data = resp.json()
                    signals = []
                    for row in data[:3]:
                        signals.append(PositioningSignal(
                            source="cot",
                            signal_type="cot_positioning",
                            symbol=symbol,
                            value=float(row.get("noncomm_positions_long_all", 0)),
                            confidence=0.15,
                            observed_at=datetime.now(timezone.utc),
                            metadata={"report_date": row.get("report_date_as_yyyy_mm_dd", "")},
                        ))
                    return signals
        except Exception:
            logger.warning("COT fetch failed for %s (non-fatal)", symbol)

        return []

    async def fetch_onchain_whale_activity(self, asset: str) -> list[PositioningSignal]:
        """Fetch on-chain whale activity — stub for production API integration."""
        # In production: integrate with Arkham, Nansen, or custom on-chain scanner
        logger.debug("Whale tracking for %s — no data source configured", asset)
        return []

    async def get_all_positioning(self, symbols: list[str]) -> dict[str, list[PositioningSignal]]:
        """Fetch positioning data for all symbols, cached."""
        import asyncio
        result: dict[str, list[PositioningSignal]] = {}

        for symbol in symbols:
            if symbol in self._cache:
                result[symbol] = self._cache[symbol]
                continue

            tasks = [
                self.fetch_cot_report(symbol),
                self.fetch_onchain_whale_activity(symbol),
            ]
            fetched = await asyncio.gather(*tasks, return_exceptions=True)

            all_signals: list[PositioningSignal] = []
            for r in fetched:
                if isinstance(r, list):
                    all_signals.extend(r)

            self._cache[symbol] = all_signals
            result[symbol] = all_signals

        return result
