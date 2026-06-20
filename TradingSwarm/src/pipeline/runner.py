"""
Pipeline Runner — main orchestrator for QuantEngine.

Wires all Phase 0 services into a running pipeline:
  Data Ingest -> Signal Engine -> Risk Gate -> OMS -> Execution -> Fill -> Ledger -> Reconciliation

Manages:
- Service lifecycle (startup, shutdown)
- Startup reconciliation gate
- Background workers (outbox, reservation expiry, periodic recon)
- Graceful shutdown
"""

from __future__ import annotations

import asyncio
import logging
import signal
import sys
from typing import Any

from src.core.config import Environment, get_config
from src.core.instrument_master import InstrumentMaster
from src.core.julia_bridge import get_bridge
from src.control.kill_switch import get_conservative_mode, get_kill_switch
from src.execution.reconciler import Reconciler, startup_reconciliation
from src.ledger import outbox, postgres, redis_streams
from src.monitoring.health import start_health_server
from src.pipeline.data_ingest import DataIngestService
from src.pipeline.fill_processor import FillProcessor
from src.pipeline.oms import OrderManagementSystem
from src.pipeline.risk_gate import PreTradeRiskGate, initialize_risk_budgets
from src.pipeline.signal_engine import SignalEngine
from src.pipeline.signal_router import SignalRouter
from src.security.secrets import get_secret_store

logger = logging.getLogger(__name__)


class PipelineRunner:
    """
    Orchestrates the full hot-path pipeline for one team.

    Lifecycle:
    1. Initialize infrastructure (Postgres, Redis, Julia bridge)
    2. Run migrations
    3. Load instrument master
    4. Startup reconciliation — OMS stays frozen until clean
    5. Start background workers
    6. Start data ingest + signal processing
    7. Wait for shutdown signal
    """

    def __init__(self, team_id: str, venue: str) -> None:
        self.team_id = team_id
        self.venue = venue
        self._cfg = get_config()
        self._tasks: list[asyncio.Task] = []
        self._shutdown_event = asyncio.Event()

        # Services — initialized in start()
        self.instrument_master = InstrumentMaster()
        self.oms = OrderManagementSystem()
        self.risk_gate = PreTradeRiskGate()
        self.fill_processor: FillProcessor | None = None
        self.signal_engine: SignalEngine | None = None
        self.signal_router: SignalRouter | None = None
        self.data_ingest: DataIngestService | None = None
        self.reconciler: Reconciler | None = None
        self._adapter: Any = None

    async def start(self) -> None:
        """Full startup sequence."""
        logger.info("=" * 60)
        logger.info("QuantEngine Pipeline — %s/%s", self.team_id, self.venue)
        logger.info("Environment: %s", self._cfg.environment.value)
        logger.info("=" * 60)

        # 1. Validate secrets
        secrets = get_secret_store()
        missing = secrets.validate_for_environment()
        if missing and self._cfg.is_live:
            logger.error("Cannot start in LIVE mode with missing secrets: %s", missing)
            sys.exit(1)

        # 2. Initialize infrastructure
        logger.info("Initializing infrastructure...")
        await postgres.get_pool()
        await postgres.run_migrations()
        await redis_streams.get_redis()
        await redis_streams.ensure_consumer_groups(f"pipeline.{self.team_id}")

        # Verify Redis AOF for non-dev
        if self._cfg.environment != Environment.DEV:
            if not await redis_streams.verify_aof():
                logger.error("Redis AOF not enabled — refusing to start in %s", self._cfg.environment.value)
                sys.exit(1)

        # 3. Initialize risk budgets
        await initialize_risk_budgets()

        # 4. Load instrument master
        pool = await postgres.get_pool()
        await self.instrument_master.load_from_db(pool)
        active = self.instrument_master.list_active()
        logger.info("Loaded %d active instruments", len(active))

        # 5. Build adapter
        self._adapter = await self._build_adapter()

        # 6. Startup reconciliation — OMS stays FROZEN until clean
        if self._cfg.risk.post_restart_freeze:
            logger.info("Running startup reconciliation...")
            self.reconciler = Reconciler(self.team_id, self.venue)
            clean = await startup_reconciliation(
                self.team_id, self.venue, self._adapter
            )
            if clean:
                self.oms.unfreeze()
            else:
                logger.warning(
                    "Startup reconciliation found issues — OMS remains FROZEN. "
                    "Resolve incidents before trading."
                )
        else:
            self.oms.unfreeze()

        # 7. Build pipeline services
        self.fill_processor = FillProcessor(self.team_id, self.oms)
        self.signal_engine = SignalEngine(self.team_id, strategy_id="default")
        self.signal_router = SignalRouter(
            team_id=self.team_id,
            risk_gate=self.risk_gate,
            oms=self.oms,
            adapter=self._adapter,
            kill_switch=get_kill_switch(),
            conservative_mode=get_conservative_mode(),
            instrument_master=self.instrument_master,
        )

        self.data_ingest = DataIngestService(
            team_id=self.team_id,
            instrument_master=self.instrument_master,
        )
        self.data_ingest.register_adapter(self._adapter)

        # 8. Start health server
        await start_health_server()

        # 9. Start background workers
        self._tasks.append(asyncio.create_task(
            outbox.run_outbox_worker(), name="outbox_worker"
        ))
        self._tasks.append(asyncio.create_task(
            self._reservation_expiry_loop(), name="reservation_expiry"
        ))
        self._tasks.append(asyncio.create_task(
            self._periodic_reconciliation(), name="periodic_recon"
        ))
        self._tasks.append(asyncio.create_task(
            self._stale_order_detector(), name="stale_order_detector"
        ))

        # 10. Start data ingest
        await self.data_ingest.start()

        # 11. Start signal consumer + router
        self._tasks.append(asyncio.create_task(
            self._signal_consumer_loop(), name="signal_consumer"
        ))
        self._tasks.append(asyncio.create_task(
            self._fill_consumer_loop(), name="fill_consumer"
        ))

        logger.info("Pipeline started — all services running")

        # 12. Install signal handlers
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, self._request_shutdown)

        # Wait for shutdown
        await self._shutdown_event.wait()
        await self._shutdown()

    async def _build_adapter(self) -> Any:
        """Build the appropriate adapter for this team/venue."""
        cfg = self._cfg
        secrets = get_secret_store()

        if cfg.environment == Environment.DEV:
            # Use paper adapter for dev
            from src.execution.paper_adapter import PaperAdapter
            adapter = PaperAdapter(team_id=self.team_id, instrument_master=self.instrument_master)
            await adapter.connect()
            return adapter

        if self.venue == "binance":
            from src.execution.binance_adapter import BinanceAdapter
            adapter = BinanceAdapter(
                team_id=self.team_id,
                api_key=secrets.get_required("binance_api_key"),
                api_secret=secrets.get_required("binance_api_secret"),
                use_futures=False,
                testnet=cfg.is_paper,
            )
            await adapter.connect()
            return adapter

        raise ValueError(f"Unsupported venue: {self.venue}")

    # ---- Consumer loops ----

    async def _signal_consumer_loop(self) -> None:
        """Consume signal events and route through risk -> OMS -> execution."""
        import orjson
        group = f"signal_router.{self.team_id}"
        await redis_streams.ensure_consumer_groups(group)

        async def handler(stream: str, msg_id: str, fields: dict[str, str]) -> None:
            payload = orjson.loads(fields.get("payload", "{}"))
            if self.signal_router:
                await self.signal_router.route_signal(payload)

        # Also reclaim any pending on startup
        await redis_streams.reclaim_pending(
            "signal.generated", group,
            f"router.{self.team_id}", handler,
        )

        await redis_streams.consume(
            stream="signal.generated",
            group=group,
            consumer=f"router.{self.team_id}",
            handler=handler,
        )

    async def _fill_consumer_loop(self) -> None:
        """Consume fill events and update positions + cash ledger."""
        import orjson
        group = f"fill_processor.{self.team_id}"
        await redis_streams.ensure_consumer_groups(group)

        async def handler(stream: str, msg_id: str, fields: dict[str, str]) -> None:
            payload = orjson.loads(fields.get("payload", "{}"))
            if self.fill_processor:
                await self.fill_processor.process_fill_event(payload)

        await redis_streams.consume(
            stream="fills.events",
            group=group,
            consumer=f"processor.{self.team_id}",
            handler=handler,
        )

    # ---- Background workers ----

    async def _reservation_expiry_loop(self) -> None:
        while not self._shutdown_event.is_set():
            try:
                await self.risk_gate.expire_stale_reservations()
            except Exception:
                logger.exception("Reservation expiry error")
            await asyncio.sleep(10)

    async def _periodic_reconciliation(self) -> None:
        """Run reconciliation every 60 seconds even if streams look healthy."""
        while not self._shutdown_event.is_set():
            await asyncio.sleep(60)
            try:
                if self.reconciler and self._adapter:
                    incidents = await self.reconciler.reconcile_all(self._adapter)
                    if incidents:
                        critical = [i for i in incidents if i.severity.value == "critical"]
                        if critical:
                            ks = get_kill_switch()
                            if not ks.is_killed:
                                await ks.activate(
                                    f"Critical reconciliation incidents: {len(critical)}",
                                    actor="periodic_recon",
                                )
            except Exception:
                logger.exception("Periodic reconciliation error")

    async def _stale_order_detector(self) -> None:
        """Detect stale working orders every 30 seconds."""
        while not self._shutdown_event.is_set():
            await asyncio.sleep(30)
            try:
                stale = await self.oms.detect_stale_orders()
                for order in stale:
                    logger.warning(
                        "Stale order: %s (state=%s, last_update=%s)",
                        order["venue_order_id_internal"],
                        order["current_state"],
                        order["updated_at"],
                    )
            except Exception:
                logger.exception("Stale order detection error")

    # ---- Shutdown ----

    def _request_shutdown(self) -> None:
        logger.info("Shutdown requested")
        self._shutdown_event.set()

    async def _shutdown(self) -> None:
        logger.info("Shutting down pipeline...")

        # Cancel all background tasks
        for task in self._tasks:
            task.cancel()
        await asyncio.gather(*self._tasks, return_exceptions=True)

        # Stop data ingest
        if self.data_ingest:
            await self.data_ingest.stop()

        # Close infrastructure
        bridge = get_bridge()
        await bridge.close()
        await redis_streams.close_redis()
        await postgres.close_pool()

        logger.info("Pipeline shutdown complete")


# Scope enforcement — only these team/venue pairs are allowed to run.
# Everything else stays dormant until it earns the right to activate.
ALLOWED_SCOPES = {
    ("crypto", "binance"),
    ("crypto", "paper"),
}

# Allowed instruments per team — narrow lane until proven.
ALLOWED_INSTRUMENTS = {
    "crypto": ["BTCUSDT", "ETHUSDT"],
}


async def run_pipeline(team_id: str = "crypto", venue: str = "binance") -> None:
    """Entry point — start a pipeline for one team."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-8s %(name)s — %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    if (team_id, venue) not in ALLOWED_SCOPES:
        logger.error(
            "Scope (%s, %s) not in ALLOWED_SCOPES. "
            "Narrow lane: prove edge on crypto/binance before expanding. "
            "Allowed: %s",
            team_id, venue, ALLOWED_SCOPES,
        )
        sys.exit(1)

    runner = PipelineRunner(team_id=team_id, venue=venue)
    await runner.start()


async def run_shadow(team_id: str = "crypto", venue: str = "binance") -> None:
    """Entry point — shadow mode. Real data, no orders, signal comparison."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-8s %(name)s — %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    from src.pipeline.shadow_mode import ShadowSession

    logger.info("Starting SHADOW MODE — crypto/binance BTC+ETH")
    logger.info("Real market data. No orders. Signal comparison only.")

    session = ShadowSession(
        team_id=team_id,
        venue=venue,
        instruments=ALLOWED_INSTRUMENTS.get(team_id, ["BTCUSDT"]),
    )
    session._session_start = __import__("datetime").datetime.now(
        __import__("datetime").timezone.utc
    )

    logger.info("Shadow session %s started. Press Ctrl+C to stop and see report.", session._session_id)

    try:
        while True:
            # Update outcomes for pending signals
            await session.update_outcomes()

            # Periodic stats
            stats = session.get_stats()
            if stats["completed_signals"] > 0 and stats["total_signals"] % 10 == 0:
                logger.info(
                    "Shadow: %d signals, %d completed, hit_rate_5m=%.1f%%",
                    stats["total_signals"], stats["completed_signals"],
                    stats.get("hit_rate_5m", 0) * 100,
                )

            await asyncio.sleep(5)
    except (KeyboardInterrupt, asyncio.CancelledError):
        pass

    # Final report
    session.print_report()
    count = await session.persist_signals()
    logger.info("Persisted %d shadow signals to database", count)


async def run_validation(level: str = "plumbing") -> None:
    """Entry point — run validation pack at specified level."""
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-8s %(name)s — %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    from src.pipeline.validation_pack import ValidationLevel, ValidationPack

    pack = ValidationPack()
    vl = ValidationLevel(level)

    if vl == ValidationLevel.PLUMBING:
        await pack.measure_plumbing()
    elif vl == ValidationLevel.SHADOW:
        await pack.measure_plumbing()
        await pack.measure_shadow()
    elif vl == ValidationLevel.PAPER:
        await pack.measure_plumbing()
        await pack.measure_shadow()
        await pack.measure_paper()
    elif vl == ValidationLevel.PRE_LIVE:
        await pack.measure_plumbing()
        await pack.measure_shadow()
        await pack.measure_paper()

    pack.print_report(vl)


def main() -> None:
    """CLI entry point."""
    import argparse
    parser = argparse.ArgumentParser(description="QuantEngine Pipeline")
    sub = parser.add_subparsers(dest="command", help="Command")

    # Run pipeline
    run_cmd = sub.add_parser("run", help="Run trading pipeline")
    run_cmd.add_argument("--team", default="crypto")
    run_cmd.add_argument("--venue", default="binance")

    # Shadow mode
    shadow_cmd = sub.add_parser("shadow", help="Shadow mode — real data, no orders")
    shadow_cmd.add_argument("--team", default="crypto")
    shadow_cmd.add_argument("--venue", default="binance")

    # Validation
    val_cmd = sub.add_parser("validate", help="Run validation pack")
    val_cmd.add_argument("--level", default="plumbing",
                         choices=["plumbing", "shadow", "paper", "pre_live"])

    args = parser.parse_args()

    if args.command == "shadow":
        asyncio.run(run_shadow(team_id=args.team, venue=args.venue))
    elif args.command == "validate":
        asyncio.run(run_validation(level=args.level))
    else:
        asyncio.run(run_pipeline(
            team_id=getattr(args, "team", "crypto"),
            venue=getattr(args, "venue", "binance"),
        ))


if __name__ == "__main__":
    main()
