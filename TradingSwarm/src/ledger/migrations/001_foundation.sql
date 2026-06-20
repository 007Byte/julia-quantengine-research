-- QuantEngine Phase 0 — Foundation DDL
-- All trade-critical entities, instrument master, and outbox.

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ==========================================================================
-- 1) Instruments
-- ==========================================================================

CREATE TABLE instrument_master (
    instrument_id        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    asset_class          TEXT NOT NULL,
    instrument_type      TEXT NOT NULL,
    base_symbol          TEXT NOT NULL,
    quote_symbol         TEXT,
    underlier_instrument_id UUID REFERENCES instrument_master(instrument_id),
    multiplier           NUMERIC DEFAULT 1,
    tick_size            NUMERIC DEFAULT 0.01,
    lot_size             NUMERIC DEFAULT 1,
    min_order_size       NUMERIC,
    max_order_size       NUMERIC,
    expiry_date          TIMESTAMPTZ,
    strike               NUMERIC,
    option_type          TEXT,
    settlement_type      TEXT,
    trading_calendar     TEXT DEFAULT '24x7',
    currency_exposure    TEXT DEFAULT 'USD',
    metadata             JSONB DEFAULT '{}',
    is_active            BOOLEAN NOT NULL DEFAULT TRUE,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_instrument_asset_class ON instrument_master(asset_class) WHERE is_active;
CREATE INDEX idx_instrument_base_symbol ON instrument_master(base_symbol);

CREATE TABLE symbol_mapping (
    instrument_id        UUID NOT NULL REFERENCES instrument_master(instrument_id),
    venue                TEXT NOT NULL,
    venue_symbol         TEXT NOT NULL,
    venue_metadata       JSONB DEFAULT '{}',
    PRIMARY KEY (instrument_id, venue)
);

CREATE INDEX idx_symbol_mapping_venue ON symbol_mapping(venue, venue_symbol);

-- ==========================================================================
-- 2) Order intents (parent orders)
-- ==========================================================================

CREATE TABLE order_intents (
    order_intent_id      UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
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
    time_in_force        TEXT DEFAULT 'gtc',
    signal_id            UUID,
    correlation_id       UUID NOT NULL,
    model_version        TEXT NOT NULL,
    feature_version      TEXT NOT NULL,
    config_hash          TEXT NOT NULL,
    current_state        TEXT NOT NULL DEFAULT 'intent_created',
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_order_intents_team ON order_intents(team_id, strategy_id);
CREATE INDEX idx_order_intents_state ON order_intents(current_state) WHERE current_state NOT IN ('filled', 'canceled', 'rejected', 'expired');
CREATE INDEX idx_order_intents_instrument ON order_intents(instrument_id);
CREATE INDEX idx_order_intents_correlation ON order_intents(correlation_id);

-- ==========================================================================
-- 3) Risk reservations
-- ==========================================================================

CREATE TABLE risk_reservations (
    reservation_id       UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_intent_id      UUID NOT NULL REFERENCES order_intents(order_intent_id),
    scope                TEXT NOT NULL,
    reserved_notional    NUMERIC NOT NULL DEFAULT 0,
    reserved_gross       NUMERIC NOT NULL DEFAULT 0,
    reserved_margin      NUMERIC NOT NULL DEFAULT 0,
    status               TEXT NOT NULL DEFAULT 'active',
    expires_at           TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    released_at          TIMESTAMPTZ
);

CREATE INDEX idx_reservations_status ON risk_reservations(status) WHERE status = 'active';
CREATE INDEX idx_reservations_intent ON risk_reservations(order_intent_id);
CREATE INDEX idx_reservations_expires ON risk_reservations(expires_at) WHERE status = 'active';

-- ==========================================================================
-- 4) Risk decisions
-- ==========================================================================

CREATE TABLE risk_decisions (
    decision_id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_intent_id      UUID REFERENCES order_intents(order_intent_id),
    team_id              TEXT NOT NULL,
    decision             TEXT NOT NULL,
    reason               TEXT,
    original_qty         NUMERIC,
    approved_qty         NUMERIC,
    risk_snapshot        JSONB NOT NULL DEFAULT '{}',
    decided_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_risk_decisions_intent ON risk_decisions(order_intent_id);

-- ==========================================================================
-- 5) Venue orders (child orders)
-- ==========================================================================

CREATE TABLE venue_orders (
    venue_order_id_internal UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_intent_id      UUID NOT NULL REFERENCES order_intents(order_intent_id),
    venue                TEXT NOT NULL,
    child_seq            INTEGER NOT NULL,
    broker_order_id      TEXT,
    current_state        TEXT NOT NULL DEFAULT 'child_created',
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

CREATE INDEX idx_venue_orders_intent ON venue_orders(order_intent_id);
CREATE INDEX idx_venue_orders_broker ON venue_orders(broker_order_id) WHERE broker_order_id IS NOT NULL;
CREATE INDEX idx_venue_orders_state ON venue_orders(current_state)
    WHERE current_state NOT IN ('filled', 'canceled', 'rejected', 'expired');

-- ==========================================================================
-- 6) Order events (append-only audit)
-- ==========================================================================

CREATE TABLE order_events (
    event_id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_intent_id      UUID REFERENCES order_intents(order_intent_id),
    venue_order_id_internal UUID REFERENCES venue_orders(venue_order_id_internal),
    event_type           TEXT NOT NULL,
    broker_order_id      TEXT,
    event_time_utc       TIMESTAMPTZ NOT NULL,
    ingest_time_utc      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    payload              JSONB DEFAULT '{}'
);

CREATE INDEX idx_order_events_intent ON order_events(order_intent_id);
CREATE INDEX idx_order_events_venue_order ON order_events(venue_order_id_internal);
CREATE INDEX idx_order_events_time ON order_events(event_time_utc);

-- ==========================================================================
-- 7) Fills
-- ==========================================================================

CREATE TABLE fills (
    fill_id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
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

CREATE INDEX idx_fills_intent ON fills(order_intent_id);
CREATE INDEX idx_fills_instrument ON fills(instrument_id);
CREATE INDEX idx_fills_team ON fills(team_id, strategy_id);
CREATE INDEX idx_fills_time ON fills(fill_time_utc);

-- ==========================================================================
-- 8) Strategy-level positions
-- ==========================================================================

CREATE TABLE strategy_positions (
    team_id              TEXT NOT NULL,
    strategy_id          TEXT NOT NULL,
    instrument_id        UUID NOT NULL REFERENCES instrument_master(instrument_id),
    quantity             NUMERIC NOT NULL DEFAULT 0,
    avg_entry_price      NUMERIC,
    realized_pnl         NUMERIC NOT NULL DEFAULT 0,
    cost_basis           NUMERIC NOT NULL DEFAULT 0,
    lots                 JSONB DEFAULT '[]',
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (team_id, strategy_id, instrument_id)
);

-- ==========================================================================
-- 9) Reconciliation incidents
-- ==========================================================================

CREATE TABLE reconciliation_incidents (
    incident_id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    team_id              TEXT NOT NULL,
    venue                TEXT NOT NULL,
    incident_type        TEXT NOT NULL,
    severity             TEXT NOT NULL DEFAULT 'medium',
    expected_state       JSONB NOT NULL DEFAULT '{}',
    actual_state         JSONB NOT NULL DEFAULT '{}',
    status               TEXT NOT NULL DEFAULT 'open',
    detected_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at          TIMESTAMPTZ,
    resolution_notes     TEXT
);

CREATE INDEX idx_recon_incidents_status ON reconciliation_incidents(status)
    WHERE status != 'resolved';
CREATE INDEX idx_recon_incidents_team ON reconciliation_incidents(team_id, venue);

-- ==========================================================================
-- 10) Cash ledger
-- ==========================================================================

CREATE TABLE cash_ledger (
    entry_id             UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    team_id              TEXT NOT NULL,
    entry_type           TEXT NOT NULL,  -- settlement, fee, funding, borrow, dividend, interest, transfer
    currency             TEXT NOT NULL DEFAULT 'USD',
    amount               NUMERIC NOT NULL,
    reference_id         UUID,
    reference_type       TEXT,  -- fill, funding_payment, etc.
    notes                TEXT,
    entry_time_utc       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_cash_ledger_team ON cash_ledger(team_id);
CREATE INDEX idx_cash_ledger_time ON cash_ledger(entry_time_utc);

-- ==========================================================================
-- 11) Config versions
-- ==========================================================================

CREATE TABLE config_versions (
    config_hash          TEXT PRIMARY KEY,
    config_data          JSONB NOT NULL,
    activated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    activated_by         TEXT NOT NULL DEFAULT 'system'
);

-- ==========================================================================
-- 12) Service incidents
-- ==========================================================================

CREATE TABLE service_incidents (
    incident_id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    service_name         TEXT NOT NULL,
    incident_type        TEXT NOT NULL,
    severity             TEXT NOT NULL,
    description          TEXT,
    detected_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at          TIMESTAMPTZ
);

-- ==========================================================================
-- 13) Audit log
-- ==========================================================================

CREATE TABLE audit_log (
    log_id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    actor                TEXT NOT NULL,
    action               TEXT NOT NULL,
    entity_type          TEXT,
    entity_id            TEXT,
    details              JSONB DEFAULT '{}',
    logged_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audit_log_time ON audit_log(logged_at);
CREATE INDEX idx_audit_log_entity ON audit_log(entity_type, entity_id);

-- ==========================================================================
-- 14) Outbox (for DB-first + outbox pattern)
-- ==========================================================================

CREATE TABLE outbox (
    outbox_id            BIGSERIAL PRIMARY KEY,
    stream_name          TEXT NOT NULL,
    envelope_data        JSONB NOT NULL,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    published_at         TIMESTAMPTZ,
    published            BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_outbox_unpublished ON outbox(created_at) WHERE NOT published;

-- ==========================================================================
-- 15) Idempotency store
-- ==========================================================================

CREATE TABLE idempotency_keys (
    idempotency_key      TEXT PRIMARY KEY,
    result_data          JSONB,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at           TIMESTAMPTZ NOT NULL DEFAULT NOW() + INTERVAL '24 hours'
);

CREATE INDEX idx_idempotency_expires ON idempotency_keys(expires_at);
