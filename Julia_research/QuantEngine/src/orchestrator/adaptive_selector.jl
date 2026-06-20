# ── Adaptive Model Selector ───────────────────────────────────
# Automatically selects the best model subset + strategy for each
# asset based on real-time data characteristics. The system learns
# which models perform best in which conditions and adapts.

"""Data profile for an asset — computed from recent bars."""
struct DataProfile
    asset::String
    asset_type::Symbol
    # Regime characteristics
    trend_strength::Float64        # -1 (strong down) to +1 (strong up)
    volatility_regime::Symbol      # :low, :normal, :high, :extreme
    volume_regime::Symbol          # :thin, :normal, :heavy
    momentum_direction::Symbol     # :bullish, :bearish, :neutral
    # Market microstructure
    spread_quality::Symbol         # :tight, :normal, :wide
    cvd_signal::Symbol             # :accumulation, :distribution, :neutral
    # Time characteristics
    hours_to_event::Float64        # for prediction markets (Inf for stocks)
    data_freshness::Float64        # seconds since last update
end

"""Strategy recommendation from the adaptive selector."""
struct AdaptiveStrategy
    model_ids::Vector{Int}         # which models to run
    strategy_type::Symbol          # :trend_follow, :mean_revert, :arb, :mm, :event_driven
    kelly_multiplier::Float64      # scale Kelly up/down based on confidence
    hold_time_multiplier::Float64  # scale hold time
    urgency::Symbol                # :immediate, :normal, :patient
    reasoning::String
end

"""Historical performance record for a model in a specific regime."""
mutable struct ModelPerformanceRecord
    model_id::Int
    regime::Symbol                 # :bull, :bear, :high_vol, :low_vol, :event
    n_predictions::Int
    correct_predictions::Int
    total_pnl::Float64
    avg_edge::Float64
    lock::ReentrantLock
end

"""
Adaptive engine that tracks model performance by regime and
selects optimal models for current conditions.
"""
mutable struct AdaptiveEngine
    performance::Dict{Tuple{Int,Symbol}, ModelPerformanceRecord}
    goal_target::Float64           # $10M target
    current_bankroll::Float64
    start_bankroll::Float64
    start_date::DateTime
    lock::ReentrantLock
end

function AdaptiveEngine(; goal_target::Float64=10_000_000.0,
                         initial_bankroll::Float64=10_000.0)
    AdaptiveEngine(Dict{Tuple{Int,Symbol}, ModelPerformanceRecord}(),
                   goal_target, initial_bankroll, initial_bankroll,
                   now(), ReentrantLock())
end

# ── Data Profiling ────────────────────────────────────────────

"""
    profile_data(prices, returns, volumes; asset, asset_type, cvd_result)

Analyze recent data to determine current regime and characteristics.
This drives model selection — different regimes favor different models.
"""
function profile_data(prices::Vector{Float64}, returns::Vector{Float64},
                       volumes::Vector{Float64};
                       asset::String="", asset_type::Symbol=:stock,
                       high::Union{Vector{Float64},Nothing}=nothing,
                       low::Union{Vector{Float64},Nothing}=nothing,
                       hours_to_event::Float64=Inf)
    n = length(returns)
    if n < 20
        return DataProfile(asset, asset_type, 0.0, :normal, :normal, :neutral,
                           :normal, :neutral, hours_to_event, 0.0)
    end

    # Trend strength: normalized cumulative return over last 20 bars
    recent = returns[max(1,n-19):n]
    cum_ret = sum(recent)
    vol = std(recent)
    trend = vol > 1e-8 ? clamp(cum_ret / (vol * sqrt(20)), -1.0, 1.0) : 0.0

    # Volatility regime
    long_vol = std(returns[max(1,n-59):n])
    vol_ratio = vol / max(long_vol, 1e-8)
    vol_regime = if vol_ratio > 2.0
        :extreme
    elseif vol_ratio > 1.3
        :high
    elseif vol_ratio < 0.6
        :low
    else
        :normal
    end

    # Volume regime
    recent_vol = mean(volumes[max(1,n-4):min(n, length(volumes))])
    avg_vol = mean(volumes[max(1,n-19):min(n, length(volumes))])
    vol_level = avg_vol > 1e-8 ? recent_vol / avg_vol : 1.0
    volume_regime = if vol_level > 2.0
        :heavy
    elseif vol_level < 0.5
        :thin
    else
        :normal
    end

    # Momentum direction
    mom5 = sum(returns[max(1,n-4):n])
    mom20 = sum(returns[max(1,n-19):n])
    momentum = if mom5 > 0.01 && mom20 > 0.01
        :bullish
    elseif mom5 < -0.01 && mom20 < -0.01
        :bearish
    else
        :neutral
    end

    # Spread quality
    spread_q = if high !== nothing && low !== nothing
        avg_spread = mean((high[max(1,n-4):min(n,length(high))] .-
                          low[max(1,n-4):min(n,length(low))]) ./
                         max.(prices[max(1,n-4):n], 0.01))
        avg_spread < 0.005 ? :tight : avg_spread > 0.03 ? :wide : :normal
    else
        :normal
    end

    # CVD signal
    cvd_result = try
        compute_cvd(Float64.(prices), Float64.(volumes); high=high, low=low)
    catch
        nothing
    end
    cvd_sig = if cvd_result !== nothing
        if cvd_result.divergence == :bullish_divergence
            :accumulation
        elseif cvd_result.divergence == :bearish_divergence
            :distribution
        else
            :neutral
        end
    else
        :neutral
    end

    return DataProfile(asset, asset_type, trend, vol_regime, volume_regime,
                       momentum, spread_q, cvd_sig, hours_to_event, 0.0)
end

# ── Model Selection ───────────────────────────────────────────

"""
    select_models(profile, engine) → AdaptiveStrategy

Select optimal model subset and strategy based on data profile.
Uses historical performance records when available, falls back
to expert rules when no data exists.
"""
function select_models(profile::DataProfile, engine::AdaptiveEngine)
    # Base models that always run (core signal)
    core = [14, 17, 18, 21, 22, 23]  # GARCH, Kelly, EV Gap, Bayesian, Logistic, AR(1)

    # Regime-specific model selection
    models = copy(core)
    strategy_type = :trend_follow
    kelly_mult = 1.0
    hold_mult = 1.0
    urgency = :normal
    reasons = String[]

    # ── Asset type routing ──
    if profile.asset_type == :polymarket
        append!(models, [16, 31, 32, 33])  # LMSR, Kalman, Time Decay, Cross-Arb
        strategy_type = :event_driven
        push!(reasons, "Polymarket → event-driven models")

        if profile.hours_to_event < 48
            kelly_mult *= 0.5  # reduce near expiry
            urgency = :immediate
            push!(reasons, "Near expiry → reduced sizing, high urgency")
        end
    else
        append!(models, [5, 6, 7])  # RF, LightGBM, XGBoost (ML ensemble)
        push!(reasons, "Standard asset → ML ensemble")
    end

    # ── Volatility routing ──
    if profile.volatility_regime == :extreme
        kelly_mult *= 0.3
        hold_mult *= 0.5
        append!(models, [27, 29])  # Martingale, FracDiff
        strategy_type = :mean_revert
        push!(reasons, "Extreme vol → mean-revert strategy, ¼ Kelly")
    elseif profile.volatility_regime == :high
        kelly_mult *= 0.6
        append!(models, [24, 25])  # Black-Scholes, FD (vol-sensitive)
        push!(reasons, "High vol → derivatives models, reduced sizing")
    elseif profile.volatility_regime == :low
        kelly_mult *= 1.2
        hold_mult *= 1.5
        push!(reasons, "Low vol → increased sizing, longer holds")
    end

    # ── Trend routing ──
    if abs(profile.trend_strength) > 0.5
        append!(models, [1, 2, 34])  # LSTM, GRU, Momentum-Sentiment
        strategy_type = :trend_follow
        push!(reasons, "Strong trend ($(round(profile.trend_strength, digits=2))) → trend-following models")
    elseif abs(profile.trend_strength) < 0.15
        strategy_type = :mean_revert
        push!(reasons, "Weak trend → mean-reversion approach")
    end

    # ── CVD routing ──
    if profile.cvd_signal == :accumulation
        kelly_mult *= 1.1
        push!(reasons, "CVD accumulation detected → slight size increase")
    elseif profile.cvd_signal == :distribution
        kelly_mult *= 0.8
        push!(reasons, "CVD distribution detected → reduced sizing")
    end

    # ── Volume routing ──
    if profile.volume_regime == :heavy
        urgency = :immediate
        append!(models, [10, 30])  # SGD (adapts fast), Triple-Barrier
        push!(reasons, "Heavy volume → fast-adapting models, immediate urgency")
    elseif profile.volume_regime == :thin
        kelly_mult *= 0.5
        strategy_type = profile.asset_type == :polymarket ? :mm : strategy_type
        push!(reasons, "Thin volume → reduced sizing, consider MM")
    end

    # ── Use historical performance if available ──
    # Safety: core models NEVER get demoted (they're the signal backbone)
    core_protected = Set(core)
    min_trades_for_adaptation = 500  # need 500+ out-of-sample observations
    confidence_floor = 0.55         # if no model exceeds this, use core only

    regime = _profile_to_regime(profile)
    has_any_confident_model = false

    lock(engine.lock) do
        for mid in copy(models)
            key = (mid, regime)
            if haskey(engine.performance, key)
                rec = engine.performance[key]
                if rec.n_predictions >= min_trades_for_adaptation
                    accuracy = rec.correct_predictions / rec.n_predictions
                    if accuracy >= confidence_floor
                        has_any_confident_model = true
                    end
                    if accuracy < 0.45 && !(mid in core_protected)
                        filter!(m -> m != mid, models)
                        push!(reasons, "Model $mid demoted ($(round(accuracy*100))% in $regime, n=$(rec.n_predictions))")
                    elseif accuracy > 0.60
                        push!(reasons, "Model $mid promoted ($(round(accuracy*100))% in $regime, n=$(rec.n_predictions))")
                    end
                end
            end
        end
    end

    # Confidence floor: if no model exceeds 55% accuracy with 500+ trades,
    # fall back to core models only (safer than trusting unproven models)
    total_regime_trades = lock(engine.lock) do
        sum(rec.n_predictions for (k, rec) in engine.performance if k[2] == regime; init=0)
    end
    if total_regime_trades >= min_trades_for_adaptation && !has_any_confident_model
        models = copy(core)
        push!(reasons, "No model exceeds $(confidence_floor*100)% in $regime → core only")
    end

    # Deduplicate
    models = unique(models)

    # Audit log: record selection decision
    qe_log(:info, "adaptive", "Model selection for $(profile.asset)",
           regime=string(regime), strategy=string(strategy_type),
           n_models=length(models), kelly_mult=kelly_mult)

    return AdaptiveStrategy(models, strategy_type, clamp(kelly_mult, 0.1, 2.0),
                             clamp(hold_mult, 0.3, 3.0), urgency,
                             join(reasons, "; "))
end

"""Convert data profile to a regime symbol for performance lookup."""
function _profile_to_regime(profile::DataProfile)::Symbol
    if profile.volatility_regime == :extreme || profile.volatility_regime == :high
        return :high_vol
    elseif profile.trend_strength > 0.3
        return :bull
    elseif profile.trend_strength < -0.3
        return :bear
    elseif profile.asset_type == :polymarket
        return :event
    else
        return :low_vol
    end
end

# ── Performance Recording ─────────────────────────────────────

"""Record a model's prediction outcome for adaptive learning."""
function record_model_outcome!(engine::AdaptiveEngine, model_id::Int,
                                regime::Symbol, correct::Bool, pnl::Float64)
    lock(engine.lock) do
        key = (model_id, regime)
        if !haskey(engine.performance, key)
            engine.performance[key] = ModelPerformanceRecord(
                model_id, regime, 0, 0, 0.0, 0.0, ReentrantLock())
        end
        rec = engine.performance[key]
        rec.n_predictions += 1
        if correct
            rec.correct_predictions += 1
        end
        rec.total_pnl += pnl
        rec.avg_edge = rec.total_pnl / rec.n_predictions
    end
end

# ── Goal Tracking ─────────────────────────────────────────────

"""Update the engine with current bankroll."""
function update_bankroll!(engine::AdaptiveEngine, bankroll::Float64)
    lock(engine.lock) do
        engine.current_bankroll = bankroll
    end
end

"""
    goal_progress(engine) → NamedTuple

Track progress toward the 10M dollar goal.
Returns: completion %, daily required return, projected timeline,
current compound growth rate.
"""
function goal_progress(engine::AdaptiveEngine)
    lock(engine.lock) do
        elapsed_days = max(1.0, Dates.value(now() - engine.start_date) / (1000 * 86400))
        current = engine.current_bankroll
        start = engine.start_bankroll
        target = engine.goal_target

        completion = current / target * 100.0
        total_return = (current / start - 1.0) * 100.0

        # Compound daily growth rate
        daily_growth = (current / start) ^ (1.0 / elapsed_days) - 1.0

        # Projected days to target at current rate
        if daily_growth > 0
            days_remaining = log(target / current) / log(1.0 + daily_growth)
        else
            days_remaining = Inf
        end

        # Required daily return to hit target — use REALISTIC 5-year horizon
        # (NOT 1 year — that would require impossible daily returns)
        realistic_horizon_days = 1825.0  # 5 years
        required_daily = (target / current) ^ (1.0 / realistic_horizon_days) - 1.0

        # Scenario projections (realistic rates based on actual quant fund performance)
        _project(rate) = rate > 0 ? log(target / current) / log(1.0 + rate) : Inf
        conservative_days = _project(0.0003)  # 0.03% daily = ~11% annual (index fund)
        base_days = _project(0.0008)          # 0.08% daily = ~34% annual (good quant)
        optimistic_days = _project(0.0015)    # 0.15% daily = ~72% annual (exceptional)

        return (completion_pct=round(completion, digits=4),
                total_return_pct=round(total_return, digits=2),
                current_bankroll=round(current, digits=2),
                target=target,
                daily_growth_pct=round(daily_growth * 100, digits=4),
                days_elapsed=round(elapsed_days, digits=0),
                days_remaining=round(days_remaining, digits=0),
                required_daily_pct=round(required_daily * 100, digits=4),
                on_track=daily_growth >= required_daily,
                # Scenario projections
                conservative_years=round(conservative_days / 365, digits=1),
                base_years=round(base_days / 365, digits=1),
                optimistic_years=round(optimistic_days / 365, digits=1))
    end
end

"""Print goal progress dashboard."""
function print_goal_progress(engine::AdaptiveEngine)
    g = goal_progress(engine)
    println("  ╔══ GOAL: \$$(Int(g.target)) ════════════════════════════════╗")
    @printf("  ║  Bankroll:      \$%12.2f                         ║\n", g.current_bankroll)
    @printf("  ║  Completion:    %11.4f%%                         ║\n", g.completion_pct)
    @printf("  ║  Total Return:  %+10.2f%%                          ║\n", g.total_return_pct)
    @printf("  ║  Daily Growth:  %10.4f%%                          ║\n", g.daily_growth_pct)
    @printf("  ║  Days Elapsed:  %10.0f                            ║\n", g.days_elapsed)
    @printf("  ║  Days to Goal:  %10.0f                            ║\n", g.days_remaining)
    @printf("  ║  Required/Day:  %10.4f%%                          ║\n", g.required_daily_pct)
    println("  ║  On Track:      $(g.on_track ? "  ✓ YES" : "  ✗ NO")                              ║")
    println("  ╠══════════════════════════════════════════════════╣")
    @printf("  ║  Conservative (11%%/yr):  %5.1f years                ║\n", g.conservative_years)
    @printf("  ║  Base Case   (34%%/yr):  %5.1f years                ║\n", g.base_years)
    @printf("  ║  Optimistic  (72%%/yr):  %5.1f years                ║\n", g.optimistic_years)
    println("  ╚══════════════════════════════════════════════════╝")
end

"""
    dynamic_throttle(engine) → NamedTuple

Loss-averse throttle. NEVER increases risk when losing or behind.
- Losing money → reduce aggressively (protect remaining capital)
- Behind schedule → stay conservative (DO NOT chase losses)
- On track → normal operation
- Ahead of schedule → reduce to protect gains
- Large gains → further reduce to protect compound

Maximum daily risk cap: 2% of bankroll per day, non-overridable.
"""
function dynamic_throttle(engine::AdaptiveEngine)
    g = goal_progress(engine)

    kelly_scale = 1.0
    urgency = :normal
    reasoning = String[]
    max_daily_risk_pct = 2.0  # HARD CAP: never risk more than 2% per day

    # RULE 1: Losing capital → emergency reduction (NEVER chase losses)
    if g.total_return_pct < -15.0
        kelly_scale = 0.15
        urgency = :patient
        push!(reasoning, "Severe drawdown ($(round(g.total_return_pct, digits=1))%%) → minimum sizing")
    elseif g.total_return_pct < -10.0
        kelly_scale = 0.25
        urgency = :patient
        push!(reasoning, "Large drawdown → emergency conservative")
    elseif g.total_return_pct < -5.0
        kelly_scale = 0.50
        urgency = :patient
        push!(reasoning, "Drawdown → reduced sizing")
    elseif g.total_return_pct < 0.0
        kelly_scale = 0.75
        urgency = :patient
        push!(reasoning, "Underwater → conservative sizing")

    # RULE 2: Behind schedule → DO NOT increase risk. Stay at 1.0 or below.
    # The old code throttled UP here. That is mathematically suicidal.
    elseif !g.on_track && g.days_elapsed > 30
        kelly_scale = 0.85
        urgency = :patient
        push!(reasoning, "Behind schedule → conservative (NOT chasing)")

    # RULE 3: Ahead of schedule → protect gains
    elseif g.daily_growth_pct > 0.003  # > 0.3% daily (very strong)
        kelly_scale = 0.60
        urgency = :patient
        push!(reasoning, "Strong growth → protect gains aggressively")
    elseif g.daily_growth_pct > 0.001  # > 0.1% daily (healthy)
        kelly_scale = 0.80
        push!(reasoning, "Healthy growth → slightly conservative")

    # RULE 4: On track, normal
    else
        push!(reasoning, "Normal operation")
    end

    # RULE 5: Protect compound gains when substantially above starting capital
    if g.current_bankroll > engine.start_bankroll * 3.0
        kelly_scale *= 0.85
        push!(reasoning, "3x+ initial → protecting compound")
    end
    if g.current_bankroll > engine.start_bankroll * 10.0
        kelly_scale *= 0.80
        push!(reasoning, "10x+ initial → strong capital protection")
    end

    # HARD FLOOR: kelly_scale can never exceed 1.0 (never more aggressive than base)
    kelly_scale = clamp(kelly_scale, 0.10, 1.0)

    return (kelly_scale=kelly_scale,
            urgency=urgency,
            max_daily_risk_pct=max_daily_risk_pct,
            reasoning=join(reasoning, "; "))
end

"""Get model performance leaderboard for a specific regime."""
function model_leaderboard(engine::AdaptiveEngine, regime::Symbol)
    lock(engine.lock) do
        records = [(model_id=rec.model_id,
                    accuracy=rec.n_predictions > 0 ? rec.correct_predictions / rec.n_predictions : 0.0,
                    n=rec.n_predictions,
                    pnl=rec.total_pnl,
                    avg_edge=rec.avg_edge)
                   for (key, rec) in engine.performance
                   if key[2] == regime && rec.n_predictions >= 5]
        return sort(records, by=r -> -r.accuracy)
    end
end
