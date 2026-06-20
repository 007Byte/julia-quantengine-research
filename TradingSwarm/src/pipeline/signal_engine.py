"""
Signal Engine — Service B.

Consumes normalized market events, computes features via Julia bridge,
and emits deterministic signal events.

Research features are read as weak, non-authoritative inputs only.
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone
from typing import Any

from src.core.config import get_config
from src.core.event_schema import Side, SignalEvent, StreamEnvelope
from src.core.julia_bridge import get_bridge
from src.ledger import redis_streams

logger = logging.getLogger(__name__)


class SignalEngine:
    """
    Deterministic signal generator backed by Julia numerical core.

    Flow:
    1. Receive normalized market data
    2. Call Julia for feature computation
    3. Call Julia for model scoring / ensemble
    4. Emit signal event if threshold met
    """

    def __init__(self, team_id: str, strategy_id: str) -> None:
        self.team_id = team_id
        self.strategy_id = strategy_id
        self._bridge = get_bridge()
        self._min_signal_strength = 0.55
        self._config_hash = ""
        self._model_version = ""
        self._feature_version = ""

    async def process_market_event(
        self,
        instrument_id: str,
        prices: list[float],
        volumes: list[float],
        highs: list[float],
        lows: list[float],
        timeframe: str = "1d",
    ) -> SignalEvent | None:
        """
        Process a market data update and potentially emit a signal.

        Returns SignalEvent if signal strength exceeds threshold, else None.
        """
        if not self._bridge.is_healthy:
            logger.warning("Julia bridge unhealthy — no new signals")
            return None

        # Step 1: Compute features via Julia
        feature_result = await self._bridge.compute_features(
            instrument_id=instrument_id,
            prices=prices,
            volumes=volumes,
            highs=highs,
            lows=lows,
            timeframe=timeframe,
        )

        if feature_result.get("type") == "error":
            logger.error("Feature computation failed: %s", feature_result.get("error"))
            return None

        features = feature_result.get("features", [])
        if not features:
            return None

        # Step 2: Run ensemble via Julia
        ensemble_result = await self._bridge.run_ensemble(
            instrument_id=instrument_id,
            features=[features],
            strategy_id=self.strategy_id,
        )

        if ensemble_result.get("type") == "error":
            logger.error("Ensemble failed: %s", ensemble_result.get("error"))
            return None

        direction = ensemble_result.get("signal_direction", "hold")
        strength = float(ensemble_result.get("signal_strength", 0.0))

        # Step 3: Threshold check
        if direction == "hold" or strength < self._min_signal_strength:
            logger.debug(
                "Signal below threshold: %s %.3f (min=%.3f)",
                direction, strength, self._min_signal_strength,
            )
            return None

        # Step 4: Emit signal
        signal = SignalEvent(
            team_id=self.team_id,
            strategy_id=self.strategy_id,
            instrument_id=uuid.UUID(instrument_id),
            side=Side.BUY if direction == "buy" else Side.SELL,
            strength=strength,
            model_version=self._model_version,
            feature_version=self._feature_version,
            config_hash=self._config_hash,
            metadata={
                "ensemble_confidence": ensemble_result.get("ensemble_confidence", 0.0),
                "feature_count": len(features),
                "timeframe": timeframe,
            },
        )

        # Publish to stream
        envelope = StreamEnvelope.wrap(
            "signal.generated",
            signal,
            idempotency_key=str(signal.signal_id),
        )
        await redis_streams.publish("signal.generated", envelope)

        logger.info(
            "Signal: %s %s %.3f [%s/%s/%s]",
            direction, instrument_id, strength,
            self.team_id, self.strategy_id, signal.signal_id,
        )
        return signal

    async def start_consuming(self, consumer_name: str) -> None:
        """Start consuming normalized market data from Redis Streams."""
        await redis_streams.ensure_consumer_groups(f"signal_engine.{self.team_id}")

        async def handler(stream: str, msg_id: str, fields: dict[str, str]) -> None:
            # Parse normalized market event and process
            import orjson
            payload = orjson.loads(fields.get("payload", "{}"))
            instrument_id = payload.get("instrument_id", "")
            if not instrument_id:
                return

            # Accumulate price data (in production, maintain a rolling window)
            prices = payload.get("prices", [])
            volumes = payload.get("volumes", [])
            highs = payload.get("highs", [])
            lows = payload.get("lows", [])

            if prices:
                await self.process_market_event(
                    instrument_id=instrument_id,
                    prices=prices,
                    volumes=volumes,
                    highs=highs,
                    lows=lows,
                )

        await redis_streams.consume(
            stream="market.normalized",
            group=f"signal_engine.{self.team_id}",
            consumer=consumer_name,
            handler=handler,
        )
