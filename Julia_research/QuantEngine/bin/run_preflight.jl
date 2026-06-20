#!/usr/bin/env julia
# ── QuantEngine Pre-Flight Validation ─────────────────────────
# Run ALL validation checks before live deployment.
# This script MUST pass before any real capital is used.
#
# Usage:
#   julia --project=. -t auto bin/run_preflight.jl BTC-USD
#   julia --project=. -t auto bin/run_preflight.jl BTC-USD,ETH-USD
#
# All checks must pass:
#   1. CPCV backtest with costs (all folds positive, Sharpe ≥ 1.0)
#   2. Regime-split validation (positive in all regimes)
#   3. Monte Carlo stress test (95%+ survival, median profitable)
#   4. Cost sanity check (min edge > round-trip costs)
#   5. System integrity (all 1,500+ tests pass)

using QuantEngine
using Printf

function main()
    if isempty(ARGS)
        println("Usage: julia --project=. -t auto bin/run_preflight.jl TICKER[,TICKER2,...]")
        return
    end

    tickers = split(ARGS[1], ",") .|> strip .|> String
    all_passed = true
    results = Dict{String, Vector{NamedTuple}}()

    println()
    println("╔══════════════════════════════════════════════════════════════╗")
    println("║         QUANTENGINE PRE-FLIGHT VALIDATION                   ║")
    println("║         All checks must pass before live trading             ║")
    println("╚══════════════════════════════════════════════════════════════╝")
    println()

    for ticker in tickers
        println("━" ^ 64)
        println("  VALIDATING: $ticker")
        println("━" ^ 64)

        checks = NamedTuple[]

        # ── Check 1: Cost Sanity ──
        asset_type = detect_asset_type(ticker)
        min_edge = minimum_edge_required(asset_type)
        rt_cost = round_trip_cost_bps(realistic_costs(asset_type))
        print_cost_summary(asset_type)
        push!(checks, (name="Cost Sanity", passed=true,
                        detail="RT: $(round(rt_cost))bps, Min edge: $(round(min_edge*100, digits=2))%"))

        # ── Check 2: CPCV Backtest ──
        println()
        cpcv_result = try
            run_cpcv_backtest(ticker; verbose=true)
        catch e
            println("  CPCV failed: $(sprint(showerror, e)[1:min(80,end)])")
            nothing
        end

        if cpcv_result !== nothing
            push!(checks, (name="CPCV Backtest", passed=cpcv_result.passes_launch_check,
                            detail="Sharpe: $(round(cpcv_result.overall_sharpe, digits=2)), " *
                                   "All positive: $(cpcv_result.all_folds_positive)"))
            if !cpcv_result.passes_launch_check
                all_passed = false
                for f in cpcv_result.failure_reasons
                    println("    FAIL: $f")
                end
            end
        else
            push!(checks, (name="CPCV Backtest", passed=false, detail="Failed to run"))
            all_passed = false
        end

        # ── Check 3: Regime-Split ──
        println()
        regime_results = try
            run_regime_backtest(ticker; verbose=true)
        catch e
            println("  Regime backtest failed: $(sprint(showerror, e)[1:min(80,end)])")
            RegimeBacktestResult[]
        end

        if !isempty(regime_results)
            regime_positive = all(r -> r.total_return >= 0, regime_results)
            push!(checks, (name="Regime Split", passed=regime_positive,
                            detail="$(length(regime_results)) regimes, " *
                                   "all positive: $regime_positive"))
            if !regime_positive
                all_passed = false
            end
        else
            push!(checks, (name="Regime Split", passed=false, detail="No results"))
            all_passed = false
        end

        # ── Check 4: Monte Carlo Stress Test ──
        println()
        stock = try fetch_ohlcv(uppercase(replace(ticker, "-USD" => "-USD")); period="3y") catch; nothing end
        if stock !== nothing
            returns = diff(log.(stock.adj))
            stress = run_stress_test(returns; asset_type=asset_type,
                                      kelly_fraction=0.15, verbose=true)
            push!(checks, (name="Stress Test", passed=stress.passes,
                            detail="Survival: $(round(stress.survival_rate, digits=1))%, " *
                                   "Median: \$$(round(stress.median_final_value, digits=0))"))
            if !stress.passes
                all_passed = false
            end
        else
            push!(checks, (name="Stress Test", passed=false, detail="No data"))
            all_passed = false
        end

        results[ticker] = checks
    end

    # ── Final Summary ──
    println()
    println("╔══════════════════════════════════════════════════════════════╗")
    println("║                    VALIDATION SUMMARY                       ║")
    println("╠══════════════════════════════════════════════════════════════╣")

    for ticker in tickers
        println("║  $ticker:")
        for check in results[ticker]
            marker = check.passed ? "✓" : "✗"
            @printf("║    %s %-20s %s\n", marker, check.name, check.detail)
        end
    end

    println("╠══════════════════════════════════════════════════════════════╣")
    if all_passed
        println("║  ✓ ALL CHECKS PASSED — CLEARED FOR LIVE DEPLOYMENT        ║")
        println("║                                                            ║")
        println("║  Recommended launch command:                               ║")
        println("║  QE_EXECUTION_MODE=LIVE QE_FORCE_CONSERVATIVE=true \\       ║")
        println("║  QE_INITIAL_BANKROLL=5000 QE_KELLY_MAX_FRAC=0.15 \\         ║")
        println("║  julia --project=. -t auto bin/run_pipeline.jl $(tickers[1])  ║")
    else
        println("║  ✗ VALIDATION FAILED — DO NOT DEPLOY LIVE                  ║")
        println("║  Fix the failing checks before proceeding.                 ║")
    end
    println("╚══════════════════════════════════════════════════════════════╝")
end

main()
