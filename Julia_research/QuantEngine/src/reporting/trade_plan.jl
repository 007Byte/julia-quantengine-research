# ── Trade Plan Generation & Display ──────────────────────────
# Bridges the analysis results into the Decision + Orchestrator layers
# to produce an actionable trade plan with specific instrument, sizing,
# hold time, take-profit, stop-loss, and rationale.

"""
    generate_trade_plan(ctx, composite, config, tracker) → TradePlan

Takes the completed analysis context (all 30 models run) and produces
a full actionable trade plan by running:
  1. Map model results → pipeline step format
  2. Instrument selector → rank available instruments
  3. Decision Layer → aggressive + conservative strategies
  4. Orchestrator → select optimal strategy + instrument

Returns a TradePlan with everything the user needs to act.
"""
function generate_trade_plan(ctx::AnalysisContext, composite::NamedTuple;
                             config::PipelineConfig=load_pipeline_config(),
                             bankroll::Float64=config.initial_bankroll)::TradePlan
    # ── Step 1: Create PipelineState from analysis results ────
    event = PipelineEvent(
        now(), ctx.display_ticker, ctx.asset_type, :analysis,
        Dict{String,Any}("source" => "run_analysis"), ctx.S0, 0.0)
    state = PipelineState(event, ctx)

    # Map ctx.results (keyed by model name) → step_results (keyed by step number)
    # This bridges the analysis output into the pipeline format the decision layer expects

    # Step 2: Event Study
    for (name, r) in ctx.results
        if occursin("Event Study", name)
            state.step_results[2] = (event_study=r, delta_p=0.0, delta_p_pct=0.0)
        end
    end

    # Step 3: Logistic + AR(1)
    logistic_r = nothing; ar1_r = nothing
    for (name, r) in ctx.results
        if occursin("Logistic", name); logistic_r = r; end
        if occursin("AR(1)", name);    ar1_r = r; end
    end
    if logistic_r !== nothing || ar1_r !== nothing
        p_log = logistic_r !== nothing && hasproperty(logistic_r, :probability) ? logistic_r.probability : 0.5
        p_ar1 = ar1_r !== nothing && hasproperty(ar1_r, :probability) ? ar1_r.probability : 0.5
        p_cont = 0.6 * p_log + 0.4 * p_ar1
        state.step_results[3] = (logistic=logistic_r, ar1=ar1_r, p_continuation=p_cont)
    end

    # Step 4: XGBoost
    for (name, r) in ctx.results
        if occursin("XGBoost", name)
            p_step3 = haskey(state.step_results, 3) ? state.step_results[3].p_continuation : 0.5
            p_ref = hasproperty(r, :probability) ? 0.6 * r.probability + 0.4 * p_step3 : p_step3
            state.step_results[4] = (xgboost=r, p_refined=p_ref)
        end
    end

    # Step 5: Calibration
    for (name, r) in ctx.results
        if occursin("Calibration", name)
            state.step_results[5] = r
        end
    end

    # Step 6: Bayesian
    for (name, r) in ctx.results
        if occursin("Bayesian", name)
            state.step_results[6] = r
        end
    end

    # Step 7: EV Gap
    for (name, r) in ctx.results
        if occursin("EV Gap", name)
            state.step_results[7] = r
        end
    end

    # Step 8: Kelly
    for (name, r) in ctx.results
        if occursin("Kelly", name)
            kelly_half = hasproperty(r, :kelly_half) ? r.kelly_half : 0.05
            kelly_full = hasproperty(r, :kelly_full) ? r.kelly_full : kelly_half * 2
            sized = clamp(kelly_half, config.kelly_min_fraction * max(kelly_full, 0.01),
                                      config.kelly_max_fraction * max(kelly_full, 0.01))
            sized = clamp(sized, 0.0, config.max_position_pct)
            state.step_results[8] = (kelly=r, sized_fraction=sized)
        end
    end

    # Step 9: KL/Bregman
    kl_r = nothing; breg_r = nothing
    for (name, r) in ctx.results
        if occursin("KL-Divergence", name); kl_r = r; end
        if occursin("Bregman", name);       breg_r = r; end
    end
    if kl_r !== nothing || breg_r !== nothing
        kl_val = kl_r !== nothing && hasproperty(kl_r, :kl_divergence) ? kl_r.kl_divergence : 0.0
        hedge = kl_val > 0.2 ? "HEDGE: High KL divergence" :
                (breg_r !== nothing && hasproperty(breg_r, :arb_edge) && breg_r.arb_edge > 0.1 ?
                 "ARB OPPORTUNITY" : "NO HEDGE NEEDED")
        state.step_results[9] = (kl=kl_r, bregman=breg_r, hedge_recommendation=hedge)
    end

    # Mark steps as passed
    for k in keys(state.step_results)
        push!(state.passed_steps, k)
    end
    sort!(state.passed_steps)

    # ── Step 2: Run Orchestrator (instruments + decision + strategy) ──
    tracker = PositionTracker(bankroll)
    plan = orchestrate(state, config, tracker)

    return plan
end

"""Print trade plan to console — profit-focused, actionable output."""
function print_trade_plan(plan::TradePlan)
    s = plan.strategy
    c = plan.comparison
    agg = c.aggressive
    con = c.conservative

    println()
    println("╔══════════════════════════════════════════════════════════════╗")
    println("║                    TRADE RECOMMENDATION                     ║")
    println("╠══════════════════════════════════════════════════════════════╣")

    # ── THE RECOMMENDATION ─────────────────────────────────────
    dir_str = s.direction == :buy ? "BUY" : s.direction == :sell ? "SELL" : "HOLD (no trade)"
    @printf("║  %-62s║\n", "$(plan.asset)  —  $(dir_str) at \$$(round(s.limit_price, digits=2))")
    @printf("║  Model confidence: %-42s║\n", "$(round(s.confidence, digits=1))%")
    println("║                                                              ║")

    if s.direction == :hold
        println("║  Models do not show a strong enough edge to trade.          ║")
        println("║  Recommendation: Wait for a better setup.                   ║")
        println("║                                                              ║")
        println("╚══════════════════════════════════════════════════════════════╝")
        println()
        return
    end

    # ── WHAT TO DO ─────────────────────────────────────────────
    hold_str = s.hold_time_hours < 24 ? "$(round(Int, s.hold_time_hours)) hours" :
               "$(round(Int, s.hold_time_hours / 24)) days"
    println("╠══════════════════════════════════════════════════════════════╣")
    println("║  WHAT TO DO:                                                ║")
    order_str = s.buy_type == :market ? "Market order (buy now)" :
        "Limit order at \$$(round(s.limit_price, digits=2))"
    @printf("║    1. Place order: %-41s║\n", order_str)
    @printf("║    2. Invest:      %-41s║\n",
        "\$$(round(s.size_dollars, digits=0)) ($(round(s.size_fraction*100,digits=1))% of bankroll)")
    @printf("║    3. Set TP:      %-41s║\n",
        "sell at \$$(round(s.limit_price * (1 + s.take_profit_pct/100), digits=2)) (+$(round(s.take_profit_pct, digits=1))%)")
    @printf("║    4. Set SL:      %-41s║\n",
        "sell at \$$(round(s.limit_price * (1 - s.stop_loss_pct/100), digits=2)) (-$(round(s.stop_loss_pct, digits=1))%)")
    @printf("║    5. Hold for:    %-41s║\n", hold_str)
    println("║                                                              ║")

    # ── POTENTIAL PROFIT / LOSS ────────────────────────────────
    # Helper to print a strategy's profit projection
    function _print_strategy_profit(label, strat, w)
        pos = strat.size_dollars
        tp_d = pos * strat.take_profit_pct / 100
        sl_d = pos * strat.stop_loss_pct / 100
        exp_d = pos * strat.expected_return_pct / 100
        p_w = clamp(strat.confidence / 100, 0.01, 0.99)
        dir = strat.direction == :buy ? "BUY" : strat.direction == :hold ? "HOLD" : "SELL"
        h = strat.hold_time_hours < 24 ? "$(round(Int, strat.hold_time_hours))h" :
            "$(round(Int, strat.hold_time_hours / 24))d"

        hdr = "$(label) ($(dir), \$$(round(Int, pos)), $(h) hold):"
        @printf("║  %-62s║\n", hdr)
        if strat.direction == :hold
            @printf("║    %-58s║\n", "No trade -- models say wait")
        else
            best  = @sprintf("Best case:   +\$%.2f (+%.1f%%) -- %.0f%% probability", tp_d, strat.take_profit_pct, p_w*100)
            worst = @sprintf("Worst case:  -\$%.2f (-%.1f%%) -- %.0f%% probability", sl_d, strat.stop_loss_pct, (1-p_w)*100)
            avg   = @sprintf("Avg profit:  \$%+.2f per trade (%+.1f%%)", exp_d, strat.expected_return_pct)
            @printf("║    %-58s║\n", best)
            @printf("║    %-58s║\n", worst)
            @printf("║    %-58s║\n", avg)
        end
    end

    println("╠══════════════════════════════════════════════════════════════╣")
    println("║  POTENTIAL PROFIT / LOSS                                    ║")
    println("║                                                              ║")

    # Show the RECOMMENDED strategy first (the blend/chosen one)
    _print_strategy_profit(">>> RECOMMENDED", s, 0)
    println("║                                                              ║")

    # Show aggressive option
    println("║  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─║")
    _print_strategy_profit("Aggressive option", agg, 0)
    println("║                                                              ║")

    # Show conservative option
    println("║  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─║")
    _print_strategy_profit("Conservative option", con, 0)
    println("║                                                              ║")

    # ── CUSTOM AMOUNT PROJECTIONS ──────────────────────────────
    println("╠══════════════════════════════════════════════════════════════╣")
    println("║  IF YOU INVEST MORE:                                        ║")
    println("║                                                              ║")
    println("║    Amount      Best Case     Worst Case    Avg Profit       ║")
    println("║    ────────    ──────────    ──────────    ──────────       ║")
    for amount in [100, 500, 1000, 5000, 10000]
        tp_d = amount * s.take_profit_pct / 100
        sl_d = amount * s.stop_loss_pct / 100
        exp_d = amount * s.expected_return_pct / 100
        row = @sprintf("\$%-9d +\$%-10.0f -\$%-10.0f \$%+.0f", amount, tp_d, sl_d, exp_d)
        @printf("║    %-56s║\n", row)
    end
    println("║                                                              ║")

    # ── WHY THIS TRADE ─────────────────────────────────────────
    println("╠══════════════════════════════════════════════════════════════╣")
    println("║  WHY THIS TRADE:                                            ║")
    @printf("║    Market regime:  %-41s║\n", c.market_regime)
    @printf("║    Risk/Reward:    %-41s║\n", "1 : $(round(s.risk_reward_ratio, digits=2))")
    sharpe_str = s.expected_sharpe > 0 ? @sprintf("%.2f", s.expected_sharpe) : "N/A"
    @printf("║    Sharpe ratio:   %-41s║\n", sharpe_str)
    println("║                                                              ║")
    rat = s.rationale
    while length(rat) > 0
        chunk = rat[1:min(56, length(rat))]
        rat = length(rat) > 56 ? rat[57:end] : ""
        @printf("║    %-58s║\n", chunk)
    end

    println("║                                                              ║")
    println("║  NOT FINANCIAL ADVICE. Use at your own risk.                ║")
    println("╚══════════════════════════════════════════════════════════════╝")
    println()
end

"""Write trade plan to a text file for the output directory."""
function write_trade_plan(plan::TradePlan, dir::String)::String
    s = plan.strategy
    c = plan.comparison
    agg = c.aggressive
    con = c.conservative
    path = joinpath(dir, "$(plan.asset)_trade_plan.txt")

    open(path, "w") do io
        println(io, "=" ^ 60)
        println(io, "  TRADE RECOMMENDATION — $(plan.asset)")
        println(io, "  Generated: $(Dates.format(plan.timestamp, "yyyy-mm-dd HH:MM:SS"))")
        println(io, "=" ^ 60)
        println(io)

        dir_str = s.direction == :buy ? "BUY" : s.direction == :sell ? "SELL" : "HOLD"
        println(io, "  $(plan.asset) — $(dir_str) at \$$(round(s.limit_price, digits=2))")
        println(io, "  Model confidence: $(round(s.confidence, digits=1))%")
        println(io)

        if s.direction == :hold
            println(io, "  Models do not show a strong enough edge to trade.")
            println(io, "  Recommendation: Wait for a better setup.")
        else
            hold_str = s.hold_time_hours < 24 ? "$(round(Int, s.hold_time_hours)) hours" :
                       "$(round(Int, s.hold_time_hours / 24)) days"
            println(io, "  WHAT TO DO:")
            println(io, "    1. Place order: $(s.buy_type == :market ? "Market order" : "Limit at \$$(round(s.limit_price, digits=2))")")
            println(io, "    2. Invest:      \$$(round(s.size_dollars, digits=0)) ($(round(s.size_fraction*100,digits=1))% of bankroll)")
            println(io, "    3. Set TP:      sell at \$$(round(s.limit_price * (1 + s.take_profit_pct/100), digits=2)) (+$(round(s.take_profit_pct, digits=1))%)")
            println(io, "    4. Set SL:      sell at \$$(round(s.limit_price * (1 - s.stop_loss_pct/100), digits=2)) (-$(round(s.stop_loss_pct, digits=1))%)")
            println(io, "    5. Hold for:    $(hold_str)")
            println(io)

            # Print profit projections for a strategy
            function _write_strat(io, label, st)
                pos = st.size_dollars
                tp_d = pos * st.take_profit_pct / 100
                sl_d = pos * st.stop_loss_pct / 100
                exp_d = pos * st.expected_return_pct / 100
                p_w = clamp(st.confidence / 100, 0.01, 0.99)
                h = st.hold_time_hours < 24 ? "$(round(Int, st.hold_time_hours))h" :
                    "$(round(Int, st.hold_time_hours / 24))d"
                dir = st.direction == :buy ? "BUY" : st.direction == :hold ? "HOLD" : "SELL"
                println(io, "  $(label) ($(dir), \$$(round(Int, pos)), $(h) hold):")
                if st.direction == :hold
                    println(io, "    No trade — models say wait")
                else
                    @printf(io, "    Best case:   +\$%.2f (+%.1f%%) — %.0f%% probability\n", tp_d, st.take_profit_pct, p_w*100)
                    @printf(io, "    Worst case:  -\$%.2f (-%.1f%%) — %.0f%% probability\n", sl_d, st.stop_loss_pct, (1-p_w)*100)
                    @printf(io, "    Avg profit:  \$%+.2f per trade (%+.1f%%)\n", exp_d, st.expected_return_pct)
                end
            end

            println(io, "-" ^ 60)
            println(io, "  POTENTIAL PROFIT / LOSS")
            println(io)
            _write_strat(io, ">>> RECOMMENDED", s)
            println(io)
            _write_strat(io, "Aggressive option", agg)
            println(io)
            _write_strat(io, "Conservative option", con)
            println(io)

            println(io, "-" ^ 60)
            println(io, "  IF YOU INVEST MORE:")
            println(io)
            println(io, "    Amount      Best Case     Worst Case    Avg Profit")
            println(io, "    --------    ----------    ----------    ----------")
            for amount in [100, 500, 1000, 5000, 10000]
                tp_d = amount * s.take_profit_pct / 100
                sl_d = amount * s.stop_loss_pct / 100
                exp_d = amount * s.expected_return_pct / 100
                @printf(io, "    \$%-9d +\$%-10.0f -\$%-10.0f \$%+.0f\n",
                    amount, tp_d, sl_d, exp_d)
            end
            println(io)

            println(io, "-" ^ 60)
            println(io, "  WHY THIS TRADE:")
            println(io, "    Market regime:  $(c.market_regime)")
            println(io, "    Risk/Reward:    1 : $(round(s.risk_reward_ratio, digits=2))")
            sharpe_str = s.expected_sharpe > 0 ? @sprintf("%.2f", s.expected_sharpe) : "N/A"
            println(io, "    Sharpe ratio:   $(sharpe_str)")
            println(io, "    $(s.rationale)")
        end

        println(io)
        println(io, "=" ^ 60)
        println(io, "  NOT FINANCIAL ADVICE. Use at your own risk.")
        println(io, "=" ^ 60)
    end

    return path
end
