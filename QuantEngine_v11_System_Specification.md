# QuantEngine v11.1 — System Specification

## Status and Honest Assessment

This document describes the system **as built** with an honest assessment of what is proven vs what is claimed. It supersedes all prior specs (v1–v10).

- **Architecture plan**: v10 (approved)
- **Code implementation**: Phases 0–5 complete
- **Tests**: 236 passing (0.93s)
- **Operational validation**: **NOT STARTED** — all pre-live gates remain unchecked
- **Trading edge**: **NOT DEMONSTRATED** — no live or shadow fills exist yet
- **Current active scope**: crypto team / Binance / BTC+ETH only. All other teams/venues are dormant.

### What this system IS right now

A well-structured trading control system with deterministic signal generation, durable order management, atomic risk reservations, and broker-truth reconciliation. The safety architecture is designed to prevent the system from doing something catastrophically stupid.

### What this system IS NOT yet

A proven live trading system. Architecture is not evidence. 38 models is not alpha. A paper adapter with 5 bps slippage does not validate execution quality. Zero shadow sessions have been run. Zero real fills exist. The distance between "plumbing works" and "system has tradable edge after costs" is the entire remaining problem.

### Validation levels (defined, not yet passed)

| Level | Status | What it proves |
|---|---|---|
| PLUMBING | Requires infra up | Postgres, Redis, Julia bridge, adapters connect |
| SHADOW | Not started | Signals have directional accuracy against real market data |
| PAPER | Not started | Full pipeline produces fills, reconciliation clean, positions correct |
| PRE_LIVE | Not started | 30+ days of measured paper performance meeting all thresholds |

---

## 1. Executive Summary

QuantEngine is a **deterministic, event-driven trading platform** built across two codebases:

1. **Julia QuantEngine** — the numerical core (18K+ LOC, 38 models, 1,561 tests)
2. **Python TradingSwarm** — the production orchestration layer (45 modules, 236 tests)

The system operates across four distinct planes:

| Plane | Purpose | Latency | Failure mode |
|---|---|---|---|
| **Hot Path** | Data → Signal → Risk → OMS → Execution → Fill → Reconciliation | Milliseconds | System stops trading |
| **Warm Path** | News, LLM extraction, external positioning → cached features | Seconds–minutes | Signal engine continues without |
| **Cold Path** | Replay, retraining, reporting, tax | Hours–days | No impact on live |
| **Control Plane** | Risk aggregation, kill switch, capital allocation, monitoring | Seconds | Triggers protective action |

**Active scope**: crypto team, Binance venue, BTC/USDT + ETH/USDT only. Everything else is implemented but dormant until this narrow lane is validated.

**Core principle**: there are **no autonomous agents in the live trade path**. Every step is a deterministic service. No LLMs in execution authority. Broker truth beats internal assumptions.

---

## 2. Design Principles (Enforced)

| # | Principle | How enforced |
|---|---|---|
| 1 | **Determinism over autonomy** | Julia ensemble is stateless; same data → same signal |
| 2 | **Broker truth beats internal** | Reconciler compares internal vs broker; incidents freeze OMS |
| 3 | **At-least-once + idempotent handlers** | Redis consumer groups + XACK after processing; fill/intent dedup by ID |
| 4 | **All critical decisions are durable** | DB-first + outbox pattern; Postgres transaction before stream publish |
| 5 | **Survive restarts** | OMS frozen post-restart until reconciliation clean |
| 6 | **Research can fail silently** | FeatureStore returns None; signal engine continues |
| 7 | **Correctness before breadth** | State machines enforce risk → reservation → OMS path; no shortcuts |

---

## 3. Architecture Overview

### 3.1 Hot Path — Live Trading Pipeline

```
[1. Data Ingest + Normalization]
   venue feeds → canonical instrument_id → NormalizedBar/Trade/Quote
         ↓ Redis Stream: market.normalized
[2. Signal Engine]
   consume market data → Julia ZMQ bridge → features (18) → ensemble (38 models)
         ↓ Redis Stream: signal.generated (if strength ≥ 0.55)
[3. Signal Router]
   kill switch check → OMS freeze check → conservative mode filter
   → compute sizing → build OrderIntent
         ↓ synchronous call
[4. Pre-Trade Risk Gate]
   lock risk_budgets FOR UPDATE → hard limit checks → atomic reservation
   → persist RiskDecision + RiskReservation in same transaction
         ↓ Redis Stream: risk.decisions (via outbox)
[5. OMS Accept]
   dedupe on idempotency_key → write order_intents → outbox
   → create child VenueOrder → transition to ROUTING
         ↓ Redis Stream: oms.intents (via outbox)
[6. Venue Submission]
   adapter.submit_order() → REST/WS to broker
   → transition child to SUBMITTED → receive broker_order_id
         ↓ Redis Stream: broker.events
[7. Fill Processing]
   dedupe by fill_id → update strategy_positions (qty, avg_entry, PnL)
   → update cash_ledger (settlement + fees) → update order states
         ↓ Redis Stream: fills.events (via outbox)
[8. Reconciliation]
   event-driven on fills + periodic poll (60s)
   → compare internal vs broker orders/positions
   → create ReconciliationIncident on mismatch → freeze OMS if critical
```

### 3.2 Warm Path — Research

```
[News Feed / Filings / Social / On-Chain]
   → LLM Interpreter (Claude API, budget-bounded, versioned prompts)
   → External Positioning (13F, COT, whale tracking)
   → Feature Store (TTL-cached, confidence-scored)
   → Signal Engine reads as weak, non-authoritative inputs
```

**Isolation rule**: if the entire warm path is down, the signal engine still generates signals from Julia's numerical models alone.

### 3.3 Cold Path — Offline

```
[Replay Harness] — deterministic replay from event log
[Advisory Tax Engine] — lot tracking, wash sale detection, FIFO
[Performance Reporting] — via dashboard API
```

### 3.4 Control Plane

```
[Risk Overlord] — global limit monitoring, auto kill-switch on breach
[Capital Allocator] — composite-score distribution across teams
[Kill Switch] — global + per-team, persisted to audit_log
[Conservative Mode] — reduced sizing (0.5x), leverage cap, strategy whitelist
[Factor Exposure Model] — cross-team concentration by factor
[Projection Alignment] — validates budget counters match actual positions
[Service Supervisor] — health-based restart, escalation
[NTP Check] — clock skew detection, trading block on critical drift
[Alert Manager] — webhook + log, rate-limited, severity-routed
```

---

## 4. Julia Numerical Core

### 4.1 Scale

| Metric | Value |
|---|---|
| Source files | ~140 |
| Lines of code | 18,000+ |
| Quantitative models | 38 |
| Features computed | 18 per instrument |
| Pipeline steps | 8 (with 2 hard gates) |
| Tests | 1,561 passing |
| Dependencies | 14 pure Julia packages |

### 4.2 Model Inventory

| Category | Models | IDs |
|---|---|---|
| Deep Learning | LSTM, GRU, Helformer, Conv-LSTM, BiLSTM, TFT, MLP | m01–m03, m08–m09, m11, m13 |
| Tree-Based ML | Random Forest, LightGBM, XGBoost | m05–m07 |
| Volatility | GARCH/EGARCH, Black-Scholes, FD Pricer | m14, m24–m25 |
| Sizing/Pricing | Kelly, EV Gap, LMSR | m16–m18 |
| Information Theory | KL Divergence, Bregman, Bayesian | m19–m21 |
| Statistical | Logistic, AR(1), Martingale, SGD | m10, m22–m23, m27 |
| Advanced ML | Meta-Labeling, FracDiff Signal, Triple Barrier | m28–m30 |
| Prediction Markets | Kalman Filter, Time Decay, Cross-Market Arb | m31–m33 |
| Technical | Momentum-Sentiment, MACD (10 configs) | m34–m35 |
| Structural Arb | Funding Arb, Pairs Trading, Mean Reversion | m36–m38 |
| Specialized | PolymarketQuant, PolymarketMM, Event Study, Calibration | polymarket_*, s01–s02 |

**Execution model**: Fast models (m04–m07, m10, m14–m17, m22–m33) run in-process. Heavy models (m01–m03, m08–m09, m11, m13) run in separate OS processes via Distributed.jl.

### 4.3 Feature Vector (18 features)

| # | Feature | Source |
|---|---|---|
| 1–5 | Return lags (5 bars) | Price history |
| 6 | Volatility (20-bar) | Price history |
| 7 | Volume change | Volume data |
| 8 | RSI (14) | Price history |
| 9 | Momentum (10) | Price history |
| 10–11 | Fractional differentiation | Lopez de Prado |
| 12 | Spread (High-Low) | OHLCV |
| 13 | Order imbalance | Order book |
| 14 | Trade velocity | Tick data |
| 15 | Depth imbalance | L2 book |
| 16 | Book pressure | L2 book |
| 17 | Spread (bps) | Quote data |
| 18 | CVD divergence | Cumulative volume delta |

### 4.4 Pipeline Steps

| Step | Name | Gate type |
|---|---|---|
| 2 | Event Study + Δp | Soft |
| 3 | Logistic + AR(1) regime detection | Soft |
| 4 | XGBoost refinement | Soft |
| 5 | **Calibration gate** | **Hard** — aborts if miscalibrated |
| 6 | Bayesian posterior update | Soft |
| 7 | **EV Gap filter** | **Hard** — aborts if insufficient edge |
| 8 | Kelly sizing | Soft |
| 9 | KL/Bregman divergence + arb detection | Soft |

### 4.5 Julia Bridge (ZMQ)

| Property | Value |
|---|---|
| Protocol | ZeroMQ REQ/REP (Lazy Pirate) |
| Endpoint | `tcp://127.0.0.1:5555` |
| Standard timeout | 3,000 ms |
| Heavy timeout | 15,000 ms |
| Max retries | 3 |
| Backoff | Exponential with jitter |
| Circuit breaker | Opens after 5 failures, 30s cooldown |

**Request types**: `heartbeat`, `features`, `model_score`, `ensemble`

**Degraded behavior**: if Julia bridge is down, no new signals are generated. Existing positions continue to be monitored and reconciled. Operators are alerted.

---

## 5. Python Orchestration Layer

### 5.1 Module Map (43 source modules)

```
TradingSwarm/
├── src/
│   ├── core/                          # Foundational types
│   │   ├── config.py                  # Environment config (dev/paper/live)
│   │   ├── event_schema.py            # All canonical types + state machines
│   │   ├── instrument_master.py       # Instrument registry + symbology
│   │   ├── julia_bridge.py            # ZMQ Lazy Pirate client + circuit breaker
│   │   ├── idempotency.py             # Dedup for trade-critical handlers
│   │   ├── trading_calendar.py        # US equity / crypto / FX sessions
│   │   └── instrument_seeds.py        # Crypto + stock instrument definitions
│   │
│   ├── pipeline/                      # Hot-path services
│   │   ├── runner.py                  # Main orchestrator + lifecycle
│   │   ├── data_ingest.py             # Service A — normalize + publish
│   │   ├── signal_engine.py           # Service B — Julia features + ensemble
│   │   ├── risk_gate.py               # Service C — inline risk + atomic reservation
│   │   ├── oms.py                     # Service D — parent/child order model
│   │   ├── signal_router.py           # Signal → Risk → OMS → Execution wiring
│   │   ├── fill_processor.py          # Fill → position + cash + order state
│   │   └── smart_router.py            # Multi-venue selection + order slicing
│   │
│   ├── execution/                     # Venue adapters (state synchronizers)
│   │   ├── base_adapter.py            # Abstract adapter interface
│   │   ├── paper_adapter.py           # Simulated execution (dev/paper)
│   │   ├── binance_adapter.py         # REST + WS, spot + futures
│   │   ├── alpaca_adapter.py          # US equities REST v2
│   │   ├── polymarket_adapter.py      # CLOB + EIP-712 signing + geoblock
│   │   ├── oanda_adapter.py           # FX v20, incremental by txn ID
│   │   └── reconciler.py              # Broker truth vs internal state
│   │
│   ├── control/                       # Risk + safety
│   │   ├── kill_switch.py             # Kill switch + conservative mode
│   │   ├── risk_overlord.py           # Global risk aggregation + monitoring
│   │   ├── capital_allocator.py       # Composite-score capital distribution
│   │   ├── factor_exposure.py         # Cross-team factor concentration
│   │   └── projection_alignment.py    # Budget counter consistency
│   │
│   ├── ledger/                        # Persistence
│   │   ├── postgres.py                # Async connection pool + migration runner
│   │   ├── redis_streams.py           # Producer, consumer groups, DLQ, AOF
│   │   ├── outbox.py                  # DB-first + outbox pattern
│   │   └── migrations/
│   │       ├── 001_foundation.sql     # 15 core tables
│   │       └── 002_timescale.sql      # TimescaleDB hypertables
│   │
│   ├── monitoring/                    # Observability
│   │   ├── health.py                  # HTTP health server + Prometheus metrics
│   │   ├── alerting.py                # Webhook + log, severity-routed
│   │   ├── execution_metrics.py       # Slippage, latency, fill rate tracking
│   │   ├── supervisor.py              # Health-based service restart
│   │   └── ntp_check.py              # Clock skew detection
│   │
│   ├── research/                      # Warm path (non-authoritative)
│   │   ├── feature_store.py           # TTL-cached research features
│   │   ├── llm_interpreter.py         # Claude API extraction (versioned prompts)
│   │   ├── external_positioning.py    # 13F, COT, whale tracking
│   │   └── feeds/news_feed.py         # Multi-source news ingestor
│   │
│   ├── tax/tax_engine.py             # Advisory: lots, wash sale, FIFO
│   ├── security/secrets.py           # Multi-backend secret store
│   ├── dashboard/server.py           # JSON API for pipeline state
│   └── learning/replay_harness.py    # Deterministic event replay
│
├── tests/                             # 206 tests
│   ├── unit/        (17 files)        # Types, state machines, adapters, risk
│   └── chaos/       (1 file)          # Mandatory chaos scenarios
│
└── deploy/
    ├── docker-compose.yml             # Dev: TimescaleDB + Redis (AOF)
    ├── docker-compose.prod.yml        # Prod: WAL archiving, bind 127.0.0.1
    └── systemd/
        ├── quantengine.service        # Python pipeline
        └── quantengine-julia.service  # Julia ZMQ bridge
```

---

## 6. Data Model

### 6.1 Postgres — Transactional Truth (15 tables)

| Table | Role | Key fields |
|---|---|---|
| `instrument_master` | Canonical instruments | instrument_id (UUID PK), asset_class, base_symbol, tick_size, lot_size |
| `symbol_mapping` | Venue ↔ canonical resolution | (instrument_id, venue) PK, venue_symbol |
| `order_intents` | Parent orders | order_intent_id, idempotency_key (UNIQUE), team_id, strategy_id, current_state |
| `risk_reservations` | Atomic budget claims | reservation_id, scope, reserved_notional, status, expires_at |
| `risk_decisions` | Audit of approval/rejection | decision_id, decision, reason, risk_snapshot (JSONB) |
| `venue_orders` | Child orders at broker | venue_order_id_internal, broker_order_id, current_state, filled_qty |
| `order_events` | Immutable state transition log | event_id, event_type, event_time_utc, payload (JSONB) |
| `fills` | Execution records | fill_id, side, quantity, price, fee, slippage_bps |
| `strategy_positions` | Position state at strategy level | (team_id, strategy_id, instrument_id) PK, quantity, avg_entry_price, realized_pnl |
| `cash_ledger` | Cash flows | entry_type (settlement/fee/funding/dividend), amount, reference_id |
| `reconciliation_incidents` | Broker vs internal mismatches | incident_type, severity, expected_state, actual_state, status |
| `risk_budgets` | Scarce resource tracking | scope PK, max_gross_exposure, current_gross_exposure, current_daily_loss |
| `outbox` | DB-first + outbox pattern | stream_name, envelope_data, published (bool) |
| `idempotency_keys` | Handler dedup | idempotency_key PK, result_data, expires_at |
| `audit_log` | All operator/system actions | actor, action, entity_type, details (JSONB) |
| `config_versions` | Config change tracking | config_hash PK, config_data (JSONB) |
| `service_incidents` | Service health events | service_name, incident_type, severity |

### 6.2 TimescaleDB — Time-Series Data (3 hypertables)

| Table | Chunk interval | Compression | Retention |
|---|---|---|---|
| `market_data` (OHLCV bars) | Auto | After 30 days | 2 years |
| `normalized_trades` (tick) | Auto | After 7 days | 90 days |
| `normalized_quotes` | Auto | After 7 days | 90 days |

### 6.3 Redis Streams — Hot-Path Event Bus

| Stream | Purpose | Delivery |
|---|---|---|
| `market.normalized` | Normalized market data events | At-least-once |
| `signal.generated` | Signal engine output | At-least-once |
| `risk.decisions` | Risk approval/rejection audit | At-least-once |
| `risk.reservations` | Reservation lifecycle | At-least-once |
| `oms.intents` | Order intent accepted | At-least-once |
| `oms.events` | OMS state transitions | At-least-once |
| `broker.events` | Broker callbacks normalized | At-least-once |
| `fills.events` | Fill records for downstream | At-least-once |
| `reconciliation.incidents` | Mismatch detection | At-least-once |
| `alerts.critical` | Critical system alerts | At-least-once |

**Consumer group rules**:
- All trade-critical consumers use consumer groups
- XACK only after durable processing complete
- XAUTOCLAIM reclaims idle messages (default 30s threshold)
- Max 5 retries, then dead letter queue (`.dlq` suffix)

**Redis persistence**: AOF enabled, `appendfsync everysec`. AOF verified at startup; refused in paper/live if disabled.

---

## 7. Order Management System

### 7.1 Parent Intent State Machine

```
INTENT_CREATED
  → RISK_PENDING
    → RISK_APPROVED / REJECTED
      → RESERVING_BUDGET
        → ACCEPTED_BY_OMS / REJECTED
          → ROUTING
            → WORKING / REJECTED / CANCELED
              → PARTIALLY_FILLED / FILLED / CANCELED / SUSPENDED
                → FILLED / CANCELED (terminal)
```

Terminal states: `FILLED`, `CANCELED`, `REJECTED`, `EXPIRED`

**Invariants enforced by code**:
- No path from INTENT_CREATED to ACCEPTED_BY_OMS without passing through RISK_PENDING → RISK_APPROVED → RESERVING_BUDGET
- No backward transitions (state machine is a DAG)
- FILLED is terminal — no further transitions

### 7.2 Child Venue Order State Machine

```
CHILD_CREATED → SUBMITTED → ACKNOWLEDGED → PARTIALLY_FILLED → FILLED
                          → REJECTED
                          → UNKNOWN_BUT_OPEN (outage/gap)
                → CANCEL_REQUESTED → CANCELED / FILLED (race)
```

`UNKNOWN_BUT_OPEN` is critical during broker outages. Can resolve to any state.

### 7.3 Restart Behavior

1. Load unfinished intents + venue orders from Postgres
2. Query broker for open orders, positions, balances
3. Match internal vs external state
4. Write reconciliation incidents for mismatches
5. **OMS stays FROZEN** until mismatch set is resolved or acknowledged

---

## 8. Risk Architecture

### 8.1 Pre-Trade Risk (Synchronous, Inline)

The signal path **blocks** on the risk decision. No async "maybe later" approval.

**Atomic reservation flow** (single Postgres transaction):
1. `SELECT * FROM risk_budgets WHERE scope = 'global' FOR UPDATE` (row lock)
2. Check hard limits (gross cap, daily loss, drawdown, position count, single-position cap)
3. If approved: create `RiskReservation` + debit budget counters
4. If rejected: write `RiskDecision` audit row
5. Persist reservation + decision + outbox row in same transaction
6. Release lock on commit

**Hard non-overridable controls**:
- Global daily loss (5% default)
- Global drawdown (15% default)
- Global gross exposure cap ($1M default)
- Per-team daily loss (3% default)
- Single position cap (10% of gross cap)
- Position count cap (50)
- Post-restart freeze

### 8.2 Reservation Lifecycle

```
ACTIVE → CONSUMED (OMS turns it into a working order)
       → RELEASED (reject/cancel/timeout)
       → EXPIRED (60s TTL not consumed)
```

Reservations are uniquely keyed and cannot be consumed twice. Background worker expires stale reservations every 10s.

### 8.3 Factor Exposure (Cross-Team)

8 canonical factors: `crypto_beta`, `usd_exposure`, `growth_beta`, `value_beta`, `rates_sensitivity`, `event_overlap`, `vol_sensitivity`, `momentum`

Each instrument has a factor loading vector. Portfolio exposure = Σ(|qty| × price × loading) per factor. Per-factor concentration limits enforced.

### 8.4 Risk Overlord

Continuous monitoring loop (5s interval):
- Check global limits across all teams
- Check per-team limits
- Auto-trigger kill switch on breach
- Track high-water mark for drawdown calculation

### 8.5 Kill Switch + Conservative Mode

| Control | Effect | Deactivation |
|---|---|---|
| Kill Switch (global) | All trading halted, OMS frozen | Explicit operator action |
| Kill Switch (team) | Team trading halted | Explicit operator action |
| Conservative Mode | 0.5x sizing, no leverage, strategy whitelist | Explicit operator action |

Both persist to `audit_log` in Postgres.

---

## 9. Venue Adapters

All adapters implement the `BaseAdapter` protocol — they are **state synchronizers**, not thin wrappers.

| Adapter | Venue | Asset classes | Key features |
|---|---|---|---|
| **PaperAdapter** | paper | All | Simulated fills with configurable slippage (5 bps), latency (50ms), position/balance tracking |
| **BinanceAdapter** | binance | Crypto spot + futures | REST + WS, HMAC-SHA256 signing, reconnect logic, funding awareness |
| **AlpacaAdapter** | alpaca | US equities | REST v2, IEX/SIP data awareness, market clock queries, commission-free |
| **PolymarketAdapter** | polymarket | Prediction markets | EIP-712 signing, geoblock enforcement (US/CU/IR/KP/SY/BY), CLOB limit-only, USDC settlement |
| **OandaAdapter** | oanda | FX | v20 REST, transaction-based incremental sync, financing awareness, streaming prices |

### Reconciliation interface (all adapters):
- `get_open_orders()` — broker's view of working orders
- `get_positions()` — broker's view of positions
- `get_balances()` — broker's cash/margin state
- `normalize_order_event()` / `normalize_fill()` — raw → canonical schema

---

## 10. Instrument Master + Symbology

Every tradable instrument gets a canonical `instrument_id` (UUID). The `symbol_mapping` table resolves venue-specific symbols bidirectionally.

### Seeded instruments:

**Crypto (5)**: BTC/USDT, ETH/USDT, SOL/USDT, BNB/USDT, XRP/USDT — mapped to Binance + paper

**Stocks (10)**: AAPL, MSFT, GOOGL, AMZN, NVDA, TSLA, META, JPM, SPY, QQQ — mapped to Alpaca + paper

Each instrument carries:
- Asset class, instrument type, tick/lot sizes
- Trading calendar (24x7 for crypto, us_equity for stocks, fx for FX)
- Factor loadings for cross-team risk
- Currency exposure

---

## 11. Trading Calendars

| Calendar | Hours | Holidays |
|---|---|---|
| `24x7` | Always open | None |
| `us_equity` | 9:30–16:00 ET regular, 4:00–9:30 pre, 16:00–20:00 post | US market holidays (2026) |
| `fx` | Sunday 17:00 ET – Friday 17:00 ET | Sat closed, Sun before 17:00 ET closed |

Session detection is used by the pipeline to gate order submission.

---

## 12. Monitoring + Observability

### 12.1 Health Server (port 8090)

| Endpoint | Returns |
|---|---|
| `/health` | Postgres, Redis, Redis AOF, Julia bridge, stream backlog |
| `/metrics` | Prometheus text format |
| `/ready` | Readiness (health + no critical incidents) |

### 12.2 Prometheus Metrics

**Counters**: orders_submitted, fills_processed, risk_decisions, recon_incidents, stream_messages, outbox_published

**Gauges**: active_orders, open_positions, pending_messages, gross_exposure, daily_pnl, julia_circuit, unresolved_incidents

**Histograms**: order_latency, julia_latency, risk_eval_latency

### 12.3 Execution Quality Metrics

Per-venue rolling window (500 fills):
- Slippage: mean, median, p95, max (in bps)
- Latency: mean, median, p95, max (in ms)
- Fill rate: fills / attempts
- Rejection rate: rejections / attempts
- Quality gate: `is_quality_acceptable(venue, max_slippage_bps)` — disables venue if degraded

### 12.4 Alerting

| Severity | Channels | Example triggers |
|---|---|---|
| INFO | Log only | Successful reconciliation |
| WARNING | Log + rate-limited | Feed stale, unusual slippage |
| CRITICAL | Log + webhook | Broker disconnect, unresolved recon, DLQ growth |
| EMERGENCY | Log + webhook (no rate limit) | Kill switch activation |

### 12.5 Service Supervisor

Monitors registered services with health checks. Auto-restarts on failure (max 3 attempts). Escalates to alert on persistent failure.

### 12.6 NTP Check

Queries `time.apple.com`, `time.google.com`, `pool.ntp.org`. Thresholds: <100ms healthy, 100ms–1s warning, >1s critical (blocks trading).

---

## 13. Research Plane

### 13.1 LLM Interpreter

- **Model**: Claude Sonnet 4 (2025-05-14) via API
- **Versioned prompts**: `sentiment_v1`, `regime_v1`, `event_extraction_v1`
- **Budget**: $50/day max, tracked per-call
- **Timeout**: 30s per call
- **Cache**: by input hash + prompt version
- **Rule**: LLMs may extract/classify/summarize. **Never** trade, override risk, or mutate strategies.

### 13.2 External Positioning

| Source | API | Confidence cap |
|---|---|---|
| 13F filings | SEC EDGAR | 0.10 |
| COT reports | CFTC | 0.15 |
| Whale tracking | On-chain (stub) | 0.20 |

All positioning signals are capped at **0.3 confidence maximum** — these are weak signals by design.

### 13.3 Feature Store

- In-memory cache backed by Postgres
- TTL-based staleness (default 1 hour)
- `get_vector(instrument_id, feature_names)` returns None for missing/stale
- `evict_stale()` background cleanup
- Signal engine reads features but **continues without them**

---

## 14. Advisory Tax Engine

- **FIFO** specific identification for lot closing
- **Holding period**: short-term (<365 days) vs long-term
- **Wash sale detection**: 30-day window before/after sale
- **Asset-class aware**: crypto, equity, ETF
- **Every output carries disclaimer**: "All tax calculations must be reviewed by a qualified tax professional"
- **Does NOT block hot-path** order submission

---

## 15. Deployment

### 15.1 Development

```bash
cd TradingSwarm
docker compose -f deploy/docker-compose.yml up -d    # TimescaleDB + Redis
source .venv/bin/activate
python -m src.pipeline.runner --team crypto --venue paper
```

Julia bridge (separate terminal):
```bash
cd Julia_research/QuantEngine
julia julia_bridge/zmq_server.jl
```

### 15.2 Production

```bash
docker compose -f deploy/docker-compose.prod.yml up -d
systemctl enable quantengine-julia quantengine
systemctl start quantengine-julia quantengine
```

**Production hardening**:
- Postgres: WAL archiving, 256MB shared_buffers, log slow queries >100ms
- Redis: AOF + RDB, `maxmemory-policy noeviction`, requirepass, bind 127.0.0.1
- Services: NoNewPrivileges, ProtectSystem=strict, MemoryMax=4G (Python) / 8G (Julia)
- Credentials: separate paper/live, trading-only API scopes, withdrawals disabled

---

## 16. Testing

### 16.1 Test Suite (236 tests, 0.93s)

These tests verify **code correctness** — type safety, state machine invariants, adapter behavior, risk gate logic. They do NOT prove the system can make money or survive real venue behavior. That requires shadow sessions and measured paper trading, which have not started.

| Category | Tests | What's covered |
|---|---|---|
| Config | 6 | Environment parsing, DSN construction, from_env |
| Event Schema | 11 | All canonical types, serialization, envelope |
| Instrument Master | 8 | Register, resolve, multi-venue, unknown symbol |
| OMS State Machine | 17 | All transitions, terminal states, no backward, no skip risk |
| Paper Adapter | 11 | Buy/sell/limit/cancel/slippage/balance/status |
| Signal Router | 4 | Kill switch, freeze, conservative mode |
| Julia Bridge | 8 | Circuit breaker lifecycle (open/close/half-open) |
| Risk Controls | 16 | Kill switch, conservative mode, reservation invariants, risk gate invariants |
| Fill Processor | 10 | Position math (long/short/partial/PnL/cash) |
| Factor Exposure | 9 | Loadings, defaults, limits, all factors |
| Trading Calendar | 15 | US equity sessions, holidays, FX sessions, crypto 24x7 |
| Concurrency | 13 | Reservation uniqueness, no double-consume, idempotency, budget atomicity |
| Polymarket | 13 | Geoblock (US/IR/KP), signing, determinism, limit-only |
| Research Isolation | 15 | Feature store stale/missing, LLM budget, news feed, positioning cap |
| Tax Engine | 15 | Lots, FIFO, wash sale, holding period, disclaimer |
| Execution Metrics | 8 | Slippage stats, latency, fill rate, quality gate |
| Smart Router | 7 | Venue selection, disconnected handling, order slicing |
| Chaos Scenarios | 16 | Feed gap, duplicate messages, out-of-order events, broker outage, OMS restart, orphaned orders |
| Scope Enforcement | 2 | Only crypto/binance allowed; instruments locked to BTC+ETH |
| Validation Pack | 16 | Threshold evaluation, registry completeness, critical thresholds present |
| Shadow Mode | 11 | Signal recording, outcome tracking, buy/sell move calculation, session stats |

### 16.2 Chaos Scenarios (Section 19.2 compliance)

| Scenario | Test approach |
|---|---|
| Feed gap | Stale detection with configurable threshold |
| Duplicate stream message | Idempotency keys on all entities |
| Out-of-order broker event | `UNKNOWN_BUT_OPEN` state + resolution paths |
| Broker outage | Adapter connection states + circuit breaker |
| OMS restart mid-fill | Frozen until reconciliation; unfinished states queryable |
| Orphaned order | Reconciler detects internal orders missing at broker |
| Partial fill mismatch | State machine allows continued partial fills |

---

## 17. Market Teams

| Team | Venue(s) | Calendar | Instruments | Strategies |
|---|---|---|---|---|
| Crypto | Binance (+ paper) | 24x7 | BTC, ETH, SOL, BNB, XRP | Mean reversion, trend, stat-arb, funding-aware |
| Stocks | Alpaca (+ paper) | us_equity | AAPL, MSFT, GOOGL, AMZN, NVDA, TSLA, META, JPM, SPY, QQQ | Daily/intraday liquid equity, event-driven |
| Polymarket | Polymarket | 24x7 | Prediction markets | Calibration, mispricing, cross-market |
| FX | OANDA | fx | FX pairs | Carry, momentum, mean reversion, macro-event |

---

## 18. Validation Pack — Concrete Thresholds

The system defines 28 measurable thresholds across 4 validation levels. No threshold = no claim. These are enforced in code (`validation_pack.py`), not just written in a document.

### PLUMBING level (infrastructure works)

| Threshold | Comparator | Value | Status |
|---|---|---|---|
| Postgres connected | eq | 1 (bool) | Unmeasured |
| Redis connected + AOF verified | eq | 1 (bool) | Unmeasured |
| Julia bridge heartbeat | eq | 1 (bool) | Unmeasured |
| Migrations applied | eq | 1 (bool) | Unmeasured |
| Instruments loaded | ≥ | 2 | Unmeasured |
| Primary adapter connected | eq | 1 (bool) | Unmeasured |

### SHADOW level (signals have directional accuracy)

| Threshold | Comparator | Value | Status |
|---|---|---|---|
| Shadow signals generated (7d) | ≥ | 50 | Unmeasured |
| 5-min directional hit rate | ≥ | 52% | Unmeasured |
| Mean favorable 5-min move | > | 0 bps | Unmeasured |
| Signal direction diversity | ≥ | 20% minority direction | Unmeasured |

### PAPER level (full pipeline produces clean results)

| Threshold | Comparator | Value | Status |
|---|---|---|---|
| Paper fills (14d) | ≥ | 100 | Unmeasured |
| Post-cost expectancy per fill | > | $0 | Unmeasured |
| Slippage p95 | ≤ | 15 bps | Unmeasured |
| Reject rate | ≤ | 2% | Unmeasured |
| Recon clean days (consecutive) | ≥ | 7 | Unmeasured |
| Restart recovery time | ≤ | 30 seconds | Unmeasured |
| Uninterrupted session | ≥ | 72 hours | Unmeasured |

### PRE_LIVE level (ready for supervised capital)

| Threshold | Comparator | Value | Status |
|---|---|---|---|
| Paper/shadow signal divergence | ≤ | 5% | Unmeasured |
| Slippage drift (shadow → paper) | ≤ | 10 bps | Unmeasured |
| Trade count (30d) | ≥ | 500 | Unmeasured |
| Feed uptime (30d) | ≥ | 99.5% | Unmeasured |
| Execution quality stable | ≤ | 2x (p95/median ratio) | Unmeasured |
| Recon incidents per day (30d) | = | 0 | Unmeasured |
| Kill switch drill passes | eq | 1 (bool) | Unmeasured |
| Postgres restore drill passes | eq | 1 (bool) | Unmeasured |
| Redis recovery drill passes | eq | 1 (bool) | Unmeasured |
| Runbooks reviewed and signed | eq | 1 (bool) | Unmeasured |
| On-call owner designated | eq | 1 (bool) | Unmeasured |

**Run validation**: `python -m src.pipeline.runner validate --level plumbing`

---

## 19. Known Limitations and Technical Debt

### Single points of failure (intentional for correctness, not scale)

- **Julia bridge**: single localhost ZMQ endpoint. If it goes down, no new signals. This is a deliberate single-host correctness choice. It is not scalable multi-host infrastructure, and the spec does not claim otherwise.
- **Global risk lock**: `SELECT ... FOR UPDATE` on the `risk_budgets` row. Correct for preventing oversubscription. Will become a throughput bottleneck if signal frequency exceeds ~100/second. Acceptable for current low-frequency strategy targets.
- **Single-host deployment**: systemd on one Linux host. Not a resilient distributed plant. Fine for early validation; must be acknowledged as a prototype topology.

### Paper adapter is scaffolding, not validation

The paper adapter uses 5 bps slippage and 50 ms latency. This tells you nothing about:
- Binance partial fill queuing and order book dynamics
- Alpaca wash-trade protection behavior
- OANDA financing edge cases and spread widening
- Polymarket CLOB queue position

Use the paper adapter for plumbing tests only. For strategy validation, use shadow mode against real market data.

### Reconciliation uses periodic polling (correctly)

The system uses **both** event-driven reconciliation on broker callbacks **and** a 60-second periodic poll. The poll exists because venue WebSocket callbacks can gap, drop, or lag. Polling is correct engineering for a safety-critical reconciliation path. It is not a design flaw.

### 38 models are a liability until proven

The Julia core has 38 quantitative models. This is complexity debt unless the ensemble demonstrably beats a 3-model baseline after costs and execution effects. The adaptive selector is designed to prune underperformers, but this has not been measured against real outcomes. Until it is, 38 models is a maintenance surface, not a strength.

### Scope is deliberately collapsed

The system supports 4 venues and 4 market teams in code. Only crypto/Binance/BTC+ETH is active. This is enforced in `runner.py` via `ALLOWED_SCOPES`. Expanding scope before the narrow lane is validated is explicitly blocked.

---

## 20. Operating Modes

### Shadow mode (recommended next step)

```bash
python -m src.pipeline.runner shadow --team crypto --venue binance
```

Connects to real Binance data. Runs the full Julia signal pipeline. Records signals with timestamps and prices. After 1m/5m/15m/1h, records what the market actually did. Produces hit rate, directional accuracy, mean favorable move. No orders submitted. No capital at risk.

### Paper mode

```bash
python -m src.pipeline.runner run --team crypto --venue paper
```

Full pipeline with simulated fills. Good for plumbing validation. Not valid for strategy validation.

### Validation check

```bash
python -m src.pipeline.runner validate --level shadow
```

Measures all thresholds at the specified level. Prints pass/fail report.

---

## 21. Operating Mantra

**No durable intent, no order.**
**No clean reconciliation, no trading.**
**No atomic reservation, no approval.**
**No key hygiene, no live deployment.**
**No measured edge, no live capital.**

---

*QuantEngine v11.1 — System Specification*
*Generated 2026-03-17*
*Updated with honest assessment, scope collapse, validation pack, shadow mode, known limitations*
