module QuantEngine

using HTTP, JSON, Dates
using Statistics, LinearAlgebra
using Printf, SpecialFunctions
using StatsBase
using Optim
using Random
using Distributed
using SQLite
using JLD2

# ── Core Infrastructure ──────────────────────────────────────
include("core/types.jl")
include("core/constants.jl")
include("core/config.jl")
include("core/ralph.jl")
include("core/logger.jl")
include("core/model_registry.jl")

# ── Security — Vault (available before pipeline config) ──────
include("security/vault.jl")

# ── Data Pipeline ────────────────────────────────────────────
include("data/ingestion.jl")
include("data/features.jl")
include("data/fracdiff.jl")
include("data/triple_barrier.jl")
include("data/cpcv.jl")

# ── Neural Network Primitives ────────────────────────────────
include("nn/primitives.jl")
include("nn/lstm.jl")
include("nn/gru.jl")
include("nn/mlp.jl")
include("nn/tree.jl")
include("nn/holt_winters.jl")
include("nn/weight_cache.jl")

# ── Individual Models (one file per model) ───────────────────
include("models/m01_lstm.jl")
include("models/m02_gru.jl")
include("models/m03_helformer.jl")
include("models/m04_lstm_garch.jl")
include("models/m05_random_forest.jl")
include("models/m06_lightgbm.jl")
include("models/m07_xgboost.jl")
include("models/m08_conv_lstm.jl")
include("models/m09_bilstm.jl")
include("models/m10_sgd.jl")
include("models/m11_tft.jl")
include("models/m12_ensemble.jl")
include("models/m13_mlp_model.jl")
include("models/m14_garch_egarch.jl")
include("models/m15_rl_dqn.jl")
include("models/m16_lmsr.jl")
include("models/m17_kelly.jl")
include("models/m18_ev_gap.jl")
include("models/m19_kl_divergence.jl")
include("models/m20_bregman.jl")
include("models/m21_bayesian.jl")
include("models/m22_logistic.jl")
include("models/m23_ar1.jl")
include("models/m24_black_scholes.jl")
include("models/m25_fd_pricer.jl")
include("models/m26_term_structure.jl")
include("models/m27_martingale.jl")
include("models/m28_meta_labeling.jl")
include("models/m29_fracdiff_signal.jl")
include("models/m30_triple_barrier_signal.jl")
include("models/m31_kalman_filter.jl")
include("models/m32_time_decay.jl")
include("models/m33_cross_market_arb.jl")
include("models/polymarket_quant.jl")
include("models/polymarket_mm.jl")
include("models/m34_momentum_sentiment.jl")
include("models/m35_macd_strategies.jl")
include("models/m36_funding_arb.jl")
include("models/m37_pairs_trading.jl")
include("models/m38_mean_reversion.jl")
include("models/s01_event_study.jl")
include("models/s02_calibration.jl")

# ── Data Sanitization & Live Feed ────────────────────────────
include("data/sanitizer.jl")
include("data/live_feed.jl")
include("data/websocket_feed.jl")
include("data/binance_feed.jl")
include("data/binance_history.jl")
include("data/polygon_feed.jl")
include("data/x_stream.jl")
include("data/external_signals.jl")
include("data/orderbook.jl")
include("data/cvd.jl")
include("data/polymarket_history.jl")
include("data/minute_processor.jl")
include("data/live_book_feed.jl")
include("data/sentiment_embeddings.jl")

# ── Reporting (basic — no TradePlan deps) ────────────────────
include("reporting/composite.jl")
include("reporting/console_report.jl")
include("reporting/charts.jl")
include("reporting/text_report.jl")

# ── Orchestrator — Model Runner ──────────────────────────────
include("orchestrator/runner.jl")

# ── Execution Interface (no deps on pipeline types) ──────────
include("execution/interface.jl")
include("execution/paper_trade.jl")

# ── Risk Management ──────────────────────────────────────────
include("risk/rate_limiter.jl")

# ── Pipeline Types, Config & Event Bus ───────────────────────
include("pipeline/types.jl")
include("pipeline/config.jl")
include("pipeline/event_bus.jl")

# ── Exchange Implementations (need ExecutionMode + RateLimiter) ──
include("execution/alpaca_exchange.jl")
include("execution/polymarket_exchange.jl")

# ── Decision Layer Types (needed before audit_log) ───────────
include("decision/types.jl")

# ── Execution Audit Log (needs TradePlan from decision/types)
include("execution/audit_log.jl")

# ── Position Tracker & Circuit Breakers (need PositionState from decision/types)
include("risk/position_tracker.jl")
include("risk/circuit_breakers.jl")
include("risk/correlation.jl")
include("risk/slippage.jl")
include("risk/stress_test.jl")

# ── Alpaca Position Reconciliation (needs PositionTracker + AlpacaExchange) ──
include("execution/alpaca_positions.jl")

# ── Trade Instruments Library ────────────────────────────────
include("instruments/types.jl")
include("instruments/polymarket.jl")
include("instruments/crypto.jl")
include("instruments/stocks.jl")
include("instruments/selector.jl")

# ── Pipeline Core (Steps 1-9) ────────────────────────────────
include("pipeline/triggers.jl")
include("pipeline/steps.jl")

# ── Decision Models ──────────────────────────────────────────
include("decision/aggressive.jl")
include("decision/conservative.jl")

# ── Orchestrator — Strategy Engine ───────────────────────────
include("orchestrator/strategy_engine.jl")
include("orchestrator/adaptive_selector.jl")

# ── Storage — Trade Persistence ───────────────────────────────
include("storage/database.jl")
include("storage/queries.jl")

# ── Pipeline Executor & Loop ─────────────────────────────────
include("pipeline/executor.jl")
include("pipeline/loop.jl")
include("pipeline/learning_loop.jl")
include("learning/persistent_brain.jl")

# ── Reporting (depends on TradePlan, PipelineState, orchestrate) ──
include("reporting/pdf_report.jl")
include("reporting/trade_plan.jl")
include("reporting/signal_card.jl")

# ── Scanner & Portfolio Optimizer ─────────────────────────────
include("scanner/scanner.jl")
include("risk/portfolio_optimizer.jl")

# ── Hyperparameter Tuning ─────────────────────────────────────
include("tuning/search_spaces.jl")
include("tuning/bayesian_opt.jl")
include("tuning/ab_testing.jl")

# ── Monitoring & Alerts ───────────────────────────────────────
include("monitoring/dashboard.jl")
include("monitoring/health.jl")
include("monitoring/alerts.jl")

# ── Ensemble Optimizer ───────────────────────────────────────
include("reporting/ensemble_optimizer.jl")

# ── Backtest Engine ──────────────────────────────────────────
include("backtest/types.jl")
include("backtest/backtest_exchange.jl")
include("backtest/metrics.jl")
include("backtest/walk_forward.jl")
include("backtest/report.jl")
include("backtest/polymarket_backtest.jl")
include("backtest/regime_backtest.jl")
include("backtest/cpcv_backtest.jl")

# ── Exports ──────────────────────────────────────────────────
export AnalysisContext, prepare_context, run_all_models, run_model
# Weight Cache
export WeightCache, get_cached_or_train, save_cache!, load_cache!, clear_stale!
export ralph, RalphLog
# Reporting
export generate_charts, generate_pdf, generate_text_report, generate_metrics
export generate_trade_plan, print_trade_plan, write_trade_plan
export fetch_ohlcv, fetch_polymarket_data, validate_ticker, detect_asset_type
export fetch_binance_klines
# Lopez de Prado utilities
export fracdiff, find_min_d, adf_test, compute_fracdiff_features
export triple_barrier_label, triple_barrier_binary, daily_volatility
export cpcv_splits, cpcv_evaluate, purged_splits
export compute_composite, print_console_report
# WebSocket Feeds
export AbstractFeed, FeedConfig, FeedState, feed_snapshot
export BinanceFeed, PolygonFeed, start_feed!
# X (Twitter) Stream
export TweetBuffer, add_tweet!, get_recent_tweets, get_tweet_sentiment
export score_sentiment, detect_tweet_asset, start_x_stream
# Pipeline & Execution Mode
export run_money_printer, load_pipeline_config, PipelineConfig
export ExecutionMode, PAPER, LIVE
export PaperExchange, PositionTracker, AuditLogger
# Alpaca
export AlpacaExchange, alpaca_get_positions, alpaca_get_account
# Polymarket Exchange
export PolymarketExchange, polymarket_get_positions
# Prediction Market Models
export run_kalman_filter, run_time_decay, run_cross_market_arb
export detect_arbitrage, MarketQuote, ArbOpportunity
# Polymarket Quant Layer
export PolyQuote, PolyModelInputs, PolyTradeSignal
export estimate_fair_probability, bayesian_blend, calibrate_probability
export generate_poly_signal, print_poly_signal
export binary_kelly, logit_edge, fee_zone_quality
export buy_ev, sell_ev, break_even_buy, break_even_sell
export is_overpriced_for_buyer, is_underpriced_for_buyer
export CalibrationTable, record_prediction!, calibration_report, derive_bias
# Order Book
export BookLevel, OrderBookSnapshot, OrderBookCache, update_book!, get_book
export compute_book_features, fetch_binance_orderbook, fetch_polymarket_orderbook
# Cross-Asset Correlation
export CorrelationTracker, add_return!, asset_correlation, correlation_matrix
export correlation_adjusted_kelly, portfolio_correlation_risk
# Model Registry (Plugin System)
export ModelRegistry, register_model!, registered_model_ids, run_registered_model
export registered_fast_models, registered_heavy_models, is_registered
# Market Making
export MMConfig, MMQuote, compute_mm_quotes, should_market_make, print_mm_quote
export check_inventory_limits, auto_unwind_size, check_adverse_selection
# Realistic Slippage
export TransactionCosts, realistic_costs, realistic_costs_limit, round_trip_cost_bps, round_trip_cost_fraction
export adjust_returns_for_costs, minimum_edge_required, print_cost_summary
# Stress Test
export run_stress_test, StressTestResult
# Signal Card
export SignalCard, build_signal_card, print_signal_card
# Live Book Feed
export LiveBookManager, update_book_from_feed!, get_live_book_features
export start_binance_book_feed!, start_polymarket_book_feed!
# Sentiment Embeddings
export score_sentiment_v2, FINANCE_LEXICON
# CPCV Validation
export run_cpcv_backtest, CPCVValidationResult
# Momentum-Sentiment Fusion (m34 plugin example)
export run_momentum_sentiment
export MACDConfig, MACDSignal, MACD_CONFIGS, compute_macd, evaluate_macd
export evaluate_all_macd, macd_consensus
export FundingSnapshot, FundingArbPosition, simulate_funding_arb, generate_funding_rates
export CointegrationResult, test_cointegration, compute_spread, simulate_pairs_trading
export MeanRevSignal, compute_rsi, bollinger_bands, zscore_reversion
export evaluate_mean_reversion, mean_rev_consensus
# CVD (Cumulative Volume Delta)
export compute_cvd, cvd_to_features
# Polymarket History
export fetch_polymarket_history, fetch_polymarket_markets, backtest_polymarket_contract
# Regime Backtest
export run_regime_backtest, RegimeBacktestResult
# Learning Loop
export LearningConfig, LearningState, should_retrain, should_update_calibration
export QuantBrain, load_brain, save_brain!, learn_from_trade!, brain_filter
export get_learned_params, print_brain_summary
export record_trade_for_learning!, trigger_retrain!, update_calibration_from_trades!
export learning_status
# Adaptive Model Selector
export AdaptiveEngine, DataProfile, AdaptiveStrategy
export profile_data, select_models, record_model_outcome!
export update_bankroll!, goal_progress, print_goal_progress, model_leaderboard
export dynamic_throttle
# Minute Data Processor
export MinuteBarWindow, MinuteDataManager, add_bar!, ingest_tick!, get_window!, bar_count
export window_snapshot, aggregate_bars, should_analyze, compute_realtime_features
# External Signals
export ExternalSignal, SignalBuffer, add_signal!, get_latest_signal
export fetch_fred_series, create_poll_signal, signals_to_bayesian_evidence
# Polymarket Backtest
export generate_synthetic_polymarket_data, run_polymarket_backtest
export load_polymarket_csv
export reconcile_positions!, alpaca_close_all_positions!
export TradeStrategy, TradePlan, StrategyComparison
export InstrumentCatalog, select_instruments
# Security Vault
export AbstractVault, EnvVault, EncryptedFileVault
export get_secret, has_secret, list_secrets, set_secret!, delete_secret!
export create_vault
# Backtest
# Scanner & Portfolio
export scan_universe, ScanConfig, ScanResult, load_watchlist
export optimize_portfolio, PortfolioOptResult, PortfolioAllocation, print_portfolio
# Backtest
# Event Bus
export PipelineEventBus, create_event_bus, emit_event!, take_event!
export event_bus_stats, close_event_bus!
# Structured Logging
export QELogger, qe_log, set_log_level!
# Alerts
export AlertConfig, create_alert_config, send_alert, alert_trade, alert_circuit_breaker
# Ensemble Optimizer
export learn_ensemble_weights, build_prediction_matrix
# Tuning
export tune_model, TuningResult, get_search_space, tunable_models
# A/B Testing
export ABConfig, ABTest, create_ab_test, record_signal!, arm_stats
export check_ab_winner!, print_ab_results, create_default_ab_test
export save_tuning_result, load_tuning_result, SearchSpace, HyperParam
# Monitoring
export start_health_server
# Backtest
export run_backtest, BacktestConfig, BacktestResult, BacktestExchange
export print_backtest_report, save_backtest_chart, compute_backtest_metrics!

# ── Production Infrastructure (Postgres, OMS, Risk, Reconciler) ──
# These require LibPQ — loaded conditionally to not break existing workflows.
const HAS_LIBPQ = try using LibPQ; true catch; false end
const HAS_UUIDS = try using UUIDs; true catch; false end

if HAS_LIBPQ && HAS_UUIDS
    include("production/postgres.jl")
    include("production/oms.jl")
    include("production/risk_reservations.jl")
    include("production/reconciler.jl")
    include("production/shadow_mode.jl")
    include("production/validation.jl")
    include("production/ntp_check.jl")
    include("production/outbox.jl")
    include("production/pipeline_runner.jl")
    include("execution/binance_exchange.jl")
    include("execution/oanda_exchange.jl")

    # Production exports — Postgres
    export PgPool, pg_connect!, pg_close!, pg_execute, pg_fetch, pg_fetchone, pg_fetchval
    export with_connection, with_transaction, with_locked_transaction, run_migrations!, pg_healthy
    # Production exports — OMS
    export OrderManagementSystem, accept_intent!, transition_intent!, create_child_order!, record_fill!
    export IntentState, VenueOrderState, INTENT_TRANSITIONS, TERMINAL_INTENT_STATES
    export valid_transition, valid_venue_transition, load_unfinished
    # Production exports — Risk
    export evaluate_risk, release_reservation!, expire_stale_reservations!, initialize_risk_budgets!
    export RiskDecision, RiskReservation, RiskLimits, default_risk_limits
    # Production exports — Reconciliation
    export Reconciler, reconcile_all!, startup_reconciliation!, current_interval
    # Production exports — Shadow mode
    export ShadowSession, ShadowSignal, record_price!, update_outcomes!
    export shadow_stats, model_contribution_stats, print_shadow_report
    # Production exports — Validation
    export ValidationLevel, run_validation, print_validation_report, ALL_THRESHOLDS
    # Production exports — NTP
    export check_ntp, ntp_blocks_trading, NTPResult
    # Production exports — Outbox
    export EventBusOutbox, write_with_outbox!, publish_pending!, run_outbox_worker!, stop_outbox_worker!
    # Production exports — Pipeline runner
    export ProductionPipeline, start_production!, stop_production!, production_tick!
    export ALLOWED_SCOPES, ALLOWED_INSTRUMENTS, enforce_scope
    # Binance
    export BinanceExchange, binance_get_positions, binance_get_balances
    export binance_get_funding_rate, binance_verify_margin_mode!
    export binance_start_user_stream!, binance_keepalive_stream!
    # OANDA
    export OandaExchange, oanda_get_positions, oanda_get_account_summary
    export oanda_account_snapshot!, oanda_poll_changes!, oanda_get_financing
else
    @info "Production modules not loaded (LibPQ/UUIDs not available). Install with: Pkg.add(\"LibPQ\")"
end
# Storage
export TradeDatabase, db_record_trade!, db_record_snapshot!, db_record_model_perf!
export db_load_last_state, db_close!
export db_get_trades, db_get_equity_curve, db_get_model_leaderboard
export db_get_daily_pnl, db_get_lifetime_stats

end # module
