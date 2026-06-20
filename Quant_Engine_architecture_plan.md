# QuantEngine v9.0 — Multi-Market Trading System

## Context

QuantEngine v8.0 is a monolithic Julia engine (127 files, 16K+ LOC, 34 models, 1,561 tests). It needs decomposition into independent market-specific systems with proper operational infrastructure. This plan redesigns it as a deterministic trading pipeline — not an agent swarm.

**Core principle:** Decompose by *operational plane*, not by agent type.

**Hardware:** Apple M4 Max Pro, 40 GPU cores, macOS (dev/paper). Linux server for live production.

---

## The Live Trading Pipeline (Hot Path)

This is the entire trade-critical data flow. Everything else is secondary.

```
[1. Broker/Exchange/Data Adapters]
         ↓ normalized events
[2. Instrument Normalizer + Symbol Mapper]
         ↓ canonical instrument_ids
[3. Durable Event Log (Redis Streams, XREADGROUP + XACK)]
         ↓ at-least-once delivery
[4. Feature / Signal Engine (Julia via ZMQ Lazy Pirate RPC)]
         ↓ deterministic signals
[5. Pre-Trade Risk Gate (SYNCHRONOUS, inline, blocks until approved)]
         ↓ risk-approved order intents
[6. Order Management System (OMS) + Order State Machine]
         ↓ idempotent order submission
[7. Broker/Exchange Adapters (authoritative state synchronizers)]
         ↓ fill/cancel/reject events
[8. Fill Processing → Durable Event Log]
         ↓
[9. Ledger + Position State Projections]
         ↓
[10. Reconciler (internal state vs broker truth, periodic + on-restart)]
         ↓ incidents logged
[11. Dashboards / Alerts / Analytics]
```

**There are no "agents" on this path.** Every step is a deterministic service. No LLMs. No polling for state. No negotiation between components. Data flows forward through the pipeline. Risk decisions are synchronous. Orders are idempotent. Broker state is reconciled.

---

## The Research Pipeline (Warm Path, Fully Separated)

```
[News / Filings / Social / On-Chain / Public Positioning / Alt Data]
         ↓
[Extraction + LLM Labeling + Caching]
         ↓ versioned, bounded, ignorable features
[Research Feature Store (PostgreSQL)]
         ↓ read by Signal Engine as NON-AUTHORITATIVE weak inputs
[Signal Engine]
```

Research outputs are:
- Versioned by prompt/model/template
- Bounded by timeout and API budget
- Confidence-scored
- Cached (not computed per-tick)
- **Ignorable without breaking the system** — if the research pipeline is down, the signal engine still works

---

## The Offline Pipeline (Cold Path)

```
[Model Retraining (scheduled, never live self-modification)]
[Strategy Mutation (shadow → challenger → offline validation → gated promotion)]
[Cross-Team Learning Transfer (feature templates + meta-labels ONLY, never raw weights)]
[Backtesting + Deterministic Replay from Event Logs]
[Performance Reporting + Post-Mortem Analysis (Claude-assisted)]
[Tax Reporting (advisory, not blocking)]
```

---

## The Control Plane (Slow Path)

```
[Capital Allocation — daily/weekly, composite score with penalties, never trailing Sharpe alone]
[Cross-Team Risk Aggregation — event-driven on fills, not polling]
[Kill Switch — event-driven, immediate]
[Config Management + Feature Flags]
[Human Override / Conservative Mode]
[Monitoring + Alerting]
```

---

## Per-Team Runtime Architecture

Each market team (Crypto, Stock, Polymarket, Forex) runs the hot path as **4 deterministic services**:

### Service A: Data Ingest + Normalization
- Broker/exchange feed adapters (WebSocket + REST polling)
- Normalizes through instrument master (canonical instrument_ids)
- Publishes to **Redis Streams** (durable, at-least-once, consumer groups, XACK)
- Health/gap/stale-data detection
- Cross-source price validation
- If feed stale > N seconds: blocks downstream trading, raises incident

### Service B: Signal Engine
- Consumes normalized data from Redis Streams
- Calls Julia for feature computation and model scoring via **ZMQ Lazy Pirate RPC**:
  - Configurable timeout (5s standard, 30s heavy models)
  - Automatic retry with exponential backoff
  - Heartbeat detection for dead Julia processes
  - Circuit-breaking: if Julia is down, signal engine enters degraded mode (no new trades, existing positions monitored)
- Deterministic signal generation from 34-model ensemble (team-specific subsets via existing `select_models()`)
- Shadow/challenger model outputs logged but never traded
- External positioning features (see section below) consumed as weak, non-authoritative inputs
- Publishes signal events to Redis Streams

### Service C: Pre-Trade Risk + Portfolio Sizing
- **Synchronous and inline** — the signal engine calls this directly, blocking until approved or rejected
- NOT a separate process that polls — it is a function call in the order admission path
- Checks:
  - Position limits (team and global)
  - Gross/net exposure limits
  - Leverage and margin headroom (venue-specific)
  - Liquidity-adjusted sizing (size as % ADV or % book depth)
  - Venue/issuer/factor/currency concentration
  - Stale-data gates (reject if data feed unhealthy)
  - Broker connectivity gates (reject if broker connection down)
  - Execution-quality gates (reject if realized slippage > 2x model for recent N fills)
  - Trade-frequency throttles
  - Post-restart freeze (reject until reconciliation is clean)
  - Daily loss and drawdown circuit breakers
  - Factor-aware correlation (not just pairwise returns)
- Kelly sizing with regime-aware scaling
- Capital budget enforcement from control plane
- Every decision written to `risk_decisions` table with full context
- Outputs: risk-approved order intent with idempotency key, or rejection with reason

### Service D: Execution Gateway + OMS
This is the most critical service. It is the **authoritative order manager**, not a thin broker wrapper.

**Order State Machine:**
```
intent_created
  → risk_approved
    → submitted_to_venue
      → acknowledged (broker assigns order ID)
        → partially_filled (qty updated per fill event)
          → filled (terminal)
        → canceled (terminal)
        → rejected (terminal)
        → expired (terminal)
```

Every state transition is:
- Written to `order_events` table (durable)
- Published to Redis Streams (for downstream consumers)
- Idempotent (retries produce the same result)

**Core capabilities:**
- Idempotency keys on every order intent (dedupe on retries)
- Internal order ID ↔ broker/exchange order ID mapping
- Smart order routing (TWAP/VWAP for large orders)
- Partial fill tracking (filled_qty, remaining_qty, average_fill_price)
- Adverse selection detection (price moved against during fill → cancel remaining)
- Orphaned order detection (orders in submitted/acknowledged with no update for N minutes)
- Cancel-all and flatten logic (emergency shutdown)
- Fill logging with expected vs actual price for slippage model

**On process restart:**
1. Re-query all open orders from broker
2. Re-query all positions from broker
3. Compare vs internal ledger state
4. Log any discrepancies as reconciliation incidents
5. **Do NOT resume trading until reconciliation is clean**

**Broker adapter requirements (not thin wrappers):**

| Broker | Specific Requirements |
|--------|----------------------|
| **Binance** | REST + WS, reconnect logic, rate limiting |
| **Alpaca** | REST v2, wash-trade protection (even in paper mode), IEX vs SIP data tier awareness |
| **Polymarket** | EIP-712 signed orders, onchain Polygon settlement, wallet/key management, geographic restrictions, non-custodial |
| **OANDA** | Snapshot + incremental account maintenance via last transaction ID, session/financing handling |
| **IBKR** (Phase 5) | Callback-driven (openOrder/orderStatus), broken socket ≠ connectionClosed (must handle), reqAllOpenOrders for recovery |

---

## Instrument Master + Symbology (Phase 0 — Build First)

Without this, cross-team correlation is garbage, tax logic is wrong, sizing drifts, portfolio aggregation lies, backtests don't match live.

```sql
CREATE TABLE instrument_master (
    instrument_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    asset_class     TEXT NOT NULL,           -- equity, crypto, fx, prediction
    instrument_type TEXT NOT NULL,           -- spot, perpetual, future, option, binary
    base_symbol     TEXT NOT NULL,           -- BTC, AAPL, EUR
    quote_symbol    TEXT NOT NULL,           -- USD, USDT, JPY
    multiplier      DECIMAL DEFAULT 1.0,
    tick_size       DECIMAL,
    lot_size        DECIMAL,
    min_order_size  DECIMAL,
    max_order_size  DECIMAL,
    expiry_date     TIMESTAMPTZ,            -- NULL for perpetuals/spot
    strike          DECIMAL,                -- options only
    option_type     TEXT,                   -- call, put (options only)
    settlement_type TEXT,                   -- cash, physical, onchain
    trading_calendar TEXT,                  -- us_equity, crypto_247, fx_weekday
    margin_required DECIMAL,
    is_active       BOOLEAN DEFAULT true,
    metadata        JSONB,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE symbol_mapping (
    instrument_id   UUID REFERENCES instrument_master,
    venue           TEXT NOT NULL,           -- binance, alpaca, polymarket, oanda
    venue_symbol    TEXT NOT NULL,           -- BTCUSDT, AAPL, 0x..., EUR_USD
    venue_metadata  JSONB,                  -- venue-specific fields
    PRIMARY KEY (instrument_id, venue)
);

-- Factor exposure for cross-team correlation (not just pairwise returns)
CREATE TABLE factor_exposures (
    instrument_id   UUID REFERENCES instrument_master,
    factor_name     TEXT NOT NULL,           -- crypto_beta, growth_beta, usd_exposure, ...
    exposure        DECIMAL NOT NULL,
    as_of_date      DATE NOT NULL,
    PRIMARY KEY (instrument_id, factor_name, as_of_date)
);

-- Trading sessions and calendars
CREATE TABLE trading_sessions (
    calendar_name   TEXT NOT NULL,
    session_date    DATE NOT NULL,
    market_open     TIME,
    market_close    TIME,
    is_holiday      BOOLEAN DEFAULT false,
    PRIMARY KEY (calendar_name, session_date)
);

-- Corporate actions (equity-specific)
CREATE TABLE corporate_actions (
    action_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instrument_id   UUID REFERENCES instrument_master,
    action_type     TEXT NOT NULL,           -- split, reverse_split, dividend, merger
    ex_date         DATE NOT NULL,
    ratio           DECIMAL,                -- 2.0 for 2:1 split
    amount          DECIMAL,                -- dividend amount
    metadata        JSONB
);
```

---

## Authoritative Ledger (Phase 0 — Build First)

The system cannot audit decisions, reproduce trades, explain PnL, compute taxes, reconcile with brokers, or compare live vs backtest without this.

### Orders + Execution

```sql
CREATE TABLE orders (
    order_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    idempotency_key     TEXT UNIQUE NOT NULL,
    team_id             TEXT NOT NULL,
    strategy_id         TEXT NOT NULL,
    instrument_id       UUID NOT NULL REFERENCES instrument_master,
    venue               TEXT NOT NULL,
    side                TEXT NOT NULL CHECK (side IN ('buy', 'sell')),
    order_type          TEXT NOT NULL CHECK (order_type IN ('market', 'limit', 'stop', 'stop_limit')),
    requested_qty       DECIMAL NOT NULL,
    limit_price         DECIMAL,
    stop_price          DECIMAL,
    time_in_force       TEXT DEFAULT 'GTC',
    -- Tracing
    signal_id           UUID,
    correlation_id      UUID NOT NULL,
    model_version       TEXT NOT NULL,
    feature_version     TEXT NOT NULL,
    config_hash         TEXT NOT NULL,
    -- State
    current_state       TEXT NOT NULL DEFAULT 'intent_created',
    filled_qty          DECIMAL DEFAULT 0,
    remaining_qty       DECIMAL,
    avg_fill_price      DECIMAL,
    -- Timestamps
    created_at          TIMESTAMPTZ DEFAULT NOW(),
    submitted_at        TIMESTAMPTZ,
    last_updated_at     TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE order_events (
    event_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id            UUID NOT NULL REFERENCES orders,
    event_type          TEXT NOT NULL,
    -- Valid types: risk_approved, risk_rejected, submitted,
    --   acknowledged, partially_filled, filled, canceled,
    --   rejected, expired, cancel_requested, cancel_confirmed
    broker_order_id     TEXT,
    filled_qty          DECIMAL,
    fill_price          DECIMAL,
    remaining_qty       DECIMAL,
    reject_reason       TEXT,
    event_time_utc      TIMESTAMPTZ NOT NULL,
    ingest_time_utc     TIMESTAMPTZ DEFAULT NOW(),
    raw_broker_response JSONB
);

CREATE TABLE fills (
    fill_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id            UUID NOT NULL REFERENCES orders,
    instrument_id       UUID NOT NULL REFERENCES instrument_master,
    team_id             TEXT NOT NULL,
    strategy_id         TEXT NOT NULL,
    venue               TEXT NOT NULL,
    side                TEXT NOT NULL,
    quantity            DECIMAL NOT NULL,
    price               DECIMAL NOT NULL,
    fee                 DECIMAL NOT NULL DEFAULT 0,
    fee_currency        TEXT DEFAULT 'USD',
    is_maker            BOOLEAN,
    -- Slippage tracking
    expected_fill_price DECIMAL,
    slippage_bps        DECIMAL,    -- (actual - expected) / expected * 10000
    book_depth_at_fill  DECIMAL,    -- ADV or book depth at time of fill
    spread_at_fill_bps  DECIMAL,
    volatility_at_fill  DECIMAL,
    -- Timestamps
    fill_time_utc       TIMESTAMPTZ NOT NULL,
    ingest_time_utc     TIMESTAMPTZ DEFAULT NOW()
);
```

### Positions + Cash + Costs

```sql
CREATE TABLE positions (
    team_id             TEXT NOT NULL,
    instrument_id       UUID NOT NULL REFERENCES instrument_master,
    quantity            DECIMAL NOT NULL DEFAULT 0,
    avg_entry_price     DECIMAL,
    realized_pnl        DECIMAL DEFAULT 0,
    cost_basis          DECIMAL DEFAULT 0,
    -- Tax tracking
    entry_date          TIMESTAMPTZ,
    lots                JSONB,      -- array of {qty, price, date} for specific identification
    updated_at          TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (team_id, instrument_id)
);

CREATE TABLE cash_ledger (
    entry_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id             TEXT NOT NULL,
    entry_type          TEXT NOT NULL,
    -- Types: trade_settlement, fee, funding_payment, transfer_in, transfer_out,
    --   dividend, interest, margin_call, borrow_cost, tax_withholding
    amount              DECIMAL NOT NULL,
    currency            TEXT NOT NULL DEFAULT 'USD',
    reference_id        UUID,       -- fill_id, funding_payment_id, etc.
    balance_after       DECIMAL,
    entry_time_utc      TIMESTAMPTZ NOT NULL,
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE funding_payments (
    payment_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instrument_id       UUID NOT NULL REFERENCES instrument_master,
    team_id             TEXT NOT NULL,
    rate                DECIMAL NOT NULL,
    amount              DECIMAL NOT NULL,
    payment_time_utc    TIMESTAMPTZ NOT NULL
);

CREATE TABLE borrow_costs (
    cost_id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    instrument_id       UUID NOT NULL REFERENCES instrument_master,
    team_id             TEXT NOT NULL,
    daily_rate          DECIMAL NOT NULL,
    amount              DECIMAL NOT NULL,
    accrual_date        DATE NOT NULL
);
```

### Risk + Research + Config

```sql
CREATE TABLE risk_decisions (
    decision_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id            UUID REFERENCES orders,
    team_id             TEXT NOT NULL,
    decision            TEXT NOT NULL CHECK (decision IN ('approved', 'rejected', 'size_reduced')),
    reason              TEXT,
    -- Portfolio state at decision time
    pre_trade_heat      DECIMAL,
    gross_exposure      DECIMAL,
    net_exposure        DECIMAL,
    leverage            DECIMAL,
    correlation_risk    DECIMAL,
    factor_exposures    JSONB,
    daily_loss_pct      DECIMAL,
    drawdown_pct        DECIMAL,
    decided_at          TIMESTAMPTZ NOT NULL
);

CREATE TABLE research_observations (
    observation_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source              TEXT NOT NULL,   -- news_api, reddit, etherscan, google_trends, etc.
    instrument_id       UUID REFERENCES instrument_master,
    team_id             TEXT,
    observation_type    TEXT NOT NULL,    -- sentiment, flow, positioning, macro, narrative
    score               DECIMAL,
    confidence          DECIMAL,
    raw_payload         JSONB,
    llm_model           TEXT,            -- claude-sonnet-4-20250514, etc.
    llm_prompt_version  TEXT,
    observed_at         TIMESTAMPTZ NOT NULL,
    ingested_at         TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE model_predictions (
    prediction_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id             TEXT NOT NULL,
    instrument_id       UUID NOT NULL REFERENCES instrument_master,
    model_id            TEXT NOT NULL,
    model_version       TEXT NOT NULL,
    feature_version     TEXT NOT NULL,
    prediction          DECIMAL NOT NULL,
    confidence          DECIMAL,
    regime              TEXT,
    is_shadow           BOOLEAN DEFAULT false,
    predicted_at        TIMESTAMPTZ NOT NULL
);

CREATE TABLE reconciliation_incidents (
    incident_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id             TEXT NOT NULL,
    venue               TEXT NOT NULL,
    incident_type       TEXT NOT NULL,
    -- Types: position_mismatch, orphan_order, fill_gap, balance_diff,
    --   order_state_mismatch, missing_fill, extra_fill
    severity            TEXT DEFAULT 'warning',
    expected_state      JSONB NOT NULL,
    actual_state        JSONB NOT NULL,
    resolution          TEXT,
    auto_resolved       BOOLEAN DEFAULT false,
    detected_at         TIMESTAMPTZ NOT NULL,
    resolved_at         TIMESTAMPTZ
);

CREATE TABLE config_versions (
    config_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    team_id             TEXT,        -- NULL for global config
    config_type         TEXT NOT NULL, -- risk_limits, model_weights, strategy_params
    config_hash         TEXT NOT NULL,
    config_data         JSONB NOT NULL,
    active_from         TIMESTAMPTZ NOT NULL,
    active_to           TIMESTAMPTZ,
    changed_by          TEXT DEFAULT 'system'
);
```

### TimescaleDB Hypertables

```sql
-- Chunk intervals: indexes for active chunks should fit ~25% of RAM
-- M4 Max Pro: assume 48-96GB RAM → target 12-24GB for active chunk indexes

-- Market data: high volume, 1-day chunks, 90-day raw retention
CREATE TABLE market_data (
    time            TIMESTAMPTZ NOT NULL,
    instrument_id   UUID NOT NULL,
    open            DECIMAL, high DECIMAL, low DECIMAL, close DECIMAL,
    volume          DECIMAL,
    venue           TEXT NOT NULL,
    timeframe       TEXT DEFAULT '1m'  -- 1m, 5m, 1h, 1d
);
SELECT create_hypertable('market_data', 'time', chunk_time_interval => INTERVAL '1 day');
SELECT add_retention_policy('market_data', INTERVAL '90 days');
SELECT add_compression_policy('market_data', INTERVAL '7 days');

-- Order book snapshots: smaller, 4-hour chunks, 30-day retention
-- Store MINIMAL truth (bid/ask/spread/imbalance), NOT full L2 reconstruction
CREATE TABLE book_snapshots (
    time            TIMESTAMPTZ NOT NULL,
    instrument_id   UUID NOT NULL,
    best_bid        DECIMAL, best_ask DECIMAL,
    spread_bps      DECIMAL,
    depth_imbalance DECIMAL,
    bid_depth_usd   DECIMAL, ask_depth_usd DECIMAL
);
SELECT create_hypertable('book_snapshots', 'time', chunk_time_interval => INTERVAL '4 hours');
SELECT add_retention_policy('book_snapshots', INTERVAL '30 days');

-- Continuous aggregates with explicit refresh (NOT default 24hr)
CREATE MATERIALIZED VIEW market_data_1h WITH (timescaledb.continuous) AS
  SELECT time_bucket('1 hour', time) AS bucket, instrument_id,
         first(open, time) AS open, max(high) AS high,
         min(low) AS low, last(close, time) AS close, sum(volume) AS volume
  FROM market_data GROUP BY bucket, instrument_id;

SELECT add_continuous_aggregate_policy('market_data_1h',
  start_offset  => INTERVAL '3 hours',
  end_offset    => INTERVAL '1 hour',
  schedule_interval => INTERVAL '1 hour');

-- Daily aggregates forever (compressed)
CREATE MATERIALIZED VIEW market_data_1d WITH (timescaledb.continuous) AS
  SELECT time_bucket('1 day', time) AS bucket, instrument_id,
         first(open, time) AS open, max(high) AS high,
         min(low) AS low, last(close, time) AS close, sum(volume) AS volume
  FROM market_data GROUP BY bucket, instrument_id;
```

### Storage Tiers

| Tier | What | Retention |
|------|------|-----------|
| Raw event tables (market_data, book_snapshots) | Immutable append-only | 90 days raw, compressed after 7 days |
| Ledger tables (orders, fills, positions, cash) | Immutable truth | Forever |
| Aggregated views (1h, 1d) | Computed from raw | 1h: 2 years, 1d: forever |
| Research observations | LLM outputs, scrapes | 1 year |
| Blob/object store | Raw articles, filings, backtest artifacts | 1 year |

---

## Messaging Architecture

| Use Case | Transport | Delivery | Why |
|----------|-----------|----------|-----|
| Julia RPC (models, features, risk checks) | ZeroMQ IPC + **Lazy Pirate** | Reliable with retries/timeouts/heartbeats | Low latency, local only |
| Trade-critical events (signals, orders, fills) | **Redis Streams** | At-least-once + XACK | Durable, consumer groups, pending-entry tracking |
| Dashboard/UI updates | Redis Pub/Sub | At-most-once | Acceptable for display |
| Alerts (Telegram, email) | Redis Streams → alert consumer | At-least-once | Don't lose critical alerts |

### Idempotency

Exactly-once is fantasy. Design for **at-least-once + idempotent handlers**.

- Every order intent carries a unique `idempotency_key`
- OMS dedupes on key before processing
- Retries are safe because state transitions are idempotent
- Redis Streams consumers use `XREADGROUP` with explicit `XACK` on successful processing
- Unacknowledged messages are automatically retried via pending entry list (PEL)

### ZMQ Reliability (Lazy Pirate Pattern)

```
Python Client                    Julia Server
    │                                 │
    ├── send request ─────────────────►│
    │   (with timeout: 5s standard)    │
    │                                 │──── process
    │◄─── response ───────────────────┤
    │                                 │
    │   If timeout:                   │
    │   ├── close socket              │
    │   ├── reconnect                 │
    │   ├── retry (max 3 attempts)    │
    │   └── if all fail: circuit break│
    │                                 │
    │   Heartbeat every 5s:           │
    │   ├── send PING ────────────────►│
    │   │◄── PONG ────────────────────┤
    │   └── if no PONG for 15s:       │
    │       enter degraded mode       │
```

If Julia is unresponsive:
- Signal engine stops generating new signals (existing positions still monitored via broker adapter)
- Alert raised to monitoring
- Automatic restart attempt
- **No stale signals propagated** — circuit break prevents poisoned state

---

## Cross-Team Coordination (Control Plane)

### Correct Frequencies

| Function | Frequency | Mechanism |
|----------|-----------|-----------|
| Pre-trade risk | **Synchronous, inline** | Function call in order admission |
| Position/exposure updates | **Event-driven** (on every fill) | Redis Streams consumer |
| Kill switch | **Event-driven, immediate** | File watch + Redis Streams |
| Global exposure aggregation | **Event-driven** (on position change) | Redis Streams consumer |
| Capital allocation | **Daily or weekly** | Scheduled job |
| Research sharing | **Hourly** | Batch job |
| Learning/mutation | **Daily/offline** | Scheduled job |

### Capital Allocator (Slow, Shrunk, Skeptical)

| Team | Target | Min | Max |
|------|--------|-----|-----|
| Crypto | 30% | 15% | 40% |
| Stock | 35% | 20% | 50% |
| Polymarket | 15% | 5% | 25% |
| Forex | 20% | 10% | 30% |

**Allocation score (NOT raw trailing Sharpe):**

```
score = shrunk_alpha_estimate
      - correlation_penalty      (reduce if book is correlated with others)
      - drawdown_penalty         (reduce if recent drawdown)
      - turnover_penalty         (reduce if high churn)
      - slippage_penalty         (reduce if realized slippage is high)
      - model_instability_penalty (reduce if model predictions are noisy)
```

**Minimum requirements before any reallocation:**
- Minimum 200 independent trades per team (not just calendar days)
- Minimum 60 days of live age
- Confidence intervals on performance estimates (Bayesian shrinkage)
- Regime coverage (team has operated in at least 2 different vol regimes)
- Paper-to-live drift check (signals match between paper and live)
- Manual override bands (human can pin allocation within a range)

### Risk Overlord

**Hard limits (non-overridable):**

| Category | Limit | Action on Breach |
|----------|-------|-----------------|
| Total daily loss | 3% of total equity | Halt ALL teams immediately |
| Total drawdown | 12% from peak | All teams → conservative only |
| Per-team daily loss | 2% of team allocation | Halt that team |
| Single position size | 5% of total equity | Reject order |
| Total position count | 15 across all teams | Reject new orders |
| Total gross exposure | 2.5x equity | Reject new orders |
| Total crypto exposure | 40% of equity | Reject new crypto orders |

**Advanced limits:**

| Category | Implementation |
|----------|---------------|
| Gross + net exposure | Per-team and global caps |
| Leverage + margin headroom | Venue-specific margin calculations |
| Liquidity-adjusted sizing | Size as % of ADV or % of visible book depth |
| Venue concentration | Max % of equity on any single venue |
| Factor concentration | Factor exposure matrix, not just pairwise correlation |
| Stale-data gate | Block trading if any critical feed > 30s stale |
| Broker connectivity gate | Block trading if broker connection is down |
| Execution-quality gate | Block if realized slippage > 2x model prediction for last 20 fills |
| Trade-frequency throttle | Max orders per minute per team |
| Post-restart freeze | No trading until reconciliation incident count = 0 |

**Factor-aware correlation:**

The system must look through to underlying exposures:
- BTC position + MSTR position = crypto beta overlap
- BTC position + BTC prediction market = same directional exposure
- Growth stocks + QQQ = growth factor overlap
- EUR/USD long + USD-sensitive equities = USD factor overlap

Implementation: `factor_exposures` table with per-instrument factor loadings, updated weekly.

### Conservative Mode

Triggers:
- Dashboard button (min 24hr duration)
- Telegram command `/conservative`
- Kill switch file `~/.quantengine/CONSERVATIVE_MODE`
- Auto: 3 consecutive losing days
- Auto: VIX > 30 equivalent

Effects:
- All positions sizes halved
- Only mean-reversion + arbitrage strategies active
- Stop-losses tightened 50%
- No new leveraged positions
- No new positions in instruments with spread > 50bps

---

## Slippage Model (Conditional, Not Rolling Mean)

A single rolling mean of last 50 fills hides tail behavior and conflates different regimes.

**Model slippage conditionally by:**

| Dimension | Why |
|-----------|-----|
| Symbol | Different liquidity profiles |
| Venue | Different fee structures and book depth |
| Side (buy/sell) | Asymmetric impact |
| Order type | Market vs limit fill behavior |
| Size as % ADV | Large orders move the market |
| Size as % book depth | Thin books = more impact |
| Current spread | Wider spread = more slippage |
| Volatility regime | High vol = worse fills |
| Time of day / session | Open/close vs midday |
| Maker vs taker | Different fee tiers |
| Participation rate | How much of volume you represent |

Use **quantile-based estimates** (p50, p75, p95) within conditional buckets, not a single mean.

When slippage deteriorates, the correct response depends on context:
- Smaller order slices
- Wider aggression band (more passive)
- Change venue
- No trade (signal too weak for current cost)
- Reduce signal confidence
- Increase latency buffer

---

## Market Making: Separate Engine or Deferred

Market making is a **different operating mode**, not another strategy in the pipeline. It requires:
- High-quality, low-latency order book state
- Inventory control and skewing
- Sub-second cancel/replace discipline
- Adverse selection detection at tick level
- Exchange-specific throttling awareness
- Much tighter event loops than trend/carry/event strategies

**Decision:** Do not run market making through the standard 4-service pipeline. Either:
1. Build a dedicated, isolated market-making engine (Phase 5+), or
2. Defer until the execution gateway is rock-solid and battle-tested

---

## External Positioning Features (Not "Copy Trading")

The framing matters for safety. These are **weak, non-authoritative inputs** to the signal engine.

| Source | Latency | Honest Assessment |
|--------|---------|-------------------|
| SEC 13F filings | 45-day delay | Slow conviction/crowding factor. NOT real-time. NOT copy trading. |
| Binance leaderboard | Hours | Survivorship biased, can be gamed |
| On-chain whale flows | Minutes | May be hedged elsewhere, visible to everyone |
| Polymarket leaderboard | Hours | Same survivorship/gaming issues |
| COT reports | Weekly | Slow institutional positioning factor |
| Congress trades | 45-day delay | Same as 13F — slow factor |

These are processed as **weak features** in the signal engine. They never override model outputs. They are scored, versioned, and ignorable.

---

## The 4 Market Teams

### A. Crypto Team (Binance) — 24/7, start here
**Strategies:** Funding rate arb (m36), pairs trading (m37), mean reversion (m38), MACD trend (m35), cross-exchange arb (m33)
**Deferred:** L2 scalping, futures basis, market making (until execution gateway is battle-tested)
**Data:** Binance WS (existing), CryptoPanic, Reddit r/cryptocurrency
**Execution:** Binance adapter (REST + WS, reconnect, reconcile)
**External positioning:** On-chain whale flows, Binance leaderboard (both weak)
**Ops:** Funding rate payments need ledger treatment. Perpetual vs spot instrument mapping required.

### B. Stock Team (Alpaca) — Market hours, most liquid
**Strategies:** Daily trend (m35), pairs/stat arb (m37), mean reversion (m38), event-driven (earnings)
**Deferred:** Options (Phase 5, requires proper contract instrument handling)
**Data:** Polygon.io WS (existing). **Note:** Free Alpaca stream = IEX only. SIP requires paid tier. Design for SIP if serious about broad-market equities.
**Execution:** Alpaca adapter (REST v2, reconcile, wash-trade protection awareness)
**External positioning:** 13F filings (45-day delayed slow factor), congress trades
**Ops:** Corporate actions handling matters. Need instrument master for stock/option/ETF/ADR distinctions.

### C. Polymarket Team — Operationally unique
**Strategies:** Kalman filter (m31), calibration (s02), time-decay (m32), cross-market arb (m33), event study (s01)
**Deferred:** Market-making (separate engine or deferred)
**Data:** Polymarket Gamma API (existing), Metaculus, news sentiment
**Execution:** Polymarket adapter — **NOT just another broker.** Requires:
  - EIP-712 order signing
  - Onchain Polygon settlement awareness
  - Wallet/private key management in hot path
  - Geographic restriction handling (US/NY blocking)
  - Non-custodial trading model (different from traditional broker)
**External positioning:** Top-trader leaderboard (weak, survivorship biased)

### D. Forex Team (OANDA) — Macro-driven diversification
**Strategies:** Carry trade (interest rate differentials), momentum, mean reversion, macro event trading
**Data:** OANDA streaming, FRED (existing), ForexFactory calendar, COT reports
**Execution:** OANDA adapter — snapshot-plus-incremental account maintenance via last transaction ID. Build reconciler first.
**External positioning:** COT institutional positioning (slow factor)
**Ops:** Session effects, overnight financing, macro calendar handling.

---

## Tax Engine (Advisory First, Asset-Class Aware)

Tax logic should be **advisory first, not blocking.** The system surfaces tax implications; the human decides.

Must be asset-class aware — do NOT hard-wire one model across equities, options, crypto, and FX.

| Asset Class | Reporting | Key Rules |
|-------------|-----------|-----------|
| US Equities | 1099-B | Wash-sale (30-day across ALL teams/accounts), short-term vs long-term |
| Options | 1099-B | + constructive sale rules, straddle rules |
| Crypto | 1099-DA (2025+) | Specific identification method, basis reporting phased in 2026 |
| Forex | Section 988/1256 | Ordinary income (988) vs 60/40 capital gains (1256 election) |
| Prediction Markets | 1099-MISC likely | Treated as gambling income in most jurisdictions |

Implementation:
- Track holding periods per lot (specific identification method)
- Wash-sale window tracking across ALL teams
- Estimate tax drag as advisory metric (not gate)
- Year-end tax-loss harvesting suggestions
- FBAR flagging if foreign exchange balance > $10K
- **Consult tax professional before relying on any of this**

---

## Learning System (Constrained for Safety)

### Allowed in Live
- Offline model retraining (scheduled, validated before promotion)
- Shadow deployment (challenger runs alongside, logged but not traded)
- Gated promotion: challenger must pass full CPCV + regime + Monte Carlo validation before replacing incumbent
- Explicit rollback capability
- Regime-tagged evaluation

### NOT Allowed in Live
- Self-modifying live strategies with direct capital authority
- Cross-team raw parameter/weight transfer
- LLM outputs feeding directly into model mutation

### Cross-Team Learning Transfer (Limited to)
- Feature templates ("RSI(2) works well — try it on your assets")
- Preprocessing transforms
- Meta-labeling logic (Lopez de Prado bet/no-bet framework)
- Risk heuristics

Never raw learned weights, thresholds, or regime-specific parameters.

---

## Data Sources

### Market Data
| Source | API | Cost | Notes |
|--------|-----|------|-------|
| Binance | WS + REST | Free | Existing. Public trades, no auth for data. |
| Polygon.io | WebSocket | $29/mo starter | Existing. Real-time stocks. |
| Alpaca | REST v2 + WS | Free (IEX) / Paid (SIP) | Existing. Free = IEX only. |
| OANDA | v20 REST + streaming | Free demo | NEW. 70+ FX pairs. |
| Yahoo Finance | Unofficial REST | Free | Existing. Daily only, gaps possible. |

### Alternative / Research Data
| Source | API | Cost | Signal Strength |
|--------|-----|------|-----------------|
| Google Trends | SerpAPI | $50/mo | Weak, slow |
| Reddit | PRAW (OAuth) | Free | Weak, noisy |
| NewsAPI.org | REST | Free/paid | Weak without LLM extraction |
| CryptoPanic | REST | Free | Moderate for crypto |
| Etherscan | REST | Free (5 req/s) | Weak (whale flows may be hedged) |
| Whale Alert | REST + WS | Free tier | Weak (same caveat) |
| Quiver Quant | REST | $20/mo | Weak (45-day delayed) |
| DeFi Llama | REST | Free | Moderate for crypto |
| Glassnode | REST | $29/mo | Moderate for crypto |
| SEC EDGAR | REST | Free | Weak (45-day delayed 13F) |
| FRED | REST | Free | Moderate for macro regime |
| X/Twitter | Filtered Stream v2 | Free/paid | Weak-moderate |
| Metaculus | REST | Free | Weak (prediction aggregation) |
| ForexFactory | Scrape | Free | Moderate for FX calendar |
| CFTC COT | REST | Free | Moderate for FX positioning |

---

## File Structure

```
Julia_research/
├── QuantEngine/                        # EXISTING — wrapped via ZMQ, not rewritten
│   ├── src/                            # 127 Julia source files
│   ├── bin/                            # 17 CLI entry points
│   ├── test/                           # 36 test files
│   └── julia_bridge/                   # NEW: ZMQ Lazy Pirate server
│       ├── zmq_server.jl              #   Heartbeats, timeouts, circuit-breaking
│       ├── bridge_types.jl            #   MessagePack message definitions
│       └── test_bridge.jl             #   Round-trip integration tests
│
└── TradingSwarm/
    ├── pyproject.toml
    ├── docker-compose.yml              # Dev + paper mode
    ├── docker-compose.prod.yml         # Production (Linux)
    ├── .env.example
    │
    ├── src/
    │   ├── core/                       # PHASE 0 — build first
    │   │   ├── instrument_master.py   #   Canonical instruments + symbology
    │   │   ├── event_schema.py        #   Authoritative event definitions
    │   │   ├── idempotency.py         #   Key generation + dedupe
    │   │   └── config.py              #   Pydantic settings
    │   │
    │   ├── pipeline/                   # HOT PATH — 4 services per team
    │   │   ├── data_ingest.py         #   A. Feed adapters + normalization
    │   │   ├── signal_engine.py       #   B. Julia RPC + deterministic signals
    │   │   ├── risk_gate.py           #   C. Synchronous pre-trade risk
    │   │   └── oms.py                 #   D. Order state machine + execution
    │   │
    │   ├── execution/                  # Broker adapters (state synchronizers)
    │   │   ├── base_adapter.py        #   Interface: connect, reconnect, reconcile
    │   │   ├── binance_adapter.py     #   Crypto spot + futures
    │   │   ├── alpaca_adapter.py      #   Stocks (+ options Phase 5)
    │   │   ├── polymarket_adapter.py  #   EIP-712 signing, onchain settlement
    │   │   ├── oanda_adapter.py       #   Snapshot + incremental account state
    │   │   └── reconciler.py          #   Internal vs broker truth comparison
    │   │
    │   ├── teams/                      # Team-specific wiring
    │   │   ├── base.py                #   Wires 4 pipeline services
    │   │   ├── crypto.py
    │   │   ├── stock.py
    │   │   ├── polymarket.py
    │   │   └── forex.py
    │   │
    │   ├── control/                    # CONTROL PLANE
    │   │   ├── capital_allocator.py   #   Slow, shrunk, skeptical
    │   │   ├── risk_overlord.py       #   Global limits, factor-aware
    │   │   ├── conservative_mode.py   #   Human override
    │   │   └── kill_switch.py         #   Event-driven immediate halt
    │   │
    │   ├── ledger/                     # AUTHORITATIVE RECORDS
    │   │   ├── postgres.py            #   PostgreSQL + TimescaleDB
    │   │   ├── redis_streams.py       #   Durable trade-critical events
    │   │   ├── redis_pubsub.py        #   UI/telemetry only
    │   │   └── migrations/            #   Alembic migrations
    │   │
    │   ├── research/                   # RESEARCH PLANE (warm path)
    │   │   ├── feeds/
    │   │   │   ├── google_trends.py
    │   │   │   ├── reddit.py
    │   │   │   ├── news_api.py
    │   │   │   ├── sec_edgar.py
    │   │   │   ├── etherscan.py
    │   │   │   ├── defi_llama.py
    │   │   │   └── forex_factory.py
    │   │   ├── external_positioning.py #  13F, leaderboards, COT (weak signals)
    │   │   ├── llm_interpreter.py     #  Claude API: versioned, bounded, cached
    │   │   └── feature_store.py       #  Research features → PostgreSQL
    │   │
    │   ├── learning/                   # OFFLINE PLANE (cold path)
    │   │   ├── model_trainer.py       #  Scheduled retraining
    │   │   ├── strategy_mutation.py   #  Shadow → challenger → gated promotion
    │   │   ├── replay_harness.py      #  Deterministic sim from event logs
    │   │   └── performance_report.py  #  Claude-assisted post-mortems
    │   │
    │   ├── tax/                        # ADVISORY tax engine
    │   │   ├── tax_tracker.py         #  Per-lot holding periods, wash-sale
    │   │   ├── tax_rules.py           #  Per-asset-class rules
    │   │   └── tax_reports.py         #  Year-end reporting + harvesting
    │   │
    │   ├── dashboard/
    │   │   ├── app.py                 #  FastAPI + HTMX
    │   │   ├── templates/
    │   │   └── static/
    │   │
    │   └── monitoring/
    │       ├── alerts.py              #  Telegram + email (via Redis Streams)
    │       ├── health.py              #  Per-service health endpoints
    │       └── metrics.py             #  Prometheus export
    │
    ├── tests/
    │   ├── unit/                       # Standard unit tests
    │   ├── integration/                # Service-to-service tests
    │   ├── chaos/                      # Resilience tests
    │   │   ├── test_feed_gap.py
    │   │   ├── test_feed_reconnect.py
    │   │   ├── test_duplicate_messages.py
    │   │   ├── test_stale_data.py
    │   │   ├── test_broker_outage.py
    │   │   ├── test_clock_skew.py
    │   │   ├── test_cancel_all_restart.py
    │   │   ├── test_orphan_orders.py
    │   │   ├── test_partial_fill_reconciliation.py
    │   │   ├── test_position_mismatch.py
    │   │   └── test_limit_breach.py
    │   └── replay/                     # Deterministic replay from logs
    │
    └── deploy/
        ├── docker-compose.yml
        ├── docker-compose.prod.yml
        └── monitoring/
            ├── grafana/
            └── prometheus/
```

---

## Implementation Phases

### Phase 0: Foundations (Weeks 1-3)
**Goal:** The bones. Ledger, instrument master, messaging, OMS, reconciler. Zero strategies.

1. Create `TradingSwarm/` Python project
2. **Build instrument master + symbology** (canonical instrument definitions)
3. **Build authoritative ledger schema** (all tables above) in PostgreSQL + TimescaleDB
4. Set up PostgreSQL + TimescaleDB + Redis in Docker Compose (explicit chunk intervals, retention, compression)
5. **Build Redis Streams transport** (consumer groups, XACK, at-least-once delivery)
6. **Build ZMQ Lazy Pirate bridge** to Julia (heartbeats, timeouts, retries, circuit-breaking)
7. **Build order state machine** (the FSM above, with idempotency keys, dedupe)
8. **Build reconciler** (internal state vs broker truth, incident logging)
9. **Build monitoring + health endpoints** (not Phase 6)
10. Define authoritative event schema (every event carries full tracing fields)

**Deliverable:** Working bridge, durable messaging, OMS skeleton, ledger, reconciler, monitoring. No alpha. No strategies.

### Phase 1: One Team, One Broker, Clean Pipeline (Weeks 4-7)
**Goal:** Crypto team trading through the full pipeline in paper mode. The first milestone is: one team, one broker, one clean ledger, one reconciler, one replay harness.

1. Build 4 pipeline services for CryptoTeam:
   - Data Ingest (wraps existing Binance feed + normalization via instrument master)
   - Signal Engine (wraps Julia ensemble via ZMQ Lazy Pirate, with circuit-breaking)
   - Pre-Trade Risk Gate (synchronous, inline, comprehensive checks)
   - OMS + Execution Gateway (order FSM, Binance adapter, idempotent)
2. Binance adapter with:
   - Reconnect logic
   - Re-query open orders/positions on restart
   - Periodic reconciliation (every 5 min even when streams look healthy)
   - Cancel-all + flatten on emergency shutdown
3. Build deterministic replay harness (replay from Redis Streams event logs)
4. Build basic FastAPI dashboard (consuming Redis Pub/Sub for display)
5. End-to-end: data → features → signal → risk → order → fill → ledger → reconcile
6. Run existing Julia 1,561 tests — all must still pass (regression gate)

**Deliverable:** Crypto team paper trading through clean, deterministic, reconciled pipeline. Every order, fill, decision in the ledger.

### Phase 2: Stock Team + Cross-Team Risk (Weeks 8-11)
**Goal:** Two teams with factor-aware global risk.

1. Build StockTeam (4 services, Alpaca adapter with reconciliation)
2. Build Risk Overlord (global limits, factor exposure matrix, event-driven exposure updates)
3. Build Capital Allocator (slow, composite score, daily cadence)
4. Build conservative mode (dashboard button + Telegram + auto-triggers)
5. Cross-team factor exposure tracking
6. Post-restart freeze enforcement (no trading until reconciliation clean)
7. Chaos tests: broker outage, stale data, position mismatch, duplicate messages

**Deliverable:** Two teams with proper global risk, reconciliation, chaos-tested.

### Phase 3: Research Plane + Polymarket (Weeks 12-16)
**Goal:** Alternative data features (not authority) + third team.

1. Build Research Plane (Google Trends, Reddit, NewsAPI, CryptoPanic)
2. Build External Positioning Feature Service (13F, leaderboards, whale flows — all weak features)
3. Build LLM interpreter (Claude API — versioned, bounded, cached, ignorable)
4. Research features flow to signal engine as non-authoritative inputs
5. Build Polymarket team (4 services, EIP-712 adapter, geographic restrictions)
6. Tax engine v1 (advisory — surface implications, don't block trades)

**Deliverable:** Three teams with research features. LLMs fully outside hot path. Tax advisory.

### Phase 4: Forex Team + Production Infrastructure (Weeks 17-21)
**Goal:** Fourth team + production-grade ops.

1. Build OANDA adapter (snapshot + incremental, reconciler)
2. Build ForexTeam (4 services, carry trade + momentum)
3. Move to Linux server for 24/7:
   - Supervised services with restart policies
   - Persistent volumes + WAL archiving
   - NTP clock synchronization
   - Remote alerting (don't depend on local notifications)
   - Startup reconciliation before trading
4. Grafana dashboards + Prometheus metrics
5. Full chaos test suite on all 4 teams

**Deliverable:** Four teams on production infrastructure.

### Phase 5: Advanced Strategies + Options (Weeks 22-26)
**Goal:** Fill strategy gaps.

1. Options adapter (Alpaca multi-leg or IBKR TWS — with callback handling)
2. Covered calls, spreads (require proper contract/instrument master entries)
3. Futures basis trading (crypto spot vs perpetual — requires funding ledger)
4. If execution gateway is battle-tested: consider isolated market-making engine
5. Ornstein-Uhlenbeck mean reversion model

**Deliverable:** Broader strategy coverage with proper instrument support.

### Phase 6: Live Validation (Weeks 27-32)
**Goal:** Real-money ready.

1. **Minimum 30-day paper validation** across all 4 teams
2. Conditional slippage model (quantile-based, per symbol/venue/side/size/vol/session)
3. Full tax engine review with tax professional

**Live rollout gates (ALL must pass):**
- Clean reconciliation for 30 consecutive days (zero unresolved incidents)
- Broker connectivity 99.5%+ uptime
- Slippage drift bounded (realized within 1.5x of model for p75)
- Live-vs-backtest signal divergence bounded
- Minimum 200 independent trades per team
- Per-team Sharpe >= 1.0 with 95% confidence interval
- Chaos test suite 100% green
- Factor-aware global exposure within limits
- Replay harness reproduces paper-trading results from event log

---

## Remaining Blockers Before Live

These are production-readiness gaps that must be resolved across phases before live trading. They are not reasons to stop — they are reasons to make the design production-complete.

### 1. Redis Streams Persistence Must Be Deliberately Configured

Streams alone do not solve durability. Redis durability depends on persistence settings. With the common AOF `fsync every second` policy, roughly 1–2 seconds of data can be lost in a failure window.

**What to do:**

- Turn on AOF deliberately with an explicit fsync policy decision
- Decide whether critical writes need `WAITAOF` or replica acknowledgements
- Separate "can replay from Redis" from "must never lose order/fill truth"
- For the most critical entities (orders, fills, risk decisions), persist to PostgreSQL in the same business transaction boundary or via an **outbox/inbox pattern**

**Recommendation:** Redis Streams are fine for the first live version, but orders, fills, and risk decisions must not exist only in Redis before being durably recorded elsewhere.

### 2. Explicit Stale-Message Recovery Logic for Streams

`XREADGROUP` + `XACK` handles the happy path, but production also needs a plan for stuck pending messages. Redis documents the Pending Entries List, `XPENDING`, `XCLAIM`, and `XAUTOCLAIM` specifically for recovering messages when a consumer dies or stops progressing.

**Add explicitly:**

- Idle-time thresholds per stream
- A reaper/claim loop using `XAUTOCLAIM`
- Poison-message handling (messages that repeatedly fail processing)
- Dead-letter streams for repeated failures
- Stream trimming/retention rules that do not break replay or recovery

### 3. TimescaleDB DDL Ordering (Fixed)

~~The original examples called `create_hypertable()` before `CREATE TABLE`. TimescaleDB requires the regular PostgreSQL table to exist first before converting it to a hypertable.~~ **Fixed** — DDL examples now show correct ordering: `CREATE TABLE` first, then `create_hypertable()`.

### 4. Global Risk Needs an Atomic Reservation Model

**This is one of the main remaining design risks.**

The pre-trade risk gate is correctly synchronous and inline, but if multiple team processes can approve orders concurrently, the system can oversubscribe global limits during races.

**Example failure:**
1. Crypto and Stocks both check global gross exposure at nearly the same time
2. Both see room
3. Both approve
4. Combined result breaches the cap

**Fix — central risk reservation ledger:**

- DB transaction or advisory lock around global budget consumption
- Reserve capacity on approval, release on reject/cancel/expiry
- Fill-driven finalization (reservation → committed on fill)
- All reservation state in PostgreSQL (not Redis) for ACID guarantees

Until this exists, the risk system is logically correct but race-prone under concurrent team operation.

### 5. OMS Needs Parent/Child Order Modeling

The current OMS schema and FSM read as a single-layer order model, but the plan also calls for TWAP/VWAP and smart routing. That means one "order intent" can create multiple venue child orders.

**Required additions:**

- `order_intents` or parent orders (the risk-approved intent from the signal engine)
- `venue_orders` / child orders (individual slices sent to venues)
- Links between parent intent, slices, and fills
- Cancel/replace/amend flows at both parent and child level
- Separate completion logic: parent is complete when all children are terminal

Without this, execution analytics, partial-fill accounting, and recovery after restart will conflate parent-level intent with venue-level execution.

### 6. Positions Schema Needs Multi-Strategy Attribution

Orders and fills carry `strategy_id`, but `positions` is keyed by `(team_id, instrument_id)` only. If two strategies in the same team trade the same instrument, attribution, lot tracking, and deallocation logic break.

**Options (pick one):**

1. **`strategy_positions(team_id, strategy_id, instrument_id, ...)`** — granular strategy-level tracking, plus a higher-level netted team position view for risk
2. **`position_lots` table** — if accurate lot accounting and tax logic are priorities, track per-lot with strategy attribution

This is especially important for:
- Strategy-level performance evaluation
- Per-strategy kill switches
- Advisory tax logic (lot identification)
- Live vs challenger/shadow strategy comparisons

### 7. Secrets and Key Management Are Underspecified

The Polymarket section correctly acknowledges wallet/private key management in the hot path, but the plan does not specify production secret handling for any venue.

**Must specify:**

- Where signing keys and API secrets live (env vars, vault, KMS, secure enclave)
- Whether withdrawals are disabled on trading API keys (they should be)
- How secrets rotate without downtime
- How prod and paper keys are segregated (never in same config, never same env)
- Whether the Linux production host uses KMS/HSM or equivalent
- Operator access controls and audit logs for secret access

For a non-custodial venue like Polymarket (private key signs every order), this is not optional. For custodial venues, leaked API keys with withdrawal permissions are equally catastrophic.

### 8. Live Rollout Gates Should Be Ops-First, Not Sharpe-First

The current live gates include "Sharpe >= 1.0 with 95% confidence interval" for every team. That is too blanket and strategy-dependent to be a universal go-live gate. Slower or event-driven books will not produce that shape of statistical evidence on the same timeline.

**Reframed hard gates for go-live (ops-first):**

| Gate | Rationale |
|------|-----------|
| Zero unresolved reconciliation incidents for 30+ consecutive days | Proves the ledger and broker stay in sync |
| Bounded paper/live signal drift | Proves paper and live environments produce consistent behavior |
| Bounded slippage drift (realized within 1.5x model p75) | Proves execution cost model is calibrated |
| Broker connectivity 99.5%+ uptime | Proves adapter reliability |
| Restart/recovery drills passing | Proves the system survives process restarts cleanly |
| Deterministic replay matches ledger truth | Proves the event log is complete and correct |
| Risk reservation correctness under concurrency testing | Proves global limits hold under parallel team operation |

Performance quality (Sharpe, win rate, drawdown) matters for capital sizing and allocation decisions, but **operational correctness must gate live deployment**. A system that trades poorly but correctly is recoverable; a system that trades well but incorrectly is a time bomb.

---

## Resource Requirements

### Development / Paper Trading (M4 Max Pro, macOS)

| Service | CPU Cores | RAM |
|---------|-----------|-----|
| PostgreSQL + TimescaleDB | 2 | 2 GB |
| Redis | 1 | 1 GB |
| Julia engines (start with 1-2 teams) | 4 each | 4 GB each |
| Python pipeline (per team) | 2 | 2 GB |
| Dashboard + monitoring | 1 | 512 MB |
| **Total (2 teams)** | ~16 cores | ~16 GB |
| **Total (4 teams)** | ~24 cores | ~28 GB |

M4 Max Pro with 40 cores handles this comfortably for dev and paper trading.

### Production / Live Trading (Linux Server)

- Dedicated Linux server or VM (NOT a Mac desktop)
- Supervised services (systemd, Docker with restart policies)
- Persistent volumes with periodic backup
- PostgreSQL WAL archiving to object storage
- NTP clock synchronization
- Remote alerting (Telegram, email — not dependent on local system)
- Startup reconciliation job (mandatory before trading begins)
- Health probes for every service
- Automated restart with post-restart freeze until reconciliation clean
