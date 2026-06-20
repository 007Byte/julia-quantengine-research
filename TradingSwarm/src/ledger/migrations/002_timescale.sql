-- QuantEngine Phase 0 — TimescaleDB hypertables
-- Run AFTER TimescaleDB extension is installed.

CREATE EXTENSION IF NOT EXISTS timescaledb;

-- Market data (OHLCV bars)
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
CREATE INDEX idx_market_data_inst ON market_data(instrument_id, timeframe, time DESC);

-- Normalized trades
CREATE TABLE normalized_trades (
    time                 TIMESTAMPTZ NOT NULL,
    instrument_id        UUID NOT NULL,
    venue                TEXT NOT NULL,
    price                NUMERIC NOT NULL,
    quantity             NUMERIC NOT NULL,
    side                 TEXT
);

SELECT create_hypertable('normalized_trades', by_range('time'));
CREATE INDEX idx_norm_trades_inst ON normalized_trades(instrument_id, time DESC);

-- Normalized quotes
CREATE TABLE normalized_quotes (
    time                 TIMESTAMPTZ NOT NULL,
    instrument_id        UUID NOT NULL,
    venue                TEXT NOT NULL,
    bid_price            NUMERIC NOT NULL,
    bid_size             NUMERIC NOT NULL,
    ask_price            NUMERIC NOT NULL,
    ask_size             NUMERIC NOT NULL
);

SELECT create_hypertable('normalized_quotes', by_range('time'));

-- Compression policies
SELECT add_compression_policy('normalized_trades', INTERVAL '7 days');
SELECT add_compression_policy('normalized_quotes', INTERVAL '7 days');
SELECT add_compression_policy('market_data', INTERVAL '30 days');

-- Retention policies
SELECT add_retention_policy('normalized_trades', INTERVAL '90 days');
SELECT add_retention_policy('normalized_quotes', INTERVAL '90 days');
SELECT add_retention_policy('market_data', INTERVAL '730 days');
