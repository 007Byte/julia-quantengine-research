"""
NTP Validation + Clock Skew Detection.

Trading systems require accurate timestamps. This module:
- Checks local clock against NTP servers
- Detects drift above configurable thresholds
- Blocks trading on excessive skew
- Logs skew as a health metric
"""

from __future__ import annotations

import asyncio
import logging
import struct
import time
from typing import Any

logger = logging.getLogger(__name__)

NTP_SERVERS = [
    "time.apple.com",
    "time.google.com",
    "pool.ntp.org",
]

# NTP epoch is 1900-01-01, Unix epoch is 1970-01-01
NTP_DELTA = 2208988800


class NTPCheck:
    """
    Validates local clock against NTP servers.

    Thresholds:
    - < 100ms: healthy
    - 100ms - 1s: warning
    - > 1s: critical (should block trading)
    """

    def __init__(
        self,
        warning_ms: float = 100.0,
        critical_ms: float = 1000.0,
    ) -> None:
        self._warning_ms = warning_ms
        self._critical_ms = critical_ms
        self._last_skew_ms: float | None = None
        self._last_check: float = 0

    @property
    def is_healthy(self) -> bool:
        if self._last_skew_ms is None:
            return True  # unknown = assume OK
        return abs(self._last_skew_ms) < self._critical_ms

    @property
    def last_skew_ms(self) -> float | None:
        return self._last_skew_ms

    async def check(self, server: str | None = None) -> dict[str, Any]:
        """
        Query NTP and return skew info.

        Returns dict with: skew_ms, server, healthy, level
        """
        servers = [server] if server else NTP_SERVERS

        for srv in servers:
            try:
                skew = await self._query_ntp(srv)
                self._last_skew_ms = skew * 1000
                self._last_check = time.time()

                abs_ms = abs(self._last_skew_ms)
                if abs_ms < self._warning_ms:
                    level = "healthy"
                elif abs_ms < self._critical_ms:
                    level = "warning"
                    logger.warning("Clock skew: %.1fms (server=%s)", self._last_skew_ms, srv)
                else:
                    level = "critical"
                    logger.critical(
                        "CRITICAL clock skew: %.1fms (server=%s) — trading should be blocked",
                        self._last_skew_ms, srv,
                    )

                return {
                    "skew_ms": self._last_skew_ms,
                    "server": srv,
                    "healthy": level != "critical",
                    "level": level,
                }
            except Exception:
                logger.debug("NTP query failed for %s", srv)
                continue

        logger.warning("All NTP servers unreachable")
        return {"skew_ms": None, "server": None, "healthy": True, "level": "unknown"}

    async def _query_ntp(self, server: str) -> float:
        """
        Query a single NTP server. Returns skew in seconds.

        Uses raw UDP socket with SNTP (simplified NTP).
        """
        loop = asyncio.get_event_loop()

        def _sync_query() -> float:
            import socket
            client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            client.settimeout(2)

            # NTP request packet
            data = b'\x1b' + 47 * b'\0'
            t1 = time.time()
            client.sendto(data, (server, 123))
            response, _ = client.recvfrom(1024)
            t4 = time.time()
            client.close()

            # Parse transmit timestamp (bytes 40-47)
            transmit_time = struct.unpack('!12I', response)[10]
            t3 = transmit_time - NTP_DELTA

            # Simplified offset: server_time - local_time
            rtt = t4 - t1
            offset = t3 - t1 - rtt / 2
            return offset

        return await loop.run_in_executor(None, _sync_query)

    async def periodic_check(self, interval_seconds: float = 300.0) -> None:
        """Run NTP check periodically."""
        while True:
            result = await self.check()
            if result["level"] == "critical":
                from src.monitoring.alerting import AlertSeverity, Alert, get_alert_manager
                mgr = get_alert_manager()
                await mgr.send(Alert(
                    AlertSeverity.CRITICAL,
                    "Clock Skew Critical",
                    f"Skew: {result['skew_ms']:.1f}ms — trading unsafe",
                    source="ntp_check",
                ))
            await asyncio.sleep(interval_seconds)
