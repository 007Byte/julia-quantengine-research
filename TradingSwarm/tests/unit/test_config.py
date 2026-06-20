"""Unit tests for configuration."""

import os

import pytest

from src.core.config import Config, Environment, reset_config


class TestConfig:
    def setup_method(self):
        reset_config()

    def test_default_config(self):
        cfg = Config()
        assert cfg.environment == Environment.DEV
        assert cfg.postgres.port == 5432
        assert cfg.redis.port == 6379
        assert cfg.risk.global_max_daily_loss_pct == 0.05

    def test_postgres_dsn(self):
        cfg = Config(postgres={"host": "db.local", "port": 5433, "database": "qe", "user": "admin", "password": "secret"})
        assert "db.local:5433/qe" in cfg.postgres.dsn

    def test_redis_url(self):
        cfg = Config(redis={"host": "redis.local", "port": 6380, "password": "pass"})
        assert "redis.local:6380" in cfg.redis.url
        assert ":pass@" in cfg.redis.url

    def test_is_live(self):
        cfg = Config(environment=Environment.LIVE)
        assert cfg.is_live
        assert not cfg.is_paper

    def test_is_paper(self):
        cfg = Config(environment=Environment.PAPER)
        assert cfg.is_paper
        assert not cfg.is_live

    def test_from_env(self, monkeypatch):
        monkeypatch.setenv("QE_ENVIRONMENT", "paper")
        monkeypatch.setenv("QE_PG_HOST", "pg.example.com")
        monkeypatch.setenv("QE_ENABLED_TEAMS", "crypto,stocks")

        reset_config()
        cfg = Config.from_env()
        assert cfg.environment == Environment.PAPER
        assert cfg.postgres.host == "pg.example.com"
        assert cfg.enabled_teams == ["crypto", "stocks"]
