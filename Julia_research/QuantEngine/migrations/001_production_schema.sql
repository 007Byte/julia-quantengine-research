-- QuantEngine Production Schema — Postgres
-- Adds production OMS, risk reservations, reconciliation to the existing model.
-- The existing SQLite tables (trades, equity_snapshots, model_performance) stay for
-- backward compat; production uses these Postgres tables for the durable path.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- Order intents (parent orders)
-- ============================================================

CREATE TABLE IF NOT EXISTS order_intents (
    order_intent_id      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    idempotency_key      TEXT NOT NULL UNIQUE,
    team_id              TEXT NOT NULL,
    strategy_id          TEXT NOT NULL,
    instrument_id        TEXT NOT NULL,
    venue_preference     TEXT,
    side                 TEXT NOT NULL,
    intent_type          TEXT NOT NULL,
    requested_qty        NUMERIC NOT NULL,
    limit_price          NUMERIC DEFAULT 0,
    stop_price           NUMERIC DEFAULT 0,
    time_in_force        TEXT DEFAULT 'gtc',
    signal_id            TEXT,
    correlation_id       UUID NOT NULL,
    model_version        TEXT NOT NULL DEFAULT '',
    feature_version      TEXT NOT NULL DEFAULT '',
    config_hash          TEXT NOT NULL DEFAULT '',
    current_state        TEXT NOT NULL DEFAULT 'INTENT_CREATED',
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_oi_state ON order_intents(current_state)
    WHERE current_state NOT IN ('FILLED', 'CANCELED', 'REJECTED', 'EXPIRED');
CREATE INDEX IF NOT EXISTS idx_oi_team ON order_intents(team_id, strategy_id);

-- ============================================================
-- Risk budgets (for atomic reservation)
-- ============================================================

CREATE TABLE IF NOT EXISTS risk_budgets (
    scope                   TEXT PRIMARY KEY,
    max_gross_exposure      NUMERIC NOT NULL,
    max_notional            NUMERIC NOT NULL,
    max_daily_loss          NUMERIC NOT NULL,
    max_position_count      INTEGER NOT NULL DEFAULT 50,
    current_gross_exposure  NUMERIC NOT NULL DEFAULT 0,
    current_notional        NUMERIC NOT NULL DEFAULT 0,
    current_daily_loss      NUMERIC NOT NULL DEFAULT 0,
    current_position_count  INTEGER NOT NULL DEFAULT 0,
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- Risk reservations
-- ============================================================

CREATE TABLE IF NOT EXISTS risk_reservations (
    reservation_id       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_intent_id      UUID NOT NULL REFERENCES order_intents(order_intent_id),
    scope                TEXT NOT NULL,
    reserved_notional    NUMERIC NOT NULL DEFAULT 0,
    reserved_gross       NUMERIC NOT NULL DEFAULT 0,
    status               TEXT NOT NULL DEFAULT 'ACTIVE',
    expires_at           TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    released_at          TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_res_active ON risk_reservations(status) WHERE status = 'ACTIVE';

-- ============================================================
-- Risk decisions (audit)
-- ============================================================

CREATE TABLE IF NOT EXISTS risk_decisions (
    decision_id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_intent_id      UUID REFERENCES order_intents(order_intent_id),
    team_id              TEXT NOT NULL,
    decision             TEXT NOT NULL,
    reason               TEXT,
    original_qty         NUMERIC,
    approved_qty         NUMERIC,
    risk_snapshot        JSONB DEFAULT '{}',
    decided_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- Venue orders (child orders)
-- ============================================================

CREATE TABLE IF NOT EXISTS venue_orders (
    venue_order_id_internal UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_intent_id      UUID NOT NULL REFERENCES order_intents(order_intent_id),
    venue                TEXT NOT NULL,
    child_seq            INTEGER NOT NULL,
    broker_order_id      TEXT,
    current_state        TEXT NOT NULL DEFAULT 'CHILD_CREATED',
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

CREATE INDEX IF NOT EXISTS idx_vo_state ON venue_orders(current_state)
    WHERE current_state NOT IN ('VENUE_FILLED', 'VENUE_CANCELED', 'VENUE_REJECTED', 'VENUE_EXPIRED');

-- ============================================================
-- Order events (immutable append-only log)
-- ============================================================

CREATE TABLE IF NOT EXISTS order_events (
    event_id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_intent_id      UUID,
    venue_order_id_internal UUID,
    event_type           TEXT NOT NULL,
    broker_order_id      TEXT,
    event_time_utc       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ingest_time_utc      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    payload              JSONB DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_oe_intent ON order_events(order_intent_id);
CREATE INDEX IF NOT EXISTS idx_oe_time ON order_events(event_time_utc);

-- ============================================================
-- Fills
-- ============================================================

CREATE TABLE IF NOT EXISTS fills (
    fill_id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_intent_id      UUID NOT NULL,
    venue_order_id_internal UUID,
    instrument_id        TEXT NOT NULL,
    team_id              TEXT NOT NULL,
    strategy_id          TEXT NOT NULL,
    venue                TEXT NOT NULL,
    side                 TEXT NOT NULL,
    quantity             NUMERIC NOT NULL,
    price                NUMERIC NOT NULL,
    fee                  NUMERIC NOT NULL DEFAULT 0,
    fee_currency         TEXT DEFAULT 'USD',
    expected_fill_price  NUMERIC,
    slippage_bps         NUMERIC,
    fill_time_utc        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ingest_time_utc      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_fills_intent ON fills(order_intent_id);
CREATE INDEX IF NOT EXISTS idx_fills_time ON fills(fill_time_utc);

-- ============================================================
-- Strategy positions
-- ============================================================

CREATE TABLE IF NOT EXISTS strategy_positions (
    team_id              TEXT NOT NULL,
    strategy_id          TEXT NOT NULL,
    instrument_id        TEXT NOT NULL,
    quantity             NUMERIC NOT NULL DEFAULT 0,
    avg_entry_price      NUMERIC,
    realized_pnl         NUMERIC NOT NULL DEFAULT 0,
    cost_basis           NUMERIC NOT NULL DEFAULT 0,
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (team_id, strategy_id, instrument_id)
);

-- ============================================================
-- Reconciliation incidents
-- ============================================================

CREATE TABLE IF NOT EXISTS reconciliation_incidents (
    incident_id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    team_id              TEXT NOT NULL,
    venue                TEXT NOT NULL,
    incident_type        TEXT NOT NULL,
    severity             TEXT NOT NULL DEFAULT 'MEDIUM',
    expected_state       TEXT NOT NULL DEFAULT '',
    actual_state         TEXT NOT NULL DEFAULT '',
    status               TEXT NOT NULL DEFAULT 'open',
    detected_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at          TIMESTAMPTZ,
    resolution_notes     TEXT
);

CREATE INDEX IF NOT EXISTS idx_ri_open ON reconciliation_incidents(status) WHERE status != 'resolved';

-- ============================================================
-- Audit log
-- ============================================================

CREATE TABLE IF NOT EXISTS audit_log (
    log_id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    actor                TEXT NOT NULL DEFAULT 'system',
    action               TEXT NOT NULL,
    entity_type          TEXT,
    entity_id            TEXT,
    details              JSONB DEFAULT '{}',
    logged_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_al_time ON audit_log(logged_at);

-- ============================================================
-- Outbox (DB-first + event publish pattern)
-- ============================================================

CREATE TABLE IF NOT EXISTS outbox (
    outbox_id            BIGSERIAL PRIMARY KEY,
    stream_name          TEXT NOT NULL,
    event_type           TEXT NOT NULL,
    payload              JSONB NOT NULL DEFAULT '{}',
    correlation_id       UUID NOT NULL DEFAULT uuid_generate_v4(),
    idempotency_key      TEXT NOT NULL DEFAULT '',
    published            BOOLEAN NOT NULL DEFAULT FALSE,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at         TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_outbox_pending ON outbox(created_at) WHERE NOT published;
