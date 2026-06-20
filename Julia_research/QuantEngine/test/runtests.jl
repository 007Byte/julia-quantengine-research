using Test
using QuantEngine
using QuantEngine: _safe_value, combinations_indices,
    sanitize_price, sanitize_volume, sanitize_returns, sanitize_polymarket, sanitize_ohlcv,
    compute_features, make_sequences,
    run_kelly, run_garch_egarch,
    can_open_position, open_position!, close_position!, portfolio_heat, tracker_snapshot,
    maybe_reset_daily!, preflight_risk_check, post_trade_risk_check!,
    tick_cooling!, check_position_exits!,
    RateLimiter, try_request!, wait_for_slot!, create_rate_limiters,
    AuditLogger, audit_log!, audit_trade!,
    fracdiff_weights, fracdiff, adf_test, find_min_d, compute_fracdiff_features,
    purged_splits, cpcv_splits, cpcv_evaluate,
    ralph, RalphLog, AnalysisContext,
    PositionState, PositionTracker,
    compute_composite,
    BacktestExchange, BacktestConfig, BacktestResult,
    compute_backtest_metrics!, set_bar!,
    place_order, get_balance, get_current_price, cancel_order, get_open_orders,
    _compute_max_drawdown, _generate_folds, BacktestTrade,
    TradeDatabase, db_record_trade!, db_record_snapshot!, db_record_model_perf!,
    db_load_last_state, db_close!,
    db_get_trades, db_get_equity_curve, db_get_model_leaderboard,
    db_get_daily_pnl, db_get_lifetime_stats,
    AlpacaExchange, alpaca_get_positions, alpaca_get_account,
    reconcile_positions!, AbstractExchange,
    FeedConfig, FeedState, feed_snapshot, feed_message_received!,
    feed_connected!, feed_disconnected!, feed_error!,
    BinanceFeed, PolygonFeed,
    _binance_to_ticker, _ticker_to_binance, _process_binance_message!,
    RollingHistory, get_recent_prices, update_history!,
    EnvVault, EncryptedFileVault, get_secret, has_secret, list_secrets,
    set_secret!, delete_secret!, create_vault, _derive_key, _xor_crypt,
    ScanResult, ScanConfig, scan_universe, load_watchlist, N_MODELS,
    optimize_portfolio, PortfolioOptResult, PortfolioAllocation,
    SearchSpace, HyperParam, sample_point, normalize_point, denormalize_point,
    get_search_space, tunable_models, TuningResult, TuningTrial,
    save_tuning_result, load_tuning_result, _suggest_next,
    _normal_pdf, _normal_cdf,
    _handle_health, _handle_metrics, start_health_server,
    ABConfig, ABTest, create_ab_test, record_signal!, arm_stats,
    check_ab_winner!, create_default_ab_test,
    get_cached_for_incremental, NEGATORS
using Dates, Random, Statistics, JSON, LinearAlgebra

@testset "QuantEngine" begin
    @testset "Input Validation"    begin include("test_validation.jl") end
    @testset "Data Sanitizer"      begin include("test_sanitizer.jl") end
    @testset "Feature Engineering"  begin include("test_features.jl") end
    @testset "Composite Signal"     begin include("test_composite.jl") end
    @testset "Kelly Criterion"      begin include("test_kelly.jl") end
    @testset "GARCH/EGARCH"         begin include("test_garch.jl") end
    @testset "Circuit Breakers"     begin include("test_circuit_breakers.jl") end
    @testset "Position Tracker"     begin include("test_position_tracker.jl") end
    @testset "Rate Limiter"         begin include("test_rate_limiter.jl") end
    @testset "Audit Logger"         begin include("test_audit_log.jl") end
    @testset "FracDiff"             begin include("test_fracdiff.jl") end
    @testset "CPCV"                 begin include("test_cpcv.jl") end
    @testset "RALPH"                begin include("test_ralph.jl") end
    @testset "Backtest Engine"      begin include("test_backtest.jl") end
    @testset "Database"             begin include("test_database.jl") end
    @testset "Alpaca Exchange"      begin include("test_alpaca.jl") end
    @testset "WebSocket Feeds"      begin include("test_websocket.jl") end
    @testset "Vault"                begin include("test_vault.jl") end
    @testset "X Stream"             begin include("test_x_stream.jl") end
    @testset "Scanner & Portfolio"  begin include("test_scanner.jl") end
    @testset "Tuning"               begin include("test_tuning.jl") end
    @testset "Monitoring"           begin include("test_monitoring.jl") end
    @testset "Weight Cache"         begin include("test_weight_cache.jl") end
    @testset "Event Bus"            begin include("test_event_bus.jl") end
    @testset "Ensemble Optimizer"   begin include("test_ensemble_optimizer.jl") end
    @testset "Alerts"               begin include("test_alerts.jl") end
    @testset "Prediction Markets"   begin include("test_prediction_markets.jl") end
    @testset "Profit Boosters"      begin include("test_profit_boosters.jl") end
    @testset "Polymarket Quant"     begin include("test_polymarket_quant.jl") end
    @testset "Advanced Features"    begin include("test_advanced_features.jl") end
    @testset "Final Features"       begin include("test_final_features.jl") end
    @testset "Adaptive Selector"    begin include("test_adaptive.jl") end
    @testset "Hardening"            begin include("test_hardening.jl") end
    @testset "Launch Safety"        begin include("test_launch_safety.jl") end
    @testset "Signal Card"          begin include("test_signal_card.jl") end
end
