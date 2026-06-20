"""
Remote Alerting — multi-channel alert delivery.

Channels:
- Webhook (Slack, Discord, PagerDuty, etc.)
- Console/log (always)
- Redis stream (for dashboard consumption)

Critical alerts (Section 18.2):
- Broker disconnected, feed stale, OMS restart
- Unresolved reconciliation incident
- Reservation deadlock/timeout, DLQ growth
- Order state mismatch, unusual slippage
- Kill switch activation
"""

from __future__ import annotations

import asyncio
import logging
import uuid
from datetime import datetime, timezone
from enum import StrEnum
from typing import Any

import httpx

from src.core.config import get_config

logger = logging.getLogger(__name__)


class AlertSeverity(StrEnum):
    INFO = "info"
    WARNING = "warning"
    CRITICAL = "critical"
    EMERGENCY = "emergency"


class Alert:
    """A single alert."""

    def __init__(
        self,
        severity: AlertSeverity,
        title: str,
        message: str,
        source: str,
        details: dict[str, Any] | None = None,
    ) -> None:
        self.alert_id = str(uuid.uuid4())[:8]
        self.severity = severity
        self.title = title
        self.message = message
        self.source = source
        self.details = details or {}
        self.created_at = datetime.now(timezone.utc)

    def to_dict(self) -> dict[str, Any]:
        return {
            "alert_id": self.alert_id,
            "severity": self.severity.value,
            "title": self.title,
            "message": self.message,
            "source": self.source,
            "details": self.details,
            "created_at": self.created_at.isoformat(),
        }


class AlertManager:
    """
    Multi-channel alert dispatcher.

    All alerts go to log. Critical/emergency also go to webhook.
    """

    def __init__(self) -> None:
        self._webhook_url = get_config().monitoring.alert_webhook_url
        self._history: list[Alert] = []
        self._max_history = 1000
        self._rate_limit: dict[str, float] = {}  # title -> last_sent timestamp
        self._rate_limit_seconds = 60.0

    async def send(self, alert: Alert) -> None:
        """Dispatch an alert to all configured channels."""
        # Rate limit by title
        now = alert.created_at.timestamp()
        last = self._rate_limit.get(alert.title, 0)
        if now - last < self._rate_limit_seconds and alert.severity != AlertSeverity.EMERGENCY:
            return
        self._rate_limit[alert.title] = now

        # Always log
        log_fn = {
            AlertSeverity.INFO: logger.info,
            AlertSeverity.WARNING: logger.warning,
            AlertSeverity.CRITICAL: logger.critical,
            AlertSeverity.EMERGENCY: logger.critical,
        }.get(alert.severity, logger.warning)
        log_fn("[ALERT:%s] %s — %s", alert.severity.value, alert.title, alert.message)

        # Store in history
        self._history.append(alert)
        if len(self._history) > self._max_history:
            self._history = self._history[-self._max_history:]

        # Webhook for critical/emergency
        if alert.severity in (AlertSeverity.CRITICAL, AlertSeverity.EMERGENCY):
            await self._send_webhook(alert)

    async def _send_webhook(self, alert: Alert) -> None:
        """Send alert to configured webhook URL."""
        if not self._webhook_url:
            return

        payload = {
            "text": f"*[{alert.severity.value.upper()}]* {alert.title}\n{alert.message}",
            **alert.to_dict(),
        }

        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                resp = await client.post(self._webhook_url, json=payload)
                if resp.status_code >= 400:
                    logger.warning("Webhook delivery failed: %d", resp.status_code)
        except Exception:
            logger.warning("Webhook delivery error (non-fatal)")

    def get_recent(self, count: int = 50) -> list[dict[str, Any]]:
        return [a.to_dict() for a in self._history[-count:]]

    # ---- Convenience methods ----

    async def broker_disconnected(self, venue: str, team_id: str) -> None:
        await self.send(Alert(
            AlertSeverity.CRITICAL, "Broker Disconnected",
            f"{venue} disconnected for team {team_id}",
            source="adapter",
        ))

    async def feed_stale(self, instrument_id: str, seconds: float) -> None:
        await self.send(Alert(
            AlertSeverity.WARNING, "Feed Stale",
            f"No data for {instrument_id} in {seconds:.0f}s",
            source="data_ingest",
        ))

    async def recon_incident(self, team_id: str, venue: str, incident_type: str, severity: str) -> None:
        await self.send(Alert(
            AlertSeverity.CRITICAL if severity == "critical" else AlertSeverity.WARNING,
            "Reconciliation Incident",
            f"{incident_type} on {venue} for {team_id}",
            source="reconciler",
        ))

    async def kill_switch_activated(self, reason: str, scope: str) -> None:
        await self.send(Alert(
            AlertSeverity.EMERGENCY, "Kill Switch Activated",
            f"{scope}: {reason}",
            source="kill_switch",
        ))

    async def slippage_breach(self, venue: str, order_id: str, slippage_bps: float) -> None:
        await self.send(Alert(
            AlertSeverity.WARNING, "Unusual Slippage",
            f"Order {order_id} on {venue}: {slippage_bps:.1f} bps",
            source="oms",
        ))

    async def dlq_growth(self, stream: str, count: int) -> None:
        await self.send(Alert(
            AlertSeverity.CRITICAL, "DLQ Growing",
            f"{stream}.dlq has {count} messages",
            source="redis_streams",
        ))


_manager: AlertManager | None = None


def get_alert_manager() -> AlertManager:
    global _manager
    if _manager is None:
        _manager = AlertManager()
    return _manager
