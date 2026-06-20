"""
Secrets management baseline.

Preferred order (per Section 17.3):
1. Cloud/host KMS/HSM-backed store
2. OS keychain / secure enclave
3. Encrypted file (temporary fallback for non-prod)

For Phase 0: environment variable loader with validation,
plus keychain integration on macOS for dev.
"""

from __future__ import annotations

import logging
import os
import subprocess
from dataclasses import dataclass
from enum import StrEnum
from typing import Any

from src.core.config import Environment, get_config

logger = logging.getLogger(__name__)


class SecretClass(StrEnum):
    API_KEY = "api_key"
    API_SECRET = "api_secret"
    DB_PASSWORD = "db_password"
    SIGNING_KEY = "signing_key"
    WEBHOOK_SECRET = "webhook_secret"


@dataclass(frozen=True)
class SecretRef:
    """Reference to a secret — never contains the actual value."""
    name: str
    secret_class: SecretClass
    env_var: str
    required_for_live: bool = True


# Registry of all known secrets
SECRET_REGISTRY: list[SecretRef] = [
    SecretRef("binance_api_key", SecretClass.API_KEY, "QE_BINANCE_API_KEY"),
    SecretRef("binance_api_secret", SecretClass.API_SECRET, "QE_BINANCE_API_SECRET"),
    SecretRef("alpaca_api_key", SecretClass.API_KEY, "QE_ALPACA_API_KEY"),
    SecretRef("alpaca_api_secret", SecretClass.API_SECRET, "QE_ALPACA_API_SECRET"),
    SecretRef("polymarket_api_key", SecretClass.API_KEY, "QE_POLYMARKET_API_KEY", required_for_live=True),
    SecretRef("polymarket_signing_key", SecretClass.SIGNING_KEY, "QE_POLYMARKET_SIGNING_KEY", required_for_live=True),
    SecretRef("oanda_api_token", SecretClass.API_KEY, "QE_OANDA_API_TOKEN"),
    SecretRef("postgres_password", SecretClass.DB_PASSWORD, "QE_PG_PASSWORD"),
    SecretRef("redis_password", SecretClass.DB_PASSWORD, "QE_REDIS_PASSWORD", required_for_live=True),
    SecretRef("alert_webhook_url", SecretClass.WEBHOOK_SECRET, "QE_ALERT_WEBHOOK_URL", required_for_live=False),
]


class SecretStore:
    """
    Multi-backend secret store.

    Resolves secrets from:
    1. macOS Keychain (dev)
    2. Environment variables (all environments)
    3. Validates completeness before live deployment
    """

    def __init__(self) -> None:
        self._cache: dict[str, str] = {}
        self._env = get_config().environment

    def get(self, name: str) -> str | None:
        """Get a secret value by name."""
        if name in self._cache:
            return self._cache[name]

        ref = self._find_ref(name)
        if ref is None:
            logger.warning("Unknown secret requested: %s", name)
            return None

        # Try environment variable first
        value = os.environ.get(ref.env_var)
        if value:
            self._cache[name] = value
            return value

        # Try macOS keychain (dev only)
        if self._env == Environment.DEV:
            value = self._read_keychain(ref.env_var)
            if value:
                self._cache[name] = value
                return value

        return None

    def get_required(self, name: str) -> str:
        """Get a secret or raise if missing."""
        value = self.get(name)
        if not value:
            raise RuntimeError(f"Required secret not found: {name}")
        return value

    def validate_for_environment(self) -> list[str]:
        """
        Validate that all required secrets are available.
        Returns list of missing secret names.
        """
        missing = []
        for ref in SECRET_REGISTRY:
            if self._env == Environment.LIVE and ref.required_for_live:
                value = self.get(ref.name)
                if not value:
                    missing.append(ref.name)
            elif self._env == Environment.PAPER:
                # Paper mode needs broker credentials
                if ref.secret_class in (SecretClass.API_KEY, SecretClass.API_SECRET):
                    value = self.get(ref.name)
                    if not value:
                        missing.append(ref.name)

        if missing:
            logger.error("Missing secrets for %s mode: %s", self._env.value, missing)
        else:
            logger.info("All required secrets validated for %s mode", self._env.value)

        return missing

    def validate_credential_separation(self) -> bool:
        """
        Verify paper and live credentials are distinct.
        Returns True if properly separated (or not applicable).
        """
        # This check requires that live keys are tagged differently
        # For now, just verify the env separation is explicit
        env = self._env
        if env == Environment.LIVE:
            # Ensure we're not accidentally using paper keys
            paper_marker = os.environ.get("QE_PAPER_MODE_MARKER")
            if paper_marker:
                logger.error(
                    "CREDENTIAL SEPARATION VIOLATION: "
                    "QE_PAPER_MODE_MARKER is set in LIVE environment"
                )
                return False
        return True

    def _find_ref(self, name: str) -> SecretRef | None:
        for ref in SECRET_REGISTRY:
            if ref.name == name:
                return ref
        return None

    def _read_keychain(self, key: str) -> str | None:
        """Read from macOS keychain."""
        try:
            result = subprocess.run(
                [
                    "security", "find-generic-password",
                    "-s", f"quantengine.{key}",
                    "-w",
                ],
                capture_output=True,
                text=True,
                timeout=5,
            )
            if result.returncode == 0:
                return result.stdout.strip()
        except Exception:
            pass
        return None


# Singleton
_store: SecretStore | None = None


def get_secret_store() -> SecretStore:
    global _store
    if _store is None:
        _store = SecretStore()
    return _store
