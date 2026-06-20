# ── Pipeline Steps 2-9 — Sequential RALPH-Validated Chain ────
# Each step wrapped in RALPH. Hard gates abort. Soft gates degrade gracefully.

"""Run one pipeline step with RALPH validation and circuit breaking."""
function run_step!(step_fn::Function, state::PipelineState, step_num::Int,
                   step_name::String; verbose::Bool=true)::Bool
    state.aborted && return false

    result = ralph(step_fn, "Step $step_num: $step_name", state.ctx;
                   max_retries=1, verbose=verbose)

    if result === nothing
        if step_num in REQUIRED_STEPS
            state.aborted = true
            state.abort_reason = "Required step $step_num ($step_name) failed RALPH validation"
            return false
        else
            verbose && @warn "Optional step $step_num ($step_name) failed — continuing degraded"
            return true
        end
    end

    lock(state.lock) do
        state.step_results[step_num] = result
        push!(state.passed_steps, step_num)
    end
    return true
end

"""Convert pipeline step results to the Dict format existing models expect."""
function build_results_dict(state::PipelineState)::Dict{String,Any}
    results = Dict{String,Any}()
    if haskey(state.step_results, 3)
        s3 = state.step_results[3]
        haskey(s3, :logistic) && (results["22. Logistic Regression (Post-Trade)"] = s3.logistic)
        haskey(s3, :ar1)      && (results["23. AR(1) Autoregression"] = s3.ar1)
    end
    if haskey(state.step_results, 4) && haskey(state.step_results[4], :xgboost)
        results["7. XGBoost"] = state.step_results[4].xgboost
    end
    if haskey(state.step_results, 6)
        results["21. Bayesian Update"] = state.step_results[6]
    end
    return results
end

"""Combine logistic regression and AR(1) continuation signals."""
function combine_continuation(logistic, ar1)::Float64
    p_log = hasproperty(logistic, :probability) ? logistic.probability : 0.5
    p_ar1 = hasproperty(ar1, :probability) ? ar1.probability : 0.5

    # Logistic gets 0.6 weight (more features), AR(1) gets 0.4 (simpler but robust)
    w_log = 0.6; w_ar1 = 0.4

    # If AR(1) says mean-reversion but logistic says continuation → equal weight
    if hasproperty(ar1, :regime) && occursin("MEAN-REVERSION", string(ar1.regime))
        if hasproperty(logistic, :continuation_signal) && logistic.continuation_signal
            w_log = 0.5; w_ar1 = 0.5
        end
    end

    return clamp(w_log * p_log + w_ar1 * p_ar1, 0.01, 0.99)
end

"""Compute price change since trigger for event study context."""
function compute_delta_p(prices::Vector{Float64}, event::PipelineEvent)::Float64
    if length(prices) >= 5
        return (event.price_at_trigger - prices[end-4]) / max(prices[end-4], 1e-8)
    elseif length(prices) >= 2
        return (event.price_at_trigger - prices[end-1]) / max(prices[end-1], 1e-8)
    end
    return 0.0
end

"""Determine market regime from pipeline step results."""
function detect_regime(state::PipelineState)::String
    # From AR(1) if available
    if haskey(state.step_results, 3) && haskey(state.step_results[3], :ar1)
        ar1 = state.step_results[3].ar1
        if hasproperty(ar1, :regime)
            regime_str = string(ar1.regime)
            if occursin("MOMENTUM", regime_str)
                return "trending"
            elseif occursin("MEAN-REVERSION", regime_str)
                return "mean-reverting"
            end
        end
    end

    # From GARCH volatility if available (via step results or ctx)
    # High vol → volatile regime
    if length(state.ctx.returns) > 20
        recent_vol = std(state.ctx.returns[max(1,end-19):end])
        hist_vol = std(state.ctx.returns)
        if recent_vol > hist_vol * 1.5
            return "volatile"
        end
    end

    return "calm"
end

"""
    run_pipeline_steps!(state, config) → Bool (true if all required steps passed)

Execute Steps 2-9 of the pipeline sequentially with RALPH validation.
"""
function run_pipeline_steps!(state::PipelineState, config::PipelineConfig;
                             verbose::Bool=true)::Bool

    # ── Step 2: Event Study + Δp ──────────────────────────────
    run_step!(state, 2, "Event Study + Δp"; verbose) do
        es = run_event_study(state.ctx.returns, state.ctx.prices)
        delta_p = compute_delta_p(state.ctx.prices, state.event)
        (event_study=es, delta_p=delta_p, delta_p_pct=delta_p*100)
    end

    # ── Step 3: Logistic Regression + AR(1) ───────────────────
    run_step!(state, 3, "Logistic + AR(1)"; verbose) do
        logistic = run_logistic_regression(state.ctx.returns,
                       state.ctx.prices[2:end], state.ctx.volumes[2:end])
        ar1 = run_ar1(state.ctx.returns)
        p_cont = combine_continuation(logistic, ar1)
        (logistic=logistic, ar1=ar1, p_continuation=p_cont)
    end

    # ── Step 4: XGBoost Refinement ────────────────────────────
    run_step!(state, 4, "XGBoost Refinement"; verbose) do
        xgb = run_xgboost(state.ctx.X_train, state.ctx.y_train,
                           state.ctx.X_test, state.ctx.y_test,
                           state.ctx.returns, state.ctx.asset_type)
        p_step3 = get(state.step_results, 3, (p_continuation=0.5,)).p_continuation
        p_refined = 0.6 * xgb.probability + 0.4 * p_step3
        (xgboost=xgb, p_refined=p_refined)
    end

    # ── Step 5: Calibration Gate ★ HARD GATE ★ ────────────────
    run_step!(state, 5, "Calibration Gate"; verbose) do
        intermediate = build_results_dict(state)
        cal = run_calibration_check(state.ctx.returns, intermediate)
        if hasproperty(cal, :is_calibrated) && !cal.is_calibrated
            gap = hasproperty(cal, :calibration_gap) ? abs(cal.calibration_gap) : 1.0
            if gap > config.calibration_gap_max
                state.aborted = true
                state.abort_reason = "Calibration gap $(round(gap, digits=3)) > $(config.calibration_gap_max)"
            end
        end
        cal
    end
    state.aborted && return false

    # ── Step 6: Bayesian Update ───────────────────────────────
    run_step!(state, 6, "Bayesian Update"; verbose) do
        intermediate = build_results_dict(state)
        run_bayesian(state.ctx.returns, intermediate)
    end

    # ── Step 7: EV Gap Filter ★ HARD GATE ★ ──────────────────
    run_step!(state, 7, "EV Gap Filter"; verbose) do
        intermediate = build_results_dict(state)
        mp = state.event.price_at_trigger
        if state.ctx.asset_type != :polymarket
            mp = 0.52  # stock/crypto baseline
        end
        ev = run_ev_gap(intermediate, mp, state.ctx.asset_type)
        if hasproperty(ev, :ev_after_fees) && ev.ev_after_fees < config.ev_gap_min
            state.aborted = true
            state.abort_reason = "EV gap $(round(ev.ev_after_fees, digits=3)) < $(config.ev_gap_min)"
        end
        ev
    end
    state.aborted && return false

    # ── Step 8: Kelly Sizing ──────────────────────────────────
    run_step!(state, 8, "Kelly Sizing"; verbose) do
        kelly = run_kelly(state.ctx.returns)
        raw = hasproperty(kelly, :kelly_half) ? kelly.kelly_half : 0.0
        full = hasproperty(kelly, :kelly_full) ? kelly.kelly_full : raw * 2
        sized = clamp(raw, config.kelly_min_fraction * max(full, 0.01),
                           config.kelly_max_fraction * max(full, 0.01))
        sized = clamp(sized, 0.0, config.max_position_pct)
        (kelly=kelly, sized_fraction=sized)
    end

    # ── Step 9: KL/Bregman Arb/Hedge ─────────────────────────
    run_step!(state, 9, "KL/Bregman Arb/Hedge"; verbose) do
        intermediate = build_results_dict(state)
        kl = run_kl_divergence(state.ctx.returns, intermediate)
        bregman = run_bregman(state.ctx.returns, intermediate)

        kl_val = hasproperty(kl, :kl_divergence) ? kl.kl_divergence : 0.0
        hedge = if kl_val > 0.2
            "HEDGE: High KL divergence ($(round(kl_val, digits=3)))"
        elseif hasproperty(bregman, :arb_edge) && bregman.arb_edge > 0.1
            "ARB: Bregman edge $(round(bregman.arb_edge, digits=3))"
        else
            "NO HEDGE NEEDED"
        end

        (kl=kl, bregman=bregman, hedge_recommendation=hedge)
    end

    return !state.aborted
end
