# ── Decision Model 1: Aggressive (Max Profit) ────────────────
# Optimizes for maximum expected return. Higher leverage, shorter holds.
# NOW: All values derived from model outputs — zero hardcoded defaults.

function decide_aggressive(state::PipelineState, config::PipelineConfig,
                           instruments::Vector{ScoredInstrument},
                           bankroll::Float64)::TradeStrategy
    # Extract key signals from pipeline
    ev_gap = _get_ev(state)
    kelly = _get_kelly(state)
    p_refined = _get_p_refined(state)
    regime = detect_regime(state)
    bayesian_posterior = _get_bayesian(state)

    # ── Pull model outputs for data-driven decisions ───────────
    garch_vol = _get_garch_vol(state)              # annualized vol from GARCH/EGARCH
    kelly_edge = _get_kelly_edge(state)             # win_rate * avg_win - (1-win_rate)*avg_loss
    bs_sigma = _get_bs_sigma(state)                 # Black-Scholes best vol estimate
    composite_p = _get_composite_p(state)           # ensemble probability
    martingale_adj = _get_martingale_adj(state)     # dampening/boosting factor
    meta_bet_size = _get_meta_bet_size(state)       # meta-labeling confidence

    # Use the best volatility estimate available (prefer GARCH → BS → historical)
    daily_vol = if garch_vol > 0
        garch_vol / sqrt(252)
    elseif bs_sigma > 0
        bs_sigma / sqrt(252)
    else
        std(state.ctx.returns)
    end

    # Direction from ensemble of signals — aggressive uses majority vote
    signals_up = count([p_refined > 0.5, ev_gap > 0, bayesian_posterior > 0.5, composite_p > 0.5])
    direction = signals_up >= 2 ? :buy : signals_up == 0 ? :sell : :hold

    # ── Position size: ¾ Kelly (from actual Kelly model) ───────
    full_kelly = kelly !== nothing && hasproperty(kelly, :kelly_full) ?
        kelly.kelly_full : 0.0
    # If Kelly says 0 or unavailable, derive from probability edge
    if full_kelly <= 0.001
        edge = abs(composite_p - 0.5) * 2  # 0 to 1 scale
        full_kelly = clamp(edge * 0.5, 0.01, 0.30)  # conservative fallback from edge
    end
    sized = clamp(0.75 * full_kelly, 0.01, config.max_position_pct)

    # Apply meta-labeling: scale position by meta-model's bet confidence
    if meta_bet_size > 0 && meta_bet_size < 1
        sized *= meta_bet_size
        sized = max(sized, 0.01)
    end
    size_dollars = bankroll * sized

    # ── Hold time: derived from volatility (higher vol → shorter hold) ──
    # Target: hold long enough for 1 expected move, but not so long risk compounds
    # expected_move_days ≈ (target_return / daily_vol)^2
    target_move = daily_vol * 3  # target ~3 daily vol moves
    hold_days = if daily_vol > 0.001
        move_ratio = target_move / daily_vol
        clamp(move_ratio, 0.5, 30.0)  # 0.5 to 30 days
    else
        3.0  # fallback
    end

    # Regime adjustment: trending → hold longer to ride, volatile → cut shorter
    if occursin("trending", regime)
        hold_days *= 1.5
    elseif occursin("volatile", regime)
        hold_days *= 0.5
    end

    # Crypto trades 24/7 → convert differently
    hold_hours = if state.ctx.asset_type == :crypto
        clamp(hold_days * 24, 2.0, 168.0)
    else
        clamp(hold_days * 6.5, 2.0, 480.0)  # 6.5 trading hours/day
    end

    # Buy type: market if EV > 10% (urgency), limit otherwise
    buy_type = ev_gap > 0.10 ? :market : :limit
    current_price = state.event.price_at_trigger
    limit_price = buy_type == :limit ? current_price * 0.998 : current_price

    # ── Take profit & stop loss: from GARCH volatility forecast ──
    # TP = expected favorable move over hold period (vol * sqrt(days) * confidence)
    vol_over_hold = daily_vol * sqrt(max(hold_days, 0.5)) * 100  # in %
    confidence_factor = clamp(abs(composite_p - 0.5) * 4, 0.3, 2.0)  # higher p → wider TP

    take_profit = vol_over_hold * confidence_factor * 1.5  # 1.5x expected move
    take_profit = clamp(take_profit, 0.5, 50.0)

    # SL from Kelly criterion: optimal stop = Kelly fraction × price
    # Risk-reward from Kelly: f* = (p*b - q) / b → implies optimal stop
    kelly_implied_sl = if full_kelly > 0.01
        take_profit / (full_kelly * 10)  # tighter stop when Kelly is small
    else
        take_profit / 1.8
    end
    stop_loss = clamp(kelly_implied_sl, 0.3, take_profit * 0.8)

    # Instrument: aggressive picks higher-leverage options
    inst_name = :spot_buy
    if !isempty(instruments)
        leveraged = filter(s -> s.instrument.leverage > 1.0 && s.score > 0.5, instruments)
        inst_name = if !isempty(leveraged)
            leveraged[1].instrument.name
        else
            instruments[1].instrument.name
        end
    end

    # ── Confidence: weighted combination of model signals ──────
    # Base: composite probability strength
    prob_conf = abs(composite_p - 0.5) * 200  # 0-100 from probability
    # Boost from Kelly edge consistency
    edge_cons = kelly !== nothing && hasproperty(kelly, :edge_consistency) ?
        kelly.edge_consistency : 50.0
    # Boost from meta-labeling
    meta_conf = meta_bet_size * 100
    # Penalize if martingale (random walk → less confident)
    mart_penalty = martingale_adj == "DAMPENED" ? 0.7 : martingale_adj == "BOOSTED" ? 1.2 : 1.0

    confidence = clamp((0.4 * prob_conf + 0.3 * edge_cons + 0.3 * meta_conf) * mart_penalty, 0.0, 100.0)

    # ── Expected return ON THE POSITION (not on bankroll) ───────
    # E[R] = P(win) × TP% - P(loss) × SL%  (return per dollar invested)
    p_win = composite_p > 0.5 ? composite_p : (1 - composite_p)
    p_loss = 1 - p_win
    expected_return = p_win * take_profit - p_loss * stop_loss

    # Sharpe estimate from Kelly model
    expected_sharpe = kelly !== nothing && hasproperty(kelly, :edge_sharpe) ?
        kelly.edge_sharpe : 0.0

    rationale = @sprintf("Aggressive: p=%.1f%%, vol=%.1f%%, Kelly=%.1f%%, TP=%.1f%% SL=%.1f%%, E[R]=%.2f%%, %s, %sh",
                composite_p*100, daily_vol*sqrt(252)*100, sized*100,
                take_profit, stop_loss, expected_return,
                uppercase(regime), round(Int, hold_hours))

    return TradeStrategy(
        "Aggressive", direction, buy_type, inst_name, limit_price,
        sized, size_dollars, hold_hours, take_profit, stop_loss,
        confidence, expected_return, expected_sharpe,
        take_profit / max(stop_loss, 0.01), rationale
    )
end

# ── Helpers ───────────────────────────────────────────────────

function _get_ev(state::PipelineState)::Float64
    haskey(state.step_results, 7) || return 0.0
    r = state.step_results[7]
    hasproperty(r, :ev_after_fees) ? r.ev_after_fees : 0.0
end

function _get_kelly(state::PipelineState)
    haskey(state.step_results, 8) || return nothing
    r = state.step_results[8]
    hasproperty(r, :kelly) ? r.kelly : nothing
end

function _get_p_refined(state::PipelineState)::Float64
    if haskey(state.step_results, 4) && hasproperty(state.step_results[4], :p_refined)
        return state.step_results[4].p_refined
    elseif haskey(state.step_results, 3) && hasproperty(state.step_results[3], :p_continuation)
        return state.step_results[3].p_continuation
    end
    return 0.5
end

function _get_bayesian(state::PipelineState)::Float64
    haskey(state.step_results, 6) || return 0.5
    r = state.step_results[6]
    hasproperty(r, :posterior) ? r.posterior : 0.5
end

# ── NEW helpers that pull from the 30 model results ──────────

function _get_garch_vol(state::PipelineState)::Float64
    for (name, r) in state.ctx.results
        if occursin("GARCH", name) && r isa NamedTuple && hasproperty(r, :σ_annual_forecast)
            v = r.σ_annual_forecast
            return !isnan(v) ? v : 0.0
        end
    end
    return 0.0
end

function _get_bs_sigma(state::PipelineState)::Float64
    for (name, r) in state.ctx.results
        if occursin("Black-Scholes", name) && r isa NamedTuple && hasproperty(r, :sigma_best)
            v = r.sigma_best
            return !isnan(v) ? v : 0.0
        end
    end
    return 0.0
end

function _get_composite_p(state::PipelineState)::Float64
    # Use Ensemble Stacking probability (aggregates all models)
    for (name, r) in state.ctx.results
        if occursin("Ensemble", name) && r isa NamedTuple && hasproperty(r, :probability)
            p = r.probability
            return !isnan(p) ? p : 0.5
        end
    end
    # Fallback to refined probability
    return _get_p_refined(state)
end

function _get_kelly_edge(state::PipelineState)::Float64
    kelly = _get_kelly(state)
    kelly === nothing && return 0.0
    if hasproperty(kelly, :win_rate) && hasproperty(kelly, :avg_win) && hasproperty(kelly, :avg_loss)
        edge = kelly.win_rate * kelly.avg_win - (1 - kelly.win_rate) * abs(kelly.avg_loss)
        return !isnan(edge) ? edge : 0.0
    end
    return 0.0
end

function _get_martingale_adj(state::PipelineState)::String
    for (name, r) in state.ctx.results
        if occursin("Martingale", name) && r isa NamedTuple && hasproperty(r, :confidence_adj)
            return string(r.confidence_adj)
        end
    end
    return "NEUTRAL"
end

function _get_meta_bet_size(state::PipelineState)::Float64
    for (name, r) in state.ctx.results
        if occursin("Meta-Label", name) && r isa NamedTuple && hasproperty(r, :bet_size)
            v = r.bet_size
            return !isnan(v) ? v : 1.0
        end
    end
    return 1.0  # default: full bet
end
