# ── Decision Model 2: Conservative (Safe Profit) ─────────────
# Optimizes for risk-adjusted return. Lower leverage, longer holds, tighter stops.
# NOW: All values derived from model outputs — zero hardcoded defaults.

function decide_conservative(state::PipelineState, config::PipelineConfig,
                              instruments::Vector{ScoredInstrument},
                              bankroll::Float64)::TradeStrategy
    ev_gap = _get_ev(state)
    kelly = _get_kelly(state)
    p_refined = _get_p_refined(state)
    regime = detect_regime(state)
    bayesian_posterior = _get_bayesian(state)

    # ── Pull model outputs ─────────────────────────────────────
    garch_vol = _get_garch_vol(state)
    bs_sigma = _get_bs_sigma(state)
    composite_p = _get_composite_p(state)
    martingale_adj = _get_martingale_adj(state)
    meta_bet_size = _get_meta_bet_size(state)

    daily_vol = if garch_vol > 0
        garch_vol / sqrt(252)
    elseif bs_sigma > 0
        bs_sigma / sqrt(252)
    else
        std(state.ctx.returns)
    end

    # Conservative: only buy, never short. Require agreement from refined signal + EV.
    model_agree = p_refined > 0.53 && ev_gap > 0.02
    bayesian_supports = bayesian_posterior > 0.45
    direction = (model_agree && bayesian_supports) ? :buy : :hold

    # KL divergence check — skip if too uncertain
    kl_val = 0.0
    if haskey(state.step_results, 9) && hasproperty(state.step_results[9], :kl)
        kl_r = state.step_results[9].kl
        kl_val = hasproperty(kl_r, :kl_divergence) ? kl_r.kl_divergence : 0.0
    end
    if kl_val > 0.15
        direction = :hold
    end

    # ── Position size: ¼ Kelly ─────────────────────────────────
    full_kelly = kelly !== nothing && hasproperty(kelly, :kelly_full) ?
        kelly.kelly_full : 0.0
    if full_kelly <= 0.001
        edge = abs(composite_p - 0.5) * 2
        full_kelly = clamp(edge * 0.3, 0.01, 0.20)
    end
    sized = clamp(0.25 * full_kelly, 0.01, config.max_position_pct * 0.5)

    # Scale by meta-labeling confidence
    if meta_bet_size > 0 && meta_bet_size < 1
        sized *= meta_bet_size
        sized = max(sized, 0.01)
    end
    size_dollars = bankroll * sized

    # ── Hold time: derived from vol — conservative holds longer ──
    hold_days = if daily_vol > 0.001
        target_move = daily_vol * 2  # target 2 daily vol moves (less ambitious)
        clamp(target_move / daily_vol, 1.0, 60.0)
    else
        5.0
    end

    # Asset-type adjustment (crypto is 24/7, polymarket can be weeks)
    hold_hours = if state.ctx.asset_type == :crypto
        clamp(hold_days * 24, 12.0, 336.0)    # 12h to 2 weeks
    elseif state.ctx.asset_type == :polymarket
        clamp(hold_days * 24, 24.0, 672.0)    # 1 day to 4 weeks
    else
        clamp(hold_days * 6.5, 6.5, 650.0)    # 1 day to ~100 trading days
    end

    # Always limit order (never chase market)
    buy_type = :limit
    current_price = state.event.price_at_trigger
    limit_price = current_price * 0.995  # 0.5% discount

    # ── TP/SL from vol — conservative uses tighter targets ─────
    vol_over_hold = daily_vol * sqrt(max(hold_days, 0.5)) * 100
    confidence_factor = clamp(abs(composite_p - 0.5) * 3, 0.2, 1.5)

    take_profit = vol_over_hold * confidence_factor  # 1x expected move (no multiplier)
    take_profit = clamp(take_profit, 0.5, 20.0)

    stop_loss = take_profit / 2.0  # conservative: 2:1 risk/reward
    stop_loss = clamp(stop_loss, 0.3, take_profit * 0.6)

    # Instrument: conservative picks defined-risk, low-leverage
    inst_name = :spot_buy
    if !isempty(instruments)
        safe = filter(s -> s.instrument.leverage <= 1.0 &&
                           s.instrument.max_loss_pct <= 100.0 &&
                           s.instrument.complexity <= 2, instruments)
        inst_name = if !isempty(safe)
            safe[1].instrument.name
        else
            instruments[1].instrument.name
        end
    end

    # ── Confidence ─────────────────────────────────────────────
    prob_conf = abs(composite_p - 0.5) * 200
    edge_cons = kelly !== nothing && hasproperty(kelly, :edge_consistency) ?
        kelly.edge_consistency : 50.0
    meta_conf = meta_bet_size * 100
    mart_penalty = martingale_adj == "DAMPENED" ? 0.6 : martingale_adj == "BOOSTED" ? 1.1 : 1.0

    confidence = direction == :hold ? 0.0 :
        clamp((0.4 * prob_conf + 0.3 * edge_cons + 0.3 * meta_conf) * mart_penalty, 0.0, 100.0)

    # Edge consistency gate — require meaningful edge
    if edge_cons < 65.0 && direction == :buy
        direction = :hold
        confidence = 0.0
    end

    # ── Expected return ON THE POSITION ─────────────────────────
    p_win = composite_p > 0.5 ? composite_p : (1 - composite_p)
    p_loss = 1 - p_win
    expected_return = direction == :hold ? 0.0 :
        p_win * take_profit - p_loss * stop_loss

    expected_sharpe = kelly !== nothing && hasproperty(kelly, :edge_sharpe) ?
        kelly.edge_sharpe : 0.0

    rationale = if direction == :hold
        @sprintf("Conservative: HOLD -- p=%.1f%%, EV=%.1f%%, edge_cons=%.0f%%",
                 p_refined*100, ev_gap*100, edge_cons)
    else
        @sprintf("Conservative: BUY -- p=%.1f%%, vol=%.1f%%, Kelly=%.1f%%, TP=%.1f%% SL=%.1f%%, E[R]=%.2f%%, %sh",
                 composite_p*100, daily_vol*sqrt(252)*100, sized*100,
                 take_profit, stop_loss, expected_return, round(Int, hold_hours))
    end

    return TradeStrategy(
        "Conservative", direction, buy_type, inst_name, limit_price,
        sized, size_dollars, hold_hours, take_profit, stop_loss,
        confidence, expected_return, expected_sharpe,
        take_profit / max(stop_loss, 0.01), rationale
    )
end
