# ── Strategy Engine (Orchestrator Layer) ──────────────────────
# Receives both decision models + instruments → selects optimal TradePlan.

"""
    orchestrate(state, config, tracker) → TradePlan

The master decision-maker. Compares aggressive and conservative strategies,
applies portfolio context and risk limits, selects the optimal action.
"""
function orchestrate(state::PipelineState, config::PipelineConfig,
                     tracker::PositionTracker)::TradePlan
    bankroll = tracker.bankroll
    regime = detect_regime(state)

    # Get instrument recommendations
    direction_signal = _get_p_refined(state) > 0.5 ? :buy : :sell
    ev = _get_ev(state)
    kelly_r = _get_kelly(state)
    kelly_frac = kelly_r !== nothing && hasproperty(kelly_r, :kelly_half) ? kelly_r.kelly_half : 0.05
    kl_val = 0.0
    if haskey(state.step_results, 9) && hasproperty(state.step_results[9], :kl)
        kl_val = state.step_results[9].kl.kl_divergence
    end

    instruments = select_instruments(
        state.ctx.asset_type, direction_signal,
        _get_p_refined(state) * 100, ev, kelly_frac, regime, kl_val
    )

    # Run both decision models
    aggressive  = decide_aggressive(state, config, instruments, bankroll)
    conservative = decide_conservative(state, config, instruments, bankroll)

    # ── Orchestrator Decision Logic ───────────────────────────
    heat = portfolio_heat(tracker)
    snap = tracker_snapshot(tracker)

    blend_weight = 0.4  # default: slightly conservative
    recommended = :blend
    reasoning_parts = String[]

    # Rule 1: Force conservative if too much exposure
    if heat > 70.0
        recommended = :conservative
        blend_weight = 0.0
        push!(reasoning_parts, "Portfolio heat $(round(heat,digits=0))% > 70% → forced conservative")
    end

    # Rule 2: Force conservative or skip after daily losses
    if snap.daily_pnl < -config.max_daily_loss_pct * tracker.peak_bankroll * 0.6
        recommended = :conservative
        blend_weight = 0.0
        push!(reasoning_parts, "Daily loss approaching limit → forced conservative")
    end

    # Rule 3: Drawdown halt
    if snap.drawdown / 100 > config.max_drawdown_pct * 0.8
        recommended = :skip
        push!(reasoning_parts, "Drawdown $(round(snap.drawdown,digits=1))% near limit → SKIP")
    end

    # Rule 4: Volatile + high KL → conservative
    if occursin("volatile", regime) && kl_val > 0.2
        recommended = :conservative
        blend_weight = 0.0
        push!(reasoning_parts, "Volatile regime + high KL divergence → conservative")
    end

    # Rule 5: Trending + significant AR(1) → lean aggressive
    if occursin("trending", regime) && recommended == :blend
        blend_weight = min(blend_weight + 0.2, 0.8)
        push!(reasoning_parts, "Trending regime → lean aggressive (blend=$(round(blend_weight,digits=1)))")
    end

    # Rule 6: Config override
    if config.force_conservative
        recommended = :conservative
        blend_weight = 0.0
        push!(reasoning_parts, "QE_FORCE_CONSERVATIVE=true → forced conservative")
    end

    # Rule 7: Cooling period → conservative only
    if snap.cooling
        recommended = :conservative
        blend_weight = 0.0
        push!(reasoning_parts, "Cooling period active → conservative only")
    end

    # Rule 8: Strategies disagree on direction → SKIP
    if aggressive.direction != conservative.direction &&
       aggressive.direction != :hold && conservative.direction != :hold
        recommended = :skip
        push!(reasoning_parts, "Strategies disagree ($(aggressive.direction) vs $(conservative.direction)) → SKIP")
    end

    # Rule 9: Both say hold → check if p_refined still suggests a trade
    if aggressive.direction == :hold && conservative.direction == :hold
        p_ref = _get_p_refined(state)
        ev = _get_ev(state)
        if p_ref > 0.55 && ev > 0.03
            # Models are too cautious but signal is there — force conservative buy
            recommended = :conservative
            push!(reasoning_parts, "Both models HOLD but p=$(@sprintf("%.2f", p_ref)) + EV=$(@sprintf("%.2f", ev)) → force conservative")
        else
            recommended = :skip
            push!(reasoning_parts, "Both models HOLD, no strong override signal → SKIP")
        end
    end

    # Rule 10: High edge consistency + low cal gap → boost aggressive
    if kelly_r !== nothing && hasproperty(kelly_r, :edge_consistency) &&
       kelly_r.edge_consistency > 75.0 && recommended == :blend
        if haskey(state.step_results, 5)
            cal = state.step_results[5]
            cal_gap = hasproperty(cal, :calibration_gap) ? abs(cal.calibration_gap) : 1.0
            if cal_gap < 0.05
                blend_weight = min(blend_weight + 0.15, 0.85)
                push!(reasoning_parts, "Strong edge + good calibration → more aggressive")
            end
        end
    end

    # Rule 11: Correlation-adjusted sizing — reduce when correlated with existing positions
    corr_tracker = nothing
    if hasproperty(state.ctx, :weight_cache) && state.ctx.weight_cache !== nothing
        # Check if a correlation tracker is available (set by pipeline loop)
        corr_tracker = get(state.step_results, :correlation_tracker, nothing)
    end
    if corr_tracker !== nothing && corr_tracker isa CorrelationTracker
        existing_assets = collect(keys(tracker.positions))
        if !isempty(existing_assets)
            corr_risk = portfolio_correlation_risk(corr_tracker, vcat(existing_assets, [state.event.asset]))
            if corr_risk > 0.7
                # High correlation → force conservative and reduce size
                if recommended == :blend
                    recommended = :conservative
                    blend_weight = 0.0
                    push!(reasoning_parts, "Correlation risk $(round(corr_risk,digits=2)) > 0.7 → forced conservative")
                end
            elseif corr_risk > 0.4
                # Moderate correlation → scale down blend weight
                blend_weight *= (1.0 - corr_risk * 0.3)
                push!(reasoning_parts, "Correlation $(round(corr_risk,digits=2)) → reduced sizing")
            end
        end
    end

    # ── Build final strategy ──────────────────────────────────
    chosen = if recommended == :skip
        TradeStrategy("Skip", :hold, :limit, :none, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                      0.0, 0.0, 0.0, 0.0, "SKIP: " * join(reasoning_parts, "; "))
    elseif recommended == :aggressive
        aggressive
    elseif recommended == :conservative
        conservative
    else  # :blend
        _blend_strategies(aggressive, conservative, blend_weight, bankroll)
    end

    comparison = StrategyComparison(
        aggressive, conservative, regime, heat,
        recommended, blend_weight, join(reasoning_parts, "; ")
    )

    return TradePlan(
        now(), state.event.asset, state.ctx.asset_type,
        chosen, comparison,
        [(instrument=s.instrument.display_name, score=round(s.score, digits=2),
          rationale=s.rationale) for s in instruments[1:min(5, length(instruments))]],
        state.step_results, chosen.direction != :hold
    )
end

"""Blend two strategies by weight (0.0 = all conservative, 1.0 = all aggressive)."""
function _blend_strategies(agg::TradeStrategy, con::TradeStrategy,
                           w::Float64, bankroll::Float64)::TradeStrategy
    # Use aggressive's direction if it's not :hold
    direction = agg.direction != :hold ? agg.direction : con.direction

    # Blended size
    sized = w * agg.size_fraction + (1 - w) * con.size_fraction
    size_dollars = bankroll * sized

    # Blended hold time
    hold = w * agg.hold_time_hours + (1 - w) * con.hold_time_hours

    # Use aggressive buy type if blend > 0.6, else conservative
    buy_type = w > 0.6 ? agg.buy_type : con.buy_type
    limit_price = w > 0.6 ? agg.limit_price : con.limit_price

    # Use aggressive instrument if blend > 0.5
    inst = w > 0.5 ? agg.instrument_name : con.instrument_name

    # Blended targets
    tp = w * agg.take_profit_pct + (1 - w) * con.take_profit_pct
    sl = w * agg.stop_loss_pct + (1 - w) * con.stop_loss_pct
    conf = w * agg.confidence + (1 - w) * con.confidence

    rationale = "BLEND ($(round(Int, w*100))% aggressive / $(round(Int, (1-w)*100))% conservative): " *
                "size=$(round(sized*100, digits=1))%, hold=$(round(hold, digits=0))h"

    return TradeStrategy(
        "Blend", direction, buy_type, inst, limit_price,
        sized, size_dollars, hold, tp, sl, conf,
        w * agg.expected_return_pct + (1-w) * con.expected_return_pct,
        w * agg.expected_sharpe + (1-w) * con.expected_sharpe,
        tp / max(sl, 0.01), rationale
    )
end
