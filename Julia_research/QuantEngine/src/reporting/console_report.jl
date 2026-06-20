# ── Console Report ────────────────────────────────────────────

function print_console_report(ctx::AnalysisContext, composite::NamedTuple)
    println("╔══════════════════════════════════════════════════════════════╗")
    println("║  $(rpad(ctx.display_ticker, 10)) QUANTITATIVE ANALYSIS REPORT              ║")
    println("║  30-Model Engine | $(Dates.format(Dates.today(), "yyyy-mm-dd"))                        ║")
    println("╚══════════════════════════════════════════════════════════════╝")
    println()

    println("  ★ COMPOSITE DECISION: $(composite.direction)")
    @printf("    Score: %+.3f | Confidence: %d%% | Bull/Bear: %.0f%%/%.0f%%\n",
        composite.score, composite.confidence, composite.bull_pct, 100-composite.bull_pct)
    n_pass = count(r -> r.success, ctx.log)
    @printf("    Aggregate p(up): %.3f | Models: %d/%d passed | %d directional\n",
        composite.p_true, n_pass, length(ctx.log), composite.n_directional)
    println()

    # RALPH Summary
    println("  ── RALPH VALIDATION SUMMARY ──────────────────────────────")
    total_time = sum(r.time_ms for r in ctx.log)
    @printf("    Total model time: %.1f ms (%.2f sec)\n", total_time, total_time/1000)
    for rl in ctx.log
        status = rl.success ? "✓" : "✗"
        @printf("    %s  %-40s  %8.1f ms  %s\n", status, rl.model_name, rl.time_ms, rl.message)
    end
    println()

    # Model Results Table
    println("  ── MODEL RESULTS ─────────────────────────────────────────")
    println("  #   Model                          Direction  Prob   Accuracy")
    println("  ─── ────────────────────────────── ───────── ────── ────────")
    for (name, r) in sort(collect(ctx.results), by=x->x.first)
        if r isa NamedTuple
            dir = hasproperty(r, :direction) ? r.direction : "-"
            prob = hasproperty(r, :probability) ? @sprintf("%.3f", r.probability) : "-"
            acc = hasproperty(r, :accuracy) && !isnan(r.accuracy) ? @sprintf("%.1f%%", r.accuracy*100) : "-"
            num = split(name, ".")[1]
            @printf("  %-3s %-34s %-9s %6s %8s\n", num, name, dir, prob, acc)
        end
    end
    println()

    # Key Insights
    println("  ── KEY INSIGHTS ──────────────────────────────────────────")
    for (name, r) in ctx.results
        if r isa NamedTuple
            if occursin("Kelly", name) && hasproperty(r, :kelly_half)
                @printf("    Kelly ½ (recommended): %.1f%% of portfolio\n", r.kelly_half*100)
            end
            if occursin("EV Gap", name) && hasproperty(r, :ev)
                @printf("    EV Gap: %.3f (after fees: %.3f) — %s\n", r.ev, r.ev_after_fees, r.trade_signal)
            end
            if occursin("AR(1)", name) && hasproperty(r, :regime)
                @printf("    AR(1): β=%.4f — %s\n", r.beta, r.regime)
            end
            if occursin("Bayesian", name) && hasproperty(r, :posterior)
                @printf("    Bayesian: %.3f → %.3f — %s\n", r.prior, r.posterior, r.direction)
            end
            if occursin("Black-Scholes", name) && hasproperty(r, :vol_signal)
                @printf("    BS Greeks: Δ=%.3f Γ=%.4f Θ=%.2f V=%.2f — %s\n",
                    r.delta_call, r.gamma, r.theta_call, r.vega, r.vol_signal)
            end
            if occursin("Crank-Nicolson", name) && hasproperty(r, :fd_vs_bs_error)
                cn_status = r.grid_converged ? "CONVERGED" : "NOT CONVERGED"
                @printf("    FD Pricer: Call=%.2f | American Put=%.2f | BS Error=%.4f%% — %s\n",
                    r.fd_price_call, r.american_put, r.fd_vs_bs_error*100, cn_status)
            end
            if occursin("Term Structure", name) && hasproperty(r, :rate_regime)
                @printf("    Rate Regime: %s (beta1=%.4f) — Bond10y=%.4f\n",
                    r.rate_regime, r.ns_beta1, r.bond_10y_price)
            end
            if occursin("Martingale", name) && hasproperty(r, :regime)
                @printf("    Martingale: %s (predictability=%.0f%%) — %s\n",
                    r.regime, r.predictability*100, r.confidence_adj)
            end
            if occursin("Meta-Label", name) && hasproperty(r, :bet_size)
                @printf("    Meta-Label: bet_size=%.2f — %s (primary: %s @ %.3f)\n",
                    r.bet_size, r.direction, r.primary_direction, r.primary_probability)
            end
            if occursin("Fractional Diff", name) && hasproperty(r, :d_optimal)
                @printf("    FracDiff: d=%.2f (memory=%.0f%%) — %s\n",
                    r.d_optimal, r.memory_preserved*100, r.direction)
            end
            if occursin("Triple-Barrier", name) && hasproperty(r, :regime)
                @printf("    Triple-Barrier: %s (↑%.0f%% ↓%.0f%% →%.0f%%)\n",
                    r.regime, r.upper_hit_rate*100, r.lower_hit_rate*100, r.expiry_rate*100)
            end
        end
    end
    println()
end
