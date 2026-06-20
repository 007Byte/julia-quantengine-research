# ── Pipeline Configuration ────────────────────────────────────
# Secure-By-Design: ALL thresholds from ENV, never hardcoded.
# Every parameter has a safe default.

function _env_float(key::String, default::Float64)::Float64
    val = get(ENV, key, "")
    isempty(val) && return default
    parsed = tryparse(Float64, val)
    if parsed === nothing
        @warn "Invalid value for $key: '$val' — using default $default"
        return default
    end
    return parsed
end

function _env_int(key::String, default::Int)::Int
    val = get(ENV, key, "")
    isempty(val) && return default
    parsed = tryparse(Int, val)
    if parsed === nothing
        @warn "Invalid value for $key: '$val' — using default $default"
        return default
    end
    return parsed
end

function _env_bool(key::String, default::Bool)::Bool
    val = lowercase(get(ENV, key, ""))
    isempty(val) && return default
    return val in ("true", "1", "yes")
end

function _env_execution_mode(key::String, default::ExecutionMode)::ExecutionMode
    val = uppercase(strip(get(ENV, key, "")))
    isempty(val) && return default
    if val == "LIVE"
        @warn "QE_EXECUTION_MODE=LIVE — real money trading enabled"
        return LIVE
    end
    return PAPER
end

"""Load pipeline configuration from environment variables with safe defaults."""
function load_pipeline_config()::PipelineConfig
    config = PipelineConfig(
        # Step 1: Triggers
        _env_float("QE_VOLUME_SPIKE_MULT",       3.0),
        _env_float("QE_OB_IMBALANCE_THRESH",     0.70),
        _env_float("QE_PRICE_JUMP_THRESH",       0.03),  # 3% price jump

        # Step 5: Calibration gate
        _env_float("QE_CALIBRATION_GAP_MAX",     0.10),  # 10%

        # Step 7: EV filter
        _env_float("QE_EV_GAP_MIN",             0.05),  # 5%

        # Step 8: Kelly bounds
        _env_float("QE_KELLY_MIN_FRAC",         0.25),  # quarter Kelly
        _env_float("QE_KELLY_MAX_FRAC",         0.50),  # half Kelly

        # Risk limits
        _env_float("QE_MAX_POSITION_PCT",       0.10),  # 10% per position
        _env_float("QE_MAX_DAILY_LOSS_PCT",     0.05),  # 5% daily loss
        _env_float("QE_MAX_DRAWDOWN_PCT",       0.15),  # 15% drawdown halt
        _env_int(  "QE_MAX_CONCURRENT_POS",     5),

        # Operational
        _env_int(  "QE_POLL_INTERVAL_MS",       5000),   # 5 seconds
        _env_int(  "QE_DATA_LOOKBACK_DAYS",     90),
        _env_float("QE_FEE_RATE",              0.02),   # 2%
        _env_float("QE_INITIAL_BANKROLL",      2000.0),

        # Behavior
        _env_bool( "QE_FORCE_CONSERVATIVE",    false),
        _env_int(  "QE_COOLING_PERIOD",        10),      # 10 iterations

        # Execution mode — must be explicitly "LIVE" to enable real trading
        _env_execution_mode("QE_EXECUTION_MODE", PAPER),
    )

    # Validate constraints
    @assert config.kelly_min_fraction >= 0.0 "Kelly min fraction must be >= 0"
    @assert config.kelly_max_fraction <= 1.0 "Kelly max fraction must be <= 1"
    @assert config.kelly_min_fraction <= config.kelly_max_fraction "Kelly min must be <= max"
    @assert config.max_position_pct > 0 && config.max_position_pct <= 1.0
    @assert config.max_daily_loss_pct > 0 && config.max_daily_loss_pct <= 1.0
    @assert config.initial_bankroll > 0 "Bankroll must be positive"

    return config
end

"""Validate that required API keys exist (call before first API use)."""
function validate_api_keys(asset_type::Symbol)
    if asset_type == :polymarket
        key = get(ENV, "POLYMARKET_API_KEY", "")
        if isempty(key)
            @warn "POLYMARKET_API_KEY not set — using public endpoints only (limited)"
        end
    end
    # Crypto and stocks use Yahoo Finance (no key needed)
    # Future: add Polygon, Alpaca, Binance key checks here
end
