# ── Backtest Types ────────────────────────────────────────────

"""Configuration for a walk-forward backtest."""
struct BacktestConfig
    start_idx::Int              # start index in the data (1-based)
    end_idx::Int                # end index in the data
    initial_capital::Float64
    n_folds::Int                # number of walk-forward folds
    train_pct::Float64          # fraction of each fold for training (e.g., 0.8)
    include_costs::Bool
    cost_bps::Float64           # transaction cost in basis points
    slippage_bps::Float64       # simulated slippage in basis points
    use_fast_models_only::Bool  # skip heavy NN models for speed
    use_cpcv::Bool              # use CPCV purged folds instead of naive expanding window
end

function BacktestConfig(;
    start_idx::Int=1,
    end_idx::Int=0,             # 0 = use all data
    initial_capital::Float64=10000.0,
    n_folds::Int=5,
    train_pct::Float64=0.8,
    include_costs::Bool=true,
    cost_bps::Float64=10.0,     # 10 bps = 0.1%
    slippage_bps::Float64=5.0,  # 5 bps = 0.05%
    use_fast_models_only::Bool=false,
    use_cpcv::Bool=false
)
    @assert 0.5 <= train_pct <= 0.95 "train_pct must be in [0.5, 0.95]"
    @assert n_folds >= 2 "need at least 2 folds"
    @assert initial_capital > 0 "initial capital must be positive"
    BacktestConfig(start_idx, end_idx, initial_capital, n_folds, train_pct,
                   include_costs, cost_bps, slippage_bps, use_fast_models_only, use_cpcv)
end

"""Record of a single simulated trade."""
struct BacktestTrade
    fold::Int
    entry_idx::Int
    exit_idx::Int
    direction::Symbol           # :long or :short
    entry_price::Float64
    exit_price::Float64
    size_dollars::Float64
    pnl::Float64
    pnl_pct::Float64
    hold_bars::Int
    exit_reason::Symbol         # :take_profit, :stop_loss, :time_expired, :end_of_fold
    signal_confidence::Float64
    strategy_name::String
end

"""Complete results of a backtest run."""
mutable struct BacktestResult
    ticker::String
    config::BacktestConfig
    trades::Vector{BacktestTrade}
    equity_curve::Vector{Float64}    # one per bar in test periods
    equity_dates::Vector{DateTime}   # aligned dates
    daily_returns::Vector{Float64}
    # Summary metrics (computed after run)
    total_return::Float64
    sharpe::Float64
    sortino::Float64
    max_drawdown::Float64
    max_drawdown_duration::Int       # bars
    calmar::Float64
    profit_factor::Float64
    win_rate::Float64
    n_trades::Int
    avg_hold_bars::Float64
    # Benchmark comparison
    buy_hold_return::Float64
    buy_hold_sharpe::Float64
    buy_hold_max_dd::Float64
end

function BacktestResult(ticker::String, config::BacktestConfig)
    BacktestResult(ticker, config,
        BacktestTrade[], Float64[], DateTime[], Float64[],
        0.0, 0.0, 0.0, 0.0, 0, 0.0, 0.0, 0.0, 0, 0.0,
        0.0, 0.0, 0.0)
end
