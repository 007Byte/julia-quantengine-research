# ── Decision & Trade Plan Types ───────────────────────────────

"""A complete trade strategy from one decision model."""
struct TradeStrategy
    model_name::String              # "Aggressive" or "Conservative"
    direction::Symbol               # :buy, :sell, :short, :hold
    buy_type::Symbol                # :market, :limit, :stop_limit
    instrument_name::Symbol         # :spot_buy, :binary_yes, :call_option, etc.
    limit_price::Float64            # for limit/stop_limit orders (0.0 if market)
    size_fraction::Float64          # Kelly fraction used
    size_dollars::Float64           # actual dollar amount
    hold_time_hours::Float64        # recommended hold duration
    take_profit_pct::Float64        # take-profit target (%)
    stop_loss_pct::Float64          # stop-loss level (%)
    confidence::Float64             # 0-100
    expected_return_pct::Float64    # expected return for this trade
    expected_sharpe::Float64        # expected risk-adjusted quality
    risk_reward_ratio::Float64      # take_profit / stop_loss
    rationale::String               # plain-English reasoning
end

"""Comparison of both decision models' outputs."""
struct StrategyComparison
    aggressive::TradeStrategy
    conservative::TradeStrategy
    market_regime::String           # "trending", "mean-reverting", "volatile", "calm"
    portfolio_heat::Float64         # % of bankroll currently at risk
    recommended::Symbol             # :aggressive, :conservative, :blend, :skip
    blend_weight::Float64           # 0.0 (all conservative) to 1.0 (all aggressive)
    reasoning::String               # why this recommendation
end

"""The final actionable trade plan from the Orchestrator."""
struct TradePlan
    timestamp::DateTime
    asset::String
    asset_type::Symbol
    strategy::TradeStrategy         # the chosen strategy
    comparison::StrategyComparison  # both strategies for audit
    instruments_considered::Vector{NamedTuple}  # ranked instruments
    pipeline_results::Dict{Int,Any} # all step results
    execution_ready::Bool           # false if any hard gate failed
end

"""Tracks an open position."""
mutable struct PositionState
    asset::String
    direction::Symbol               # :long, :short
    instrument::Symbol              # :spot_buy, :binary_yes, etc.
    entry_price::Float64
    current_price::Float64
    size_dollars::Float64
    size_fraction::Float64
    entry_time::DateTime
    target_hold_hours::Float64
    take_profit_pct::Float64
    stop_loss_pct::Float64
    pnl::Float64
    pnl_pct::Float64
end

"""Immutable audit trail entry."""
struct AuditEntry
    timestamp::DateTime
    event_id::UInt64
    asset::String
    action::Symbol                  # :trigger, :step_pass, :step_fail, :trade, :skip, :abort
    step_number::Int
    details::Dict{String,Any}
end
