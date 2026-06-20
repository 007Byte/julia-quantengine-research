"""Unit tests for signal router logic (mocked dependencies)."""

import uuid
from decimal import Decimal
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from src.core.event_schema import (
    AssetClass,
    InstrumentType,
    OrderIntentState,
    RiskDecision,
    RiskDecisionType,
    RiskReservation,
    Side,
)
from src.core.instrument_master import Instrument, InstrumentMaster, SymbolMapping
from src.control.kill_switch import ConservativeMode, KillSwitch
from src.pipeline.signal_router import SignalRouter


@pytest.fixture
def instrument_master() -> InstrumentMaster:
    im = InstrumentMaster()
    btc = Instrument(
        asset_class=AssetClass.CRYPTO,
        instrument_type=InstrumentType.SPOT,
        base_symbol="BTC",
        quote_symbol="USDT",
    )
    im.register(btc, [
        SymbolMapping(instrument_id=btc.instrument_id, venue="paper", venue_symbol="BTCUSDT"),
    ])
    return im


@pytest.fixture
def btc_id(instrument_master: InstrumentMaster) -> str:
    return str(instrument_master.list_active()[0].instrument_id)


class TestSignalRouterKillSwitch:
    def test_kill_switch_blocks_signal(self, instrument_master, btc_id):
        ks = KillSwitch()
        ks._global_killed = True

        router = SignalRouter(
            team_id="crypto",
            risk_gate=MagicMock(),
            oms=MagicMock(),
            adapter=MagicMock(),
            kill_switch=ks,
            conservative_mode=ConservativeMode(),
            instrument_master=instrument_master,
        )

        import asyncio
        result = asyncio.get_event_loop().run_until_complete(
            router.route_signal({
                "signal_id": str(uuid.uuid4()),
                "instrument_id": btc_id,
                "side": "buy",
                "strength": 0.8,
            })
        )

        assert result["status"] == "killed"

    def test_team_kill_switch_blocks(self, instrument_master, btc_id):
        ks = KillSwitch()
        ks._team_killed.add("crypto")

        router = SignalRouter(
            team_id="crypto",
            risk_gate=MagicMock(),
            oms=MagicMock(),
            adapter=MagicMock(),
            kill_switch=ks,
            conservative_mode=ConservativeMode(),
            instrument_master=instrument_master,
        )

        import asyncio
        result = asyncio.get_event_loop().run_until_complete(
            router.route_signal({
                "signal_id": str(uuid.uuid4()),
                "instrument_id": btc_id,
                "side": "buy",
                "strength": 0.8,
            })
        )

        assert result["status"] == "killed"


class TestSignalRouterFrozen:
    def test_frozen_oms_blocks_signal(self, instrument_master, btc_id):
        oms = MagicMock()
        oms.is_frozen = True

        router = SignalRouter(
            team_id="crypto",
            risk_gate=MagicMock(),
            oms=oms,
            adapter=MagicMock(),
            kill_switch=KillSwitch(),
            conservative_mode=ConservativeMode(),
            instrument_master=instrument_master,
        )

        import asyncio
        result = asyncio.get_event_loop().run_until_complete(
            router.route_signal({
                "signal_id": str(uuid.uuid4()),
                "instrument_id": btc_id,
                "side": "buy",
                "strength": 0.8,
            })
        )

        assert result["status"] == "frozen"


class TestConservativeMode:
    def test_conservative_blocks_strategy(self, instrument_master, btc_id):
        cm = ConservativeMode()
        cm._active = True
        cm._allowed_strategies = {"safe_only"}

        router = SignalRouter(
            team_id="crypto",
            risk_gate=MagicMock(),
            oms=MagicMock(is_frozen=False),
            adapter=MagicMock(),
            kill_switch=KillSwitch(),
            conservative_mode=cm,
            instrument_master=instrument_master,
        )

        import asyncio
        result = asyncio.get_event_loop().run_until_complete(
            router.route_signal({
                "signal_id": str(uuid.uuid4()),
                "instrument_id": btc_id,
                "side": "buy",
                "strength": 0.8,
                "strategy_id": "aggressive_strategy",
            })
        )

        assert result["status"] == "conservative_blocked"
