"""
QuantEngine configuration — single source of truth for all settings.

Environment-aware: dev / paper / live with strict separation.
"""

from __future__ import annotations

import os
from enum import StrEnum
from pathlib import Path
from typing import Any

from dotenv import load_dotenv
from pydantic import BaseModel, Field, field_validator

load_dotenv()


class Environment(StrEnum):
    DEV = "dev"
    PAPER = "paper"
    LIVE = "live"


class PostgresConfig(BaseModel):
    host: str = Field(default="localhost")
    port: int = Field(default=5432)
    database: str = Field(default="quantengine")
    user: str = Field(default="quantengine")
    password: str = Field(default="")
    min_connections: int = Field(default=5)
    max_connections: int = Field(default=20)

    @property
    def dsn(self) -> str:
        return f"postgresql://{self.user}:{self.password}@{self.host}:{self.port}/{self.database}"


class RedisConfig(BaseModel):
    host: str = Field(default="localhost")
    port: int = Field(default=6379)
    db: int = Field(default=0)
    password: str = Field(default="")
    # AOF policy — enforced at startup
    aof_enabled: bool = Field(default=True)
    # Consumer group settings
    block_ms: int = Field(default=5000)
    # Pending message recovery
    reclaim_idle_ms: int = Field(default=30_000)
    max_retries: int = Field(default=5)

    @property
    def url(self) -> str:
        auth = f":{self.password}@" if self.password else ""
        return f"redis://{auth}{self.host}:{self.port}/{self.db}"


class JuliaBridgeConfig(BaseModel):
    endpoint: str = Field(default="tcp://127.0.0.1:5555")
    request_timeout_ms: int = Field(default=3000)
    heavy_timeout_ms: int = Field(default=15000)
    max_retries: int = Field(default=3)
    heartbeat_interval_ms: int = Field(default=5000)
    heartbeat_timeout_ms: int = Field(default=10000)


class RiskConfig(BaseModel):
    # Hard non-overridable limits
    global_max_daily_loss_pct: float = Field(default=0.05)
    global_max_drawdown_pct: float = Field(default=0.15)
    global_gross_exposure_cap: float = Field(default=1_000_000.0)
    per_team_daily_loss_pct: float = Field(default=0.03)
    single_position_cap_pct: float = Field(default=0.10)
    position_count_cap: int = Field(default=50)
    venue_concentration_cap_pct: float = Field(default=0.50)
    # Reservation settings
    reservation_expiry_seconds: int = Field(default=60)
    # Post-restart
    post_restart_freeze: bool = Field(default=True)


class MonitoringConfig(BaseModel):
    health_port: int = Field(default=8090)
    metrics_port: int = Field(default=9090)
    alert_webhook_url: str = Field(default="")


class Config(BaseModel):
    """Root configuration — loaded from environment variables with QE_ prefix."""

    environment: Environment = Field(default=Environment.DEV)
    instance_id: str = Field(default="qe-dev-01")

    postgres: PostgresConfig = Field(default_factory=PostgresConfig)
    redis: RedisConfig = Field(default_factory=RedisConfig)
    julia: JuliaBridgeConfig = Field(default_factory=JuliaBridgeConfig)
    risk: RiskConfig = Field(default_factory=RiskConfig)
    monitoring: MonitoringConfig = Field(default_factory=MonitoringConfig)

    # Teams enabled for this instance
    enabled_teams: list[str] = Field(default_factory=lambda: ["crypto"])

    @field_validator("environment", mode="before")
    @classmethod
    def parse_environment(cls, v: Any) -> str:
        if isinstance(v, str):
            return v.lower()
        return v

    @property
    def is_live(self) -> bool:
        return self.environment == Environment.LIVE

    @property
    def is_paper(self) -> bool:
        return self.environment == Environment.PAPER

    @classmethod
    def from_env(cls) -> Config:
        """Build config from QE_ prefixed environment variables."""
        return cls(
            environment=os.getenv("QE_ENVIRONMENT", "dev"),
            instance_id=os.getenv("QE_INSTANCE_ID", "qe-dev-01"),
            postgres=PostgresConfig(
                host=os.getenv("QE_PG_HOST", "localhost"),
                port=int(os.getenv("QE_PG_PORT", "5432")),
                database=os.getenv("QE_PG_DATABASE", "quantengine"),
                user=os.getenv("QE_PG_USER", "quantengine"),
                password=os.getenv("QE_PG_PASSWORD", ""),
            ),
            redis=RedisConfig(
                host=os.getenv("QE_REDIS_HOST", "localhost"),
                port=int(os.getenv("QE_REDIS_PORT", "6379")),
                password=os.getenv("QE_REDIS_PASSWORD", ""),
            ),
            julia=JuliaBridgeConfig(
                endpoint=os.getenv("QE_JULIA_ENDPOINT", "tcp://127.0.0.1:5555"),
            ),
            risk=RiskConfig(
                global_max_daily_loss_pct=float(
                    os.getenv("QE_MAX_DAILY_LOSS_PCT", "0.05")
                ),
                global_max_drawdown_pct=float(
                    os.getenv("QE_MAX_DRAWDOWN_PCT", "0.15")
                ),
            ),
            enabled_teams=os.getenv("QE_ENABLED_TEAMS", "crypto").split(","),
        )


# Singleton — import this
_config: Config | None = None


def get_config() -> Config:
    global _config
    if _config is None:
        _config = Config.from_env()
    return _config


def reset_config() -> None:
    """For testing only."""
    global _config
    _config = None
