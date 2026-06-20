# QuantEngine v10.0 — Production-Safe Architecture Plan

## Status

This plan supersedes prior versions.

**Decision:**
- **Approved for implementation**
- **Approved for paper trading after Phase 1**
- **Not approved for live capital until the pre-live gates in this document are all green**

This version keeps the strong parts of the current design — Julia for the numerical core, Python for orchestration, per-market books, a deterministic trading pipeline, and a full OMS/reconciliation layer — while fixing the remaining production blockers:
- trade-critical durability is defined explicitly
- stream recovery is defined explicitly
- global risk uses atomic reservations
- the OMS supports parent/child execution
- positions are tracked at strategy level
- keys/secrets management is first-class
- production hardening starts early, not late

---

## 1. Executive Summary

QuantEngine is a **deterministic, event-driven, multi-market trading platform** with four distinct operational planes:

1. **Hot Path / Live Trading Plane**
   - data ingest
   - normalization
   - signal generation
   - synchronous pre-trade risk
   - OMS/execution
   - broker truth reconciliation
   - ledger/state projections

2. **Warm Path / Research Plane**
   - news, filings, social, on-chain, public positioning, alt data
   - extraction and LLM labeling
   - cached research features
   - weak, non-authoritative inputs into the signal engine

3. **Cold Path / Offline Learning Plane**
   - retraining
   - challenger/shadow evaluation
   - replay
   - post-mortems
   - tax reporting

4. **Control Plane**
   - global risk aggregation
   - capital allocation
   - kill switch
   - config management
   - monitoring
   - human overrides

**Core principle:** decompose by operational plane and authority, not by “agent type.”

There are **no autonomous agents in the live trade path**.

---

## 2. Design Principles

1. **Determinism over autonomy**
   - Live trading must be reproducible from event logs.
   - Human-readable “intelligence” is useful in research, not in execution authority.

2. **Broker truth beats internal assumptions**
   - Internal state is provisional until reconciled with the venue/broker.

3. **At-least-once delivery + idempotent handlers**
   - Exactly-once is not a realistic operational assumption.

4. **All critical decisions are durable**
   - orders
   - fills
   - risk decisions
   - reservations
   - reconciliations
   - config activations

5. **Live path must survive restarts**
   - restart recovery is part of the primary design, not a patch.

6. **Research is allowed to fail silently**
   - If the research/LLM path is down, the system can still trade.
   - If the execution or reconciliation path is down, the system must not trade.

7. **Operational correctness before alpha breadth**
   - One clean broker + ledger + reconciler is more valuable than five half-working strategies.

---

## 3. Scope and Non-Goals

### In scope
- crypto, equities, Polymarket, FX
- paper and live trading
- centralized global risk with per-team budgets
- event replay
- advisory tax logic
- deterministic signals from the Julia core
- weak research features from external and LLM-assisted sources

### Out of scope for initial live deployment
- self-modifying live strategies
- LLM-driven execution decisions
- market making through the standard pipeline
- “copy trading” as a primary alpha source
- fully distributed multi-host orchestration beyond what is needed for a single primary live host plus backups/replicas

---

## 4. High-Level Architecture

## 4.1 The Hot Path (live trading)

```text
[Adapters]
   -> [Normalizer + Instrument Master]
   -> [Durable Event Log]
   -> [Signal Engine]
   -> [Pre-Trade Risk + Atomic Reservation]
   -> [OMS / Execution Gateway]
   -> [Broker / Venue]
   -> [Broker Events + Poll Reconciliation]
   -> [Ledger]
   -> [State Projections]
   -> [Reconciler]
   -> [Alerts / Dashboard]
```

### Hot-path rules
- no LLMs
- no human-language reasoning in authority decisions
- no asynchronous “agent debate”
- no polling-based risk approval
- no order submission without a durable order intent
- no trading after restart until reconciliation is clean

## 4.2 The Warm Path (research)

```text
[News / Filings / Social / On-Chain / Positioning / Alt Data]
   -> [Extraction + LLM Labeling + Caching]
   -> [Research Feature Store]
   -> [Signal Engine as weak inputs]
```

### Warm-path rules
- versioned prompts/templates/models
- bounded timeout and budget
- cached outputs
- confidence scores
- ignorable if unavailable

## 4.3 The Cold Path (offline)

```text
[Retraining]
[Shadow / Challenger Evaluation]
[Replay Harness]
[Performance Reporting]
[Tax Reports]
```

## 4.4 The Control Plane

```text
[Global Risk Aggregation]
[Capital Allocator]
[Kill Switch]
[Config + Feature Flags]
[Monitoring + Alerting]
[Human Override / Conservative Mode]
```

---

## 5. Runtime Services

Each market team is wired from the same deterministic service set.

### Service A — Data Ingest + Normalization
Responsibilities:
- connect to market/broker feeds
- normalize payloads to canonical event schema
- resolve venue symbols into canonical `instrument_id`
- detect gaps/staleness
- publish normalized events to the durable event log
- optionally publish telemetry to UI Pub/Sub

### Service B — Signal Engine
Responsibilities:
- consume normalized events
- compute features
- call Julia over local ZMQ reliability wrapper
- emit deterministic signal events
- emit shadow/challenger predictions separately
- read cached research features as weak inputs only

### Service C — Pre-Trade Risk + Sizing
Responsibilities:
- validate signal eligibility
- compute order sizing
- perform inline risk checks
- atomically reserve scarce global/team risk budget
- persist the decision before OMS submission

### Service D — OMS / Execution Gateway
Responsibilities:
- accept only risk-approved order intents
- maintain the canonical order state machine
- translate parent order intents into child venue orders
- route, slice, amend, cancel
- process broker callbacks and poll-based updates
- persist order/fill state
- trigger reconciliation and incident workflows

### Shared Infrastructure Services
- Postgres + TimescaleDB
- Redis Streams
- Redis Pub/Sub (UI/telemetry only)
- Monitoring/alerts
- Reconciler workers
- Config service
- Secrets service / KMS integration

---

## 6. Messaging and Durability Model

## 6.1 Transport choices

| Use case | Transport | Delivery model | Rule |
|---|---|---:|---|
| Julia feature/model RPC | ZeroMQ IPC/TCP (local) with reliability wrapper | request/reply with timeout + retry + heartbeat | local only |
| Trade-critical events | Redis Streams | at-least-once | required |
| UI updates | Redis Pub/Sub | at-most-once | acceptable |
| Alerts | Redis Streams -> alert consumer | at-least-once | required |
| Long-term truth | Postgres | durable transactional store | required |

## 6.2 Redis Streams policy

Redis Streams are the **transient durable event bus**, not the final system of record.

Trade-critical streams include:
- `market.normalized`
- `signal.generated`
- `risk.decisions`
- `risk.reservations`
- `oms.intents`
- `oms.events`
- `broker.events`
- `fills.events`
- `reconciliation.incidents`
- `alerts.critical`

### Consumer-group rules
- all trade-critical consumers use consumer groups
- handlers must be idempotent
- `XACK` only after durable processing is complete
- message retention/trimming must be explicit and environment-specific
- stream message IDs are not business IDs; business entities carry their own IDs

## 6.3 Redis persistence policy

Redis durability is only acceptable if explicitly configured.

### Required settings for live
- AOF enabled
- controlled fsync posture
- explicit recovery procedure documented
- replica policy documented where applicable
- periodic restore drills

### Policy
- normal market-data and signal events may tolerate the configured AOF window
- **order intents, risk approvals, reservations, fills, and critical OMS transitions must also be persisted to Postgres**
- for the most critical write boundaries, the service may block for stronger local durability before moving on

### Implementation recommendation
Use one of these patterns for critical transitions:
1. **DB-first**
   - write transaction in Postgres
   - publish corresponding stream event from an outbox table/worker

2. **stream-first with durability barrier**
   - append to Redis Stream
   - wait for configured durability barrier
   - persist to Postgres
   - continue only if both succeed

The preferred model for OMS/risk is **DB-first + outbox**, because it gives stronger auditability and easier replay semantics.

## 6.4 Pending-message recovery

Trade-critical streams must define explicit recovery behavior.

### Required mechanisms
- `XPENDING` visibility and metrics
- `XAUTOCLAIM`-based reclaim loop for idle/stuck messages
- per-stream idle thresholds
- dead-letter streams for poison messages
- retry counters and max-attempt rules
- operator alerting on growing pending-entry backlogs

### Default operational policy
- reclaim if message idle time exceeds configured threshold
- after N failed attempts, move to DLQ and raise incident
- do not allow silent starvation in the PEL

## 6.5 Idempotency policy

Every trade-critical handler must be safe under replay and retry.

### Required keys
- `correlation_id`
- `idempotency_key`
- `order_intent_id`
- `reservation_id`
- `broker_order_id` where available
- `signal_id`
- `config_hash`
- `model_version`
- `feature_version`

### Rules
- OMS dedupes on `idempotency_key`
- risk reservations are uniquely keyed and cannot be consumed twice
- fill ingestion dedupes by venue execution identifier or canonical synthetic key
- reconciliation incidents dedupe repeated detection of the same unresolved mismatch

---

## 7. Julia Integration

Julia remains the numerical core.

### Role
- feature generation
- model scoring
- ensemble composition
- existing model selection logic
- research/backtest analytics as needed

### Transport
- ZeroMQ with Lazy Pirate style client reliability wrapper
- heartbeat/ping support
- bounded retries
- circuit breaker

### Rules
- Julia is local to the host in initial deployment
- no dependence on Julia response for any state transition after order submission
- if Julia is degraded:
  - no new signals
  - existing positions continue to be monitored and reconciled
  - operators are alerted

### Default reliability posture
- standard timeout: low single-digit seconds
- heavy job timeout: longer, explicit
- retry count: small and bounded
- retry backoff: exponential with jitter
- hard failure path: circuit open, no new trades

---

## 8. Instrument Master and Symbology

This is a mandatory Phase 0 foundation.

## 8.1 Canonical instrument model

Every tradable instrument gets a canonical `instrument_id`.

Minimum fields:
- `instrument_id`
- `asset_class`
- `instrument_type`
- `base_symbol`
- `quote_symbol`
- `underlier_instrument_id` when applicable
- `multiplier`
- `tick_size`
- `lot_size`
- `min_order_size`
- `max_order_size`
- `expiry_date`
- `strike`
- `option_type`
- `settlement_type`
- `trading_calendar`
- `currency_exposure`
- `is_active`
- `metadata`

### Supported categories
- crypto spot
- crypto perpetual
- crypto dated future
- equity
- ETF
- ADR
- equity option
- FX spot/CFD as supported by venue
- prediction market contract / yes-no share

## 8.2 Symbol mapping
A separate mapping layer resolves:
- canonical instrument -> venue symbol
- venue symbol -> canonical instrument
- venue-specific metadata
- lot/tick conventions
- routing rules

## 8.3 Trading calendars and sessions
Required for:
- equities open/close rules
- FX session logic
- holiday calendars
- financing windows
- market-specific trading blackout logic

## 8.4 Factor exposures
Cross-team risk must work on factor exposures, not just pairwise historical correlations.

Examples:
- crypto beta
- USD exposure
- growth beta
- rates sensitivity
- event/prediction overlap

---

## 9. Authoritative Data Model

The platform needs a ledger-first design. The following entities are mandatory.

## 9.1 Core entities

### `order_intents`
The user/system’s canonical desired trade before venue slicing.

Minimum fields:
- `order_intent_id`
- `idempotency_key`
- `team_id`
- `strategy_id`
- `instrument_id`
- `venue_preference`
- `side`
- `intent_type`
- `requested_qty`
- `limit_price`
- `stop_price`
- `time_in_force`
- `signal_id`
- `correlation_id`
- `model_version`
- `feature_version`
- `config_hash`
- `current_state`
- `created_at`

### `risk_reservations`
Atomic claims on risk budget.

Minimum fields:
- `reservation_id`
- `order_intent_id`
- `scope` (global, team, venue, factor bucket)
- `reserved_notional`
- `reserved_gross`
- `reserved_margin`
- `status` (active, released, consumed, expired)
- `expires_at`
- `created_at`
- `released_at`

### `risk_decisions`
Audit of approval/rejection/size reduction.

### `venue_orders`
Child orders actually sent to the broker/venue.

Minimum fields:
- `venue_order_id_internal`
- `order_intent_id`
- `parent_slice_id` if applicable
- `broker_order_id`
- `venue`
- `child_seq`
- `state`
- `requested_qty`
- `submitted_qty`
- `filled_qty`
- `remaining_qty`
- `limit_price`
- `avg_fill_price`
- `submitted_at`
- `last_updated_at`

### `order_events`
Every OMS and broker-driven state transition.

### `fills`
Execution-level fill records.

### `strategy_positions`
Position state at strategy granularity.

Fields:
- `team_id`
- `strategy_id`
- `instrument_id`
- `quantity`
- `avg_entry_price`
- `realized_pnl`
- `cost_basis`
- `lots`
- `updated_at`

### `team_positions`
Netted team-level view derived from strategy positions.

### `cash_ledger`
Cash flows including:
- settlements
- fees
- funding
- borrow
- dividends
- interest
- transfers
- tax-related adjustments if modeled

### `funding_payments`
### `borrow_costs`
### `corporate_actions`
### `research_observations`
### `model_predictions`
### `reconciliation_incidents`
### `config_versions`
### `service_incidents`
### `audit_log`

## 9.2 State projections
Derived/current-state views are allowed, but immutable truth lives in the underlying append-only/event-style tables plus canonical ledgers.

## 9.3 Tracing fields
All critical entities/events should carry:
- `team_id`
- `strategy_id` where relevant
- `instrument_id`
- `venue`
- `signal_id`
- `order_intent_id`
- `reservation_id`
- `correlation_id`
- `event_time_utc`
- `ingest_time_utc`
- `model_version`
- `feature_version`
- `config_hash`

---

## 10. OMS and Execution Design

This is the most important runtime service.

## 10.1 Parent/child order model

The OMS must support both:
- **parent intent**
- **child venue orders**

This is mandatory if the system does:
- TWAP
- VWAP
- smart routing
- cancel/replace
- venue failover
- slice throttling

### Why this matters
A single user/system intent may produce:
- multiple child venue orders
- cancellations and resubmissions
- partial fills across time
- routing changes after adverse movement

Without a parent/child model, execution analytics and recovery become untrustworthy.

## 10.2 Canonical parent intent states

```text
intent_created
-> risk_pending
-> risk_approved
-> reserving_budget
-> accepted_by_oms
-> routing
-> working
-> partially_filled
-> filled
-> canceled
-> rejected
-> expired
-> suspended
```

## 10.3 Child venue order states

```text
child_created
-> submitted
-> acknowledged
-> partially_filled
-> filled
-> cancel_requested
-> canceled
-> rejected
-> expired
-> unknown_but_open
```

`unknown_but_open` is important during outages or callback gaps.

## 10.4 OMS responsibilities
- dedupe on idempotency key
- own the parent/child mapping
- allocate slices
- enforce per-venue routing rules
- process fills/cancels/rejects
- detect orphaned or stale working orders
- request cancel-all/flatten
- emit slippage and execution-quality metrics
- survive restart and resume safely

## 10.5 Restart behavior

On OMS restart:
1. load unfinished internal intents/orders
2. query broker/venue for open orders
3. query positions/balances
4. match internal and external state
5. write incidents for mismatches
6. freeze trading until the mismatch set is resolved or intentionally acknowledged by policy

## 10.6 Reconciliation cadence
Use both:
- event-driven reconciliation on broker events/fills
- periodic poll-based reconciliation even if streams look healthy

This is mandatory because venue callbacks can gap.

---

## 11. Pre-Trade Risk and Atomic Reservation

Global risk must be **authoritative and race-safe**.

## 11.1 Risk must be inline
The signal path blocks on the risk decision.

There is no asynchronous “maybe later” approval.

## 11.2 Atomic reservation model
Approval is not enough. The system must reserve scarce budget atomically.

### Example scarce resources
- global gross exposure
- team notional budget
- venue concentration cap
- margin headroom
- factor bucket exposure
- max order rate
- position count slots

### Required behavior
- reservation and risk decision happen atomically
- a reservation can be consumed only once
- reservations expire if the OMS never turns them into working orders
- reservations are released on reject/cancel/timeout
- fills convert reserved capacity into actual exposure

### Implementation options
**Preferred:** Postgres transaction with row/advisory locks on risk budget records.

### Reservation lifecycle
```text
risk_check_started
-> reservation_created
-> reservation_consumed_by_oms
-> released / expired / converted_to_exposure
```

## 11.3 Risk controls

### Hard non-overridable controls
- global daily loss
- global drawdown
- per-team daily loss
- gross exposure cap
- single-position cap
- position count cap
- venue concentration cap
- post-restart freeze

### Advanced controls
- leverage and margin headroom
- liquidity-adjusted sizing
- stale-feed gate
- broker-connectivity gate
- execution-quality deterioration gate
- factor concentration
- currency concentration
- trade-frequency throttle
- regime-specific limits
- session-specific rules

## 11.4 Conservative mode
Human-triggered or auto-triggered reduced-risk mode with:
- reduced sizing
- leverage restrictions
- selective strategy activation
- higher liquidity standards

---

## 12. Broker / Venue Adapter Requirements

Adapters are **state synchronizers**, not thin wrappers.

## 12.1 Common requirements
Every adapter must implement:
- connect
- reconnect
- subscribe/listen
- REST backfill or poll loop
- open-order query
- position query
- balance query
- order submit
- order cancel
- cancel-all if supported
- reconcile
- normalize broker events
- map internal/external IDs
- rate-limit handling
- outage/backoff handling

## 12.2 Binance
- REST + WebSocket
- reconnect logic
- funding and fee treatment
- spot/perp/futures distinctions in instrument master

## 12.3 Alpaca
- execution adapter
- account/order/position reconciliation
- explicit awareness that free real-time stock data is IEX-only, while broader SIP data requires the paid tier
- wash-trade protection behavior reflected in paper and live testing

## 12.4 Polymarket
Treat as operationally distinct:
- EIP-712 signing
- key custody/signing flow
- Polygon settlement awareness
- geoblock checks before order placement
- non-custodial operational model
- explicit user-region handling in deployment policy

## 12.5 OANDA
- initial full snapshot
- incremental update maintenance by transaction ID
- periodic account refresh
- financing/session awareness

## 12.6 IBKR (later phase)
- callback-heavy API model
- broken socket handling
- open-order recovery
- more complex operational surface than earlier venues

---

## 13. Storage Design

## 13.1 Postgres + TimescaleDB roles

### Postgres
- transactional truth
- orders
- fills
- reservations
- risk decisions
- reconciliations
- config
- audit

### TimescaleDB
- time-series market data
- book snapshots
- metrics
- derived candles/aggregates

## 13.2 Hypertable rules
- create normal Postgres table first
- convert to hypertable second
- set chunk intervals intentionally
- set retention and compression policies intentionally
- set continuous aggregate refresh explicitly

## 13.3 Storage tiers

| Tier | Contents | Retention |
|---|---|---|
| Raw market time series | candles, normalized quotes/trades, minimal order-book truths | finite, compressed |
| Ledger truth | orders, fills, cash, reservations, incidents, audit | effectively forever |
| Derived read models | positions, exposure projections, dashboards | rebuildable |
| Research observations | LLM and external research outputs | bounded, e.g. 1 year |
| Object/blob store | raw articles, filings, reports, replay artifacts | bounded by policy |

## 13.4 Order-book storage rule
Store the **minimum raw truth needed** for replay and analytics, not arbitrary full L2 retention by default.

---

## 14. Strategy and Position Attribution

The system must support:
- multiple strategies within one team trading the same instrument
- per-strategy PnL
- per-strategy kill switches
- lot-aware tax tracking
- challenger vs incumbent attribution

### Rule
The authoritative live position should exist at **strategy level**, with team- and global-level netted views derived from it.

---

## 15. Research Plane and External Features

Research inputs are allowed, but they are not authoritative.

## 15.1 LLM rules
LLMs may:
- summarize unstructured data
- extract structured facts
- classify narratives/regimes
- assist with post-mortems and reports

LLMs may not:
- place live trades
- override risk
- mutate live strategies directly
- bypass reconciliation or durability rules

## 15.2 External positioning features
Treat these as weak signals:
- 13F
- public leaderboards
- whale tracking
- COT
- public congressional trades
- crowd forecasts

### Rule
These features are:
- delayed or noisy
- often survivorship-biased
- potentially hedged elsewhere
- never a primary source of live execution authority

---

## 16. Tax Engine

Tax logic is **advisory first**.

### Requirements
- asset-class-aware rules
- specific identification / lot tracking where supported
- holding-period awareness
- wash-sale and related policy handling where applicable
- crypto reporting awareness
- foreign account/balance reporting awareness
- explicit disclaimer that tax professional review is mandatory before production reliance

### Rule
Tax logic must not block hot-path order submission in the initial live release.

---

## 17. Secrets, Keys, and Access Control

This is mandatory before live deployment.

## 17.1 Secret classes
- API keys
- broker credentials
- Polymarket signing keys / wallet material
- database credentials
- alerting/webhook secrets

## 17.2 Required controls
- encrypted at rest
- never committed to repo
- environment separation for dev/paper/live
- least-privilege service identities
- rotation procedure
- audit logging of secret access where supported
- emergency revoke/runbook

## 17.3 Key-management policy
Preferred order:
1. cloud or host KMS/HSM-backed secret store
2. OS keychain / secure enclave backed dev storage
3. encrypted file only as a temporary fallback for non-production work

### Additional live controls
- separate paper and live credentials
- withdrawals disabled wherever possible
- trading-only API scopes wherever possible
- distinct wallets/accounts per environment
- operator MFA on all admin surfaces

---

## 18. Monitoring, Alerting, and Incidents

Monitoring starts in Phase 0.

## 18.1 Health categories
- feed health
- Julia health
- Redis health
- Postgres health
- broker connectivity
- pending-message backlog
- reconciliation incident count
- open stale orders
- execution-quality drift
- risk reservation lock contention
- clock skew
- disk usage / WAL growth

## 18.2 Critical alerts
- broker disconnected
- feed stale
- OMS restart
- unresolved reconciliation incident
- reservation deadlock/timeout
- DLQ growth
- order state mismatch
- unusual slippage breach
- kill switch activation

## 18.3 Incident policy
Every severe incident gets:
- unique incident ID
- timeline
- impacted services
- affected orders/positions
- resolution notes
- follow-up action item

---

## 19. Testing and Validation

## 19.1 Test classes
- unit tests
- integration tests
- contract tests for adapters
- replay tests
- chaos tests
- restart/recovery drills

## 19.2 Mandatory chaos scenarios
- feed gap
- duplicate stream message
- out-of-order broker event
- stale data
- broker outage
- Redis restart
- Postgres restart
- clock skew
- OMS restart mid-fill
- orphaned order
- partial-fill mismatch
- position mismatch
- cancel-all drill
- global risk breach race between teams

## 19.3 Replay requirements
- deterministic replay from persisted events
- ability to reproduce paper/live outcomes within defined tolerance
- replay tool supports incident reconstruction

---

## 20. Market Teams

## 20.1 Crypto Team
Start here.

Initial scope:
- mean reversion
- trend
- stat-arb / pairs
- funding-aware strategies that have proper ledger support

Deferred:
- market making
- highly latency-sensitive L2 scalping unless separately justified
- complex basis until funding/cash/borrow ledger is proven

## 20.2 Stock Team
Initial scope:
- daily/intraday liquid equities strategies
- event-driven strategies with realistic data assumptions
- pairs/stat-arb only with proper corporate-action handling

Deferred:
- options until the contract model and adapter support are complete

## 20.3 Polymarket Team
Initial scope:
- calibration / event-study / mispricing / cross-market research-backed strategies

Special operational requirements:
- geoblock compliance
- signing-key controls
- settlement awareness

Deferred:
- market making

## 20.4 FX Team
Initial scope:
- carry
- momentum
- mean reversion
- macro-event aware strategies

Special requirements:
- financing awareness
- snapshot/incremental reconciliation
- session logic

---

## 21. Phased Implementation Plan

## Phase 0 — Foundations
Goal: build the bones, not alpha breadth.

Deliver:
- Python project skeleton
- instrument master + symbology
- canonical event schema
- Postgres/TimescaleDB setup
- Redis Streams setup
- Redis AOF and recovery policy
- DB-first or outbox pattern for OMS/risk critical transitions
- Julia bridge with reliability wrapper
- order intent model
- parent/child OMS skeleton
- risk reservation ledger
- reconciler skeleton
- monitoring + health endpoints
- secret-management baseline

Exit criteria:
- restart drills pass
- critical entities durable
- streams recover stuck consumers
- no strategy logic required yet

## Phase 1 — One Team, One Broker, Clean Pipeline
Goal: one complete paper-trading pipeline.

Scope:
- Crypto team only
- Binance adapter
- end-to-end: normalized data -> signal -> risk -> reservation -> OMS -> fill -> ledger -> reconciliation
- replay harness
- dashboard
- paper-trading only

Exit criteria:
- every order/fill/risk decision durable
- no unresolved reconciliation incidents in steady-state testing
- restart freeze works
- duplicate message tests pass

## Phase 2 — Cross-Team Risk + Stocks
Goal: two teams with shared global risk.

Scope:
- Stock team
- global risk aggregation
- factor-aware exposure
- capital allocator
- conservative mode
- concurrency/race tests on reservations

Exit criteria:
- no oversubscription under concurrent approvals
- global caps enforced correctly
- team and global projections align

## Phase 3 — Research Plane + Polymarket
Goal: add warm-path features safely.

Scope:
- research ingestors
- LLM feature extraction
- external positioning feature service
- Polymarket adapter
- advisory tax v1

Exit criteria:
- research plane failure does not affect hot path
- Polymarket key handling and geoblock controls validated

## Phase 4 — FX + Production Infrastructure
Goal: move onto production-shaped infrastructure.

Scope:
- OANDA adapter
- FX team
- Linux live host(s)
- persistent volumes
- WAL archiving
- remote alerting
- NTP validation
- service supervision

Exit criteria:
- full-chaos suite on all active teams
- restore and restart drills pass

## Phase 5 — Advanced Instruments / Strategies
Scope:
- options
- richer contract support
- more sophisticated routing
- possible isolated market-making engine

Exit criteria:
- no expansion until OMS/execution metrics and reconciliation quality are already strong

## Phase 6 — Live Validation
Goal: qualify for live capital.

Minimum validation:
- at least 30 days of paper trading on the intended live configuration
- replay parity
- bounded slippage drift
- clean reconciliation record
- operational runbooks reviewed
- tax review performed

---

## 22. Pre-Live Gates

All must pass before first live dollar.

### Hard operational gates
- zero unresolved reconciliation incidents over the required validation window
- startup reconciliation completes cleanly
- OMS restart drill passes
- Redis recovery drill passes
- Postgres restore drill passes
- pending-entry reclaim logic demonstrated
- DLQ procedure demonstrated
- global risk reservation race test passes
- kill switch and flatten drills pass
- live and paper credentials fully segregated
- alerting validated out of band

### Quality gates
- bounded paper/live signal divergence
- bounded slippage drift by defined quantiles
- minimum trade count by team
- acceptable broker uptime and feed health
- execution-quality model stable enough for gating
- performance statistics reviewed, but not used as the sole go-live criterion

### Human gates
- runbooks approved
- on-call owner designated
- emergency contact/escalation defined
- tax/compliance review completed as appropriate

---

## 23. Runbooks That Must Exist

Before live deployment, write these runbooks:
- broker outage
- feed stale
- OMS restart
- Redis failover/recovery
- Postgres recovery/restore
- reconciliation mismatch
- kill switch activation
- unexpected open order
- unexpected position
- key compromise / credential revoke
- Polymarket geoblock/compliance handling
- clock skew / time sync failure

---

## 24. Example Canonical DDL Skeleton

The final implementation can evolve, but the following structure is the intended baseline.

```sql
-- 1) Instruments
CREATE TABLE instrument_master (
    instrument_id        UUID PRIMARY KEY,
    asset_class          TEXT NOT NULL,
    instrument_type      TEXT NOT NULL,
    base_symbol          TEXT NOT NULL,
    quote_symbol         TEXT,
    underlier_instrument_id UUID,
    multiplier           NUMERIC,
    tick_size            NUMERIC,
    lot_size             NUMERIC,
    expiry_date          TIMESTAMPTZ,
    strike               NUMERIC,
    option_type          TEXT,
    settlement_type      TEXT,
    trading_calendar     TEXT,
    metadata             JSONB,
    is_active            BOOLEAN NOT NULL DEFAULT TRUE,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE symbol_mapping (
    instrument_id        UUID NOT NULL REFERENCES instrument_master(instrument_id),
    venue                TEXT NOT NULL,
    venue_symbol         TEXT NOT NULL,
    venue_metadata       JSONB,
    PRIMARY KEY (instrument_id, venue)
);

-- 2) Order intents
CREATE TABLE order_intents (
    order_intent_id      UUID PRIMARY KEY,
    idempotency_key      TEXT NOT NULL UNIQUE,
    team_id              TEXT NOT NULL,
    strategy_id          TEXT NOT NULL,
    instrument_id        UUID NOT NULL REFERENCES instrument_master(instrument_id),
    venue_preference     TEXT,
    side                 TEXT NOT NULL,
    intent_type          TEXT NOT NULL,
    requested_qty        NUMERIC NOT NULL,
    limit_price          NUMERIC,
    stop_price           NUMERIC,
    time_in_force        TEXT,
    signal_id            UUID,
    correlation_id       UUID NOT NULL,
    model_version        TEXT NOT NULL,
    feature_version      TEXT NOT NULL,
    config_hash          TEXT NOT NULL,
    current_state        TEXT NOT NULL,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 3) Atomic risk reservations
CREATE TABLE risk_reservations (
    reservation_id       UUID PRIMARY KEY,
    order_intent_id      UUID NOT NULL REFERENCES order_intents(order_intent_id),
    scope                TEXT NOT NULL,
    reserved_notional    NUMERIC NOT NULL DEFAULT 0,
    reserved_gross       NUMERIC NOT NULL DEFAULT 0,
    reserved_margin      NUMERIC NOT NULL DEFAULT 0,
    status               TEXT NOT NULL,
    expires_at           TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    released_at          TIMESTAMPTZ
);

-- 4) Child venue orders
CREATE TABLE venue_orders (
    venue_order_id_internal UUID PRIMARY KEY,
    order_intent_id      UUID NOT NULL REFERENCES order_intents(order_intent_id),
    venue                TEXT NOT NULL,
    child_seq            INTEGER NOT NULL,
    broker_order_id      TEXT,
    current_state        TEXT NOT NULL,
    requested_qty        NUMERIC NOT NULL,
    submitted_qty        NUMERIC,
    filled_qty           NUMERIC NOT NULL DEFAULT 0,
    remaining_qty        NUMERIC,
    limit_price          NUMERIC,
    avg_fill_price       NUMERIC,
    submitted_at         TIMESTAMPTZ,
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(order_intent_id, venue, child_seq)
);

-- 5) Order events
CREATE TABLE order_events (
    event_id             UUID PRIMARY KEY,
    order_intent_id      UUID REFERENCES order_intents(order_intent_id),
    venue_order_id_internal UUID REFERENCES venue_orders(venue_order_id_internal),
    event_type           TEXT NOT NULL,
    broker_order_id      TEXT,
    event_time_utc       TIMESTAMPTZ NOT NULL,
    ingest_time_utc      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    payload              JSONB
);

-- 6) Fills
CREATE TABLE fills (
    fill_id              UUID PRIMARY KEY,
    order_intent_id      UUID NOT NULL REFERENCES order_intents(order_intent_id),
    venue_order_id_internal UUID REFERENCES venue_orders(venue_order_id_internal),
    instrument_id        UUID NOT NULL REFERENCES instrument_master(instrument_id),
    team_id              TEXT NOT NULL,
    strategy_id          TEXT NOT NULL,
    venue                TEXT NOT NULL,
    side                 TEXT NOT NULL,
    quantity             NUMERIC NOT NULL,
    price                NUMERIC NOT NULL,
    fee                  NUMERIC NOT NULL DEFAULT 0,
    fee_currency         TEXT,
    expected_fill_price  NUMERIC,
    slippage_bps         NUMERIC,
    fill_time_utc        TIMESTAMPTZ NOT NULL,
    ingest_time_utc      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- 7) Strategy-level positions
CREATE TABLE strategy_positions (
    team_id              TEXT NOT NULL,
    strategy_id          TEXT NOT NULL,
    instrument_id        UUID NOT NULL REFERENCES instrument_master(instrument_id),
    quantity             NUMERIC NOT NULL DEFAULT 0,
    avg_entry_price      NUMERIC,
    realized_pnl         NUMERIC NOT NULL DEFAULT 0,
    cost_basis           NUMERIC NOT NULL DEFAULT 0,
    lots                 JSONB,
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (team_id, strategy_id, instrument_id)
);

-- 8) Risk decisions
CREATE TABLE risk_decisions (
    decision_id          UUID PRIMARY KEY,
    order_intent_id      UUID REFERENCES order_intents(order_intent_id),
    team_id              TEXT NOT NULL,
    decision             TEXT NOT NULL,
    reason               TEXT,
    risk_snapshot        JSONB NOT NULL,
    decided_at           TIMESTAMPTZ NOT NULL
);

-- 9) Reconciliation incidents
CREATE TABLE reconciliation_incidents (
    incident_id          UUID PRIMARY KEY,
    team_id              TEXT NOT NULL,
    venue                TEXT NOT NULL,
    incident_type        TEXT NOT NULL,
    severity             TEXT NOT NULL,
    expected_state       JSONB NOT NULL,
    actual_state         JSONB NOT NULL,
    status               TEXT NOT NULL DEFAULT 'open',
    detected_at          TIMESTAMPTZ NOT NULL,
    resolved_at          TIMESTAMPTZ
);
```

### Timescale pattern example
```sql
CREATE TABLE market_data (
    time                 TIMESTAMPTZ NOT NULL,
    instrument_id        UUID NOT NULL,
    venue                TEXT NOT NULL,
    timeframe            TEXT NOT NULL,
    open                 NUMERIC,
    high                 NUMERIC,
    low                  NUMERIC,
    close                NUMERIC,
    volume               NUMERIC
);

SELECT create_hypertable('market_data', by_range('time'));
```

---

## 25. Project Structure

```text
QuantEngine/
├── Julia_research/
│   └── QuantEngine/
│       ├── src/
│       ├── test/
│       └── julia_bridge/
│           ├── zmq_server.jl
│           ├── bridge_types.jl
│           └── test_bridge.jl
│
└── TradingSwarm/
    ├── pyproject.toml
    ├── src/
    │   ├── core/
    │   │   ├── event_schema.py
    │   │   ├── instrument_master.py
    │   │   ├── idempotency.py
    │   │   └── config.py
    │   ├── pipeline/
    │   │   ├── data_ingest.py
    │   │   ├── signal_engine.py
    │   │   ├── risk_gate.py
    │   │   └── oms.py
    │   ├── execution/
    │   │   ├── base_adapter.py
    │   │   ├── binance_adapter.py
    │   │   ├── alpaca_adapter.py
    │   │   ├── polymarket_adapter.py
    │   │   ├── oanda_adapter.py
    │   │   └── reconciler.py
    │   ├── control/
    │   │   ├── risk_overlord.py
    │   │   ├── capital_allocator.py
    │   │   ├── conservative_mode.py
    │   │   └── kill_switch.py
    │   ├── ledger/
    │   │   ├── postgres.py
    │   │   ├── outbox.py
    │   │   ├── redis_streams.py
    │   │   └── migrations/
    │   ├── research/
    │   │   ├── feeds/
    │   │   ├── llm_interpreter.py
    │   │   ├── external_positioning.py
    │   │   └── feature_store.py
    │   ├── learning/
    │   │   ├── replay_harness.py
    │   │   ├── model_trainer.py
    │   │   ├── strategy_mutation.py
    │   │   └── performance_report.py
    │   ├── tax/
    │   ├── dashboard/
    │   ├── monitoring/
    │   └── security/
    │       ├── secrets.py
    │       ├── key_policy.md
    │       └── access_control.py
    ├── tests/
    │   ├── unit/
    │   ├── integration/
    │   ├── contract/
    │   ├── chaos/
    │   └── replay/
    └── deploy/
        ├── docker-compose.yml
        ├── docker-compose.prod.yml
        ├── systemd/
        └── monitoring/
```

---

## 26. Final Go/No-Go Guidance

### Good to do now
- build Phase 0 immediately
- target one-broker, one-team paper trading as the first serious milestone
- treat the OMS, ledger, reservations, and reconciliation as the core product

### Do not do yet
- expand strategy count aggressively before the first clean paper pipeline
- add market making to the standard pipeline
- let research/LLM outputs gain execution authority
- treat Redis Streams as the only source of truth
- trade real money before runbooks and recovery drills are complete

### Operating mantra
**No durable intent, no order.  
No clean reconciliation, no trading.  
No atomic reservation, no approval.  
No key hygiene, no live deployment.**

---

## 27. External References

These references informed the production-hardening parts of the design:

1. Redis Streams documentation  
   https://redis.io/docs/latest/develop/data-types/streams/

2. Redis persistence (AOF/RDB)  
   https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/

3. Redis `WAITAOF`  
   https://redis.io/docs/latest/commands/waitaof/

4. Redis `XAUTOCLAIM`  
   https://redis.io/docs/latest/commands/xautoclaim/

5. ZeroMQ Guide, Chapter 4 — Reliable Request-Reply Patterns  
   https://zguide.zeromq.org/docs/chapter4/

6. OANDA v20 Best Practices  
   https://developer.oanda.com/rest-live-v20/best-practices/

7. Tiger Data / Timescale `create_hypertable`  
   https://www.tigerdata.com/docs/api/latest/hypertable/create_hypertable

8. Alpaca Market Data FAQ  
   https://docs.alpaca.markets/docs/market-data-faq

9. Polymarket Geographic Restrictions  
   https://docs.polymarket.com/api-reference/geoblock