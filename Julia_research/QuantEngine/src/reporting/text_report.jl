# ── Text Report + Metrics File ────────────────────────────────

"""Generate plain-text analysis report. Returns file path."""
function generate_text_report(ctx::AnalysisContext, composite::NamedTuple)::String
    dir = ctx.output_dir
    tk  = ctx.display_ticker
    report_path = joinpath(dir, "$(tk)_report.txt")

    open(report_path, "w") do io
        println(io, "=" ^ 72)
        println(io, "  $tk — QUANTITATIVE ANALYSIS REPORT")
        println(io, "  Generated: $(Dates.now())")
        println(io, "  Price: \$$(round(ctx.S0, digits=2)) | Asset: $(ctx.asset_type)")
        if ctx.asset_type != :polymarket && !isempty(ctx.dates)
            println(io, "  Data: $(Date(ctx.dates[1])) to $(Date(ctx.dates[end])) ($(length(ctx.prices)) days)")
        end
        println(io, "=" ^ 72)
        println(io)

        # Decision
        println(io, "COMPOSITE DECISION: $(composite.direction)")
        println(io, "-" ^ 72)
        @printf(io, "Score: %+.3f | Confidence: %d%% | p(up): %.3f\n",
            composite.score, composite.confidence, composite.p_true)
        @printf(io, "Bull/Bear: %.0f%% / %.0f%% | Models: %d\n",
            composite.bull_pct, 100-composite.bull_pct, composite.n_models)
        println(io)

        # RALPH log
        println(io, "RALPH VALIDATION:")
        println(io, "-" ^ 72)
        for rl in ctx.log
            @printf(io, "  %s  %-40s  %8.1f ms  %s\n",
                rl.success ? "PASS" : "FAIL", rl.model_name, rl.time_ms, rl.message)
        end
        println(io)

        # Model results
        println(io, "MODEL RESULTS:")
        println(io, "-" ^ 72)
        for (name, r) in sort(collect(ctx.results), by=x->x.first)
            if r isa NamedTuple
                dir_s = hasproperty(r, :direction) ? string(r.direction) : "-"
                prob = hasproperty(r, :probability) ? @sprintf("%.3f", r.probability) : "-"
                @printf(io, "  %-42s  Dir: %-10s  P: %s\n", name, dir_s, prob)
            end
        end
        println(io)

        # Key insights
        println(io, "KEY INSIGHTS:")
        println(io, "-" ^ 72)
        for (name, r) in ctx.results
            r isa NamedTuple || continue
            if occursin("Kelly", name) && hasproperty(r, :kelly_half)
                @printf(io, "  Kelly ½: %.1f%% | Win Rate: %.1f%% | Edge: %.0f%%\n",
                    r.kelly_half*100,
                    hasproperty(r, :win_rate) ? r.win_rate : NaN,
                    hasproperty(r, :edge_consistency) ? r.edge_consistency : NaN)
            end
            if occursin("EV Gap", name) && hasproperty(r, :ev_after_fees)
                @printf(io, "  EV: %.3f (after fees: %.3f) — %s\n", r.ev, r.ev_after_fees, r.trade_signal)
            end
            if occursin("AR(1)", name) && hasproperty(r, :regime)
                @printf(io, "  AR(1): β=%.4f (t=%.2f) — %s\n", r.beta, r.t_stat, r.regime)
            end
            if occursin("Bayesian", name) && hasproperty(r, :posterior)
                @printf(io, "  Bayesian: prior=%.3f → posterior=%.3f — %s\n", r.prior, r.posterior, r.direction)
            end
        end
        println(io)

        # Plain-English summary
        if ctx.asset_type != :polymarket && length(ctx.returns) > 0
            ann_ret = mean(ctx.returns) * 252 * 100
            ann_vol = std(ctx.returns) * sqrt(252) * 100
            sharpe = ann_vol > 0 ? (ann_ret - RF_ANNUAL*100) / ann_vol : 0.0
            println(io, "SUMMARY:")
            println(io, "-" ^ 72)
            @printf(io, "  Annual Return: %+.1f%% | Volatility: %.1f%% | Sharpe: %.2f\n",
                ann_ret, ann_vol, sharpe)
            println(io)
        end

        println(io, "=" ^ 72)
        println(io, "  NOT FINANCIAL ADVICE. Past performance ≠ future results.")
        println(io, "=" ^ 72)
    end

    println("  Text report: $(basename(report_path))")
    return report_path
end

"""Generate program metrics file. Returns file path."""
function generate_metrics(ctx::AnalysisContext, elapsed_sec::Float64)::String
    dir = ctx.output_dir
    tk  = ctx.display_ticker
    metrics_path = joinpath(dir, "metrics.txt")

    n_pass = count(r -> r.success, ctx.log)
    n_fail = count(r -> !r.success, ctx.log)
    total_ms = sum(r.time_ms for r in ctx.log)

    open(metrics_path, "w") do io
        println(io, "╔══════════════════════════════════════════════════════════════╗")
        println(io, "║          PROGRAM METRICS — QuantEngine                      ║")
        println(io, "╚══════════════════════════════════════════════════════════════╝")
        println(io)
        println(io, "  Generated:  $(Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"))")
        println(io, "  Ticker:     $tk ($(ctx.asset_type))")
        println(io, "  Output:     $(ctx.output_dir)")
        println(io)
        println(io, "════════════════════════════════════════════════════════════════")
        println(io, "  EXECUTION TIME")
        println(io, "════════════════════════════════════════════════════════════════")
        @printf(io, "  Total runtime:      %8.2f seconds\n", elapsed_sec)
        @printf(io, "  Model time:         %8.1f ms (%.2f sec)\n", total_ms, total_ms/1000)
        println(io)
        println(io, "  RALPH Model Timings:")
        for rl in ctx.log
            @printf(io, "    %-40s  %8.1f ms  %s\n", rl.model_name, rl.time_ms, rl.success ? "OK" : "FAIL")
        end
        println(io)
        println(io, "════════════════════════════════════════════════════════════════")
        println(io, "  RESULTS SUMMARY")
        println(io, "════════════════════════════════════════════════════════════════")
        @printf(io, "  Models run:         %8d\n", length(ctx.log))
        @printf(io, "  Models passed:      %8d\n", n_pass)
        @printf(io, "  Models failed:      %8d\n", n_fail)
        @printf(io, "  Pass rate:          %7.1f%%\n", n_pass / max(length(ctx.log), 1) * 100)
        println(io)
        println(io, "════════════════════════════════════════════════════════════════")
        println(io, "  SYSTEM INFO")
        println(io, "════════════════════════════════════════════════════════════════")
        println(io, "  Julia:              $(VERSION)")
        println(io, "  OS:                 $(Sys.KERNEL) $(Sys.ARCH)")
        println(io, "  Threads:            $(Sys.CPU_THREADS)")
        @printf(io, "  Memory:             %.1f GB\n", Sys.total_memory() / 1073741824)
        println(io)
        println(io, "════════════════════════════════════════════════════════════════")
        @printf(io, "  TOTAL EXECUTION:    %.2f seconds\n", elapsed_sec)
        println(io, "════════════════════════════════════════════════════════════════")
    end

    println("  Metrics: $(basename(metrics_path))")
    return metrics_path
end
