"""
Service Supervisor — health-based lifecycle management.

Monitors service health and takes corrective action:
- Restart degraded services
- Escalate persistent failures
- Track service uptime/downtime
- Coordinate graceful shutdown
"""

from __future__ import annotations

import asyncio
import logging
import time
from enum import StrEnum
from typing import Any, Callable, Coroutine

from src.monitoring.alerting import Alert, AlertSeverity, get_alert_manager

logger = logging.getLogger(__name__)


class ServiceState(StrEnum):
    STARTING = "starting"
    HEALTHY = "healthy"
    DEGRADED = "degraded"
    FAILED = "failed"
    STOPPED = "stopped"


class SupervisedService:
    """Tracks the state and health of a single service."""

    def __init__(
        self,
        name: str,
        health_check: Callable[[], Coroutine[Any, Any, bool]],
        restart_fn: Callable[[], Coroutine[Any, Any, None]] | None = None,
        max_restarts: int = 3,
        check_interval: float = 10.0,
    ) -> None:
        self.name = name
        self._health_check = health_check
        self._restart_fn = restart_fn
        self._max_restarts = max_restarts
        self._check_interval = check_interval

        self.state = ServiceState.STARTING
        self.restart_count = 0
        self.last_healthy: float = 0
        self.last_check: float = 0
        self.consecutive_failures = 0

    async def check_health(self) -> bool:
        """Run health check and update state."""
        try:
            healthy = await self._health_check()
            self.last_check = time.time()

            if healthy:
                self.state = ServiceState.HEALTHY
                self.last_healthy = time.time()
                self.consecutive_failures = 0
                return True
            else:
                self.consecutive_failures += 1
                if self.consecutive_failures >= 3:
                    self.state = ServiceState.FAILED
                else:
                    self.state = ServiceState.DEGRADED
                return False
        except Exception:
            self.consecutive_failures += 1
            self.state = ServiceState.DEGRADED if self.consecutive_failures < 3 else ServiceState.FAILED
            return False

    async def attempt_restart(self) -> bool:
        """Attempt to restart the service."""
        if self._restart_fn is None:
            return False
        if self.restart_count >= self._max_restarts:
            logger.error("Service %s exceeded max restarts (%d)", self.name, self._max_restarts)
            return False

        logger.warning("Restarting service: %s (attempt %d/%d)", self.name, self.restart_count + 1, self._max_restarts)
        try:
            await self._restart_fn()
            self.restart_count += 1
            self.state = ServiceState.STARTING
            return True
        except Exception:
            logger.exception("Restart failed for %s", self.name)
            self.state = ServiceState.FAILED
            return False

    def status(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "state": self.state.value,
            "restart_count": self.restart_count,
            "consecutive_failures": self.consecutive_failures,
            "last_healthy": self.last_healthy,
            "uptime_since_restart": time.time() - self.last_healthy if self.last_healthy > 0 else 0,
        }


class ServiceSupervisor:
    """
    Monitors all registered services and takes corrective action.
    """

    def __init__(self) -> None:
        self._services: dict[str, SupervisedService] = {}
        self._alert_manager = get_alert_manager()

    def register(self, service: SupervisedService) -> None:
        self._services[service.name] = service

    def get_status(self) -> list[dict[str, Any]]:
        return [s.status() for s in self._services.values()]

    @property
    def all_healthy(self) -> bool:
        return all(s.state == ServiceState.HEALTHY for s in self._services.values())

    async def check_all(self) -> dict[str, bool]:
        """Run health checks on all services."""
        results = {}
        for name, service in self._services.items():
            healthy = await service.check_health()
            results[name] = healthy

            if not healthy and service.state == ServiceState.FAILED:
                restarted = await service.attempt_restart()
                if not restarted:
                    await self._alert_manager.send(Alert(
                        AlertSeverity.CRITICAL,
                        f"Service Failed: {name}",
                        f"Service {name} is FAILED and could not be restarted "
                        f"({service.restart_count}/{service._max_restarts} restarts used)",
                        source="supervisor",
                    ))

        return results

    async def run(self, interval: float = 10.0) -> None:
        """Continuous supervision loop."""
        logger.info("Supervisor started: monitoring %d services", len(self._services))
        while True:
            try:
                results = await self.check_all()
                unhealthy = [n for n, h in results.items() if not h]
                if unhealthy:
                    logger.warning("Unhealthy services: %s", unhealthy)
            except asyncio.CancelledError:
                logger.info("Supervisor shutting down")
                return
            except Exception:
                logger.exception("Supervisor check error")
            await asyncio.sleep(interval)
