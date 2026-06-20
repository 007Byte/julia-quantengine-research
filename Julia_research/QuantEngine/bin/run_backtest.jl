#!/usr/bin/env julia
# ── QuantEngine Walk-Forward Backtest ─────────────────────────
# Usage:
#   julia --project=. bin/run_backtest.jl BTC-USD --cpcv --costs
#   julia --project=. bin/run_backtest.jl BTC-USD --cpcv --costs --fast
#   julia --project=. bin/run_backtest.jl AAPL --cpcv --costs --folds 8 --capital 50000
#
# REQUIRED flags (must explicitly choose):
#   --cpcv           Use CPCV purged folds (recommended)
#   --no-cpcv        Use naive expanding window (not recommended)
#   --costs          Apply realistic transaction costs (recommended)
#   --no-costs       Skip cost modeling (not recommended)
#
# Options:
#   --fast           Use only fast models (skip heavy NN, ~10x faster)
#   --folds N        Number of walk-forward folds (default: 5)
#   --capital N      Initial capital (default: 10000)
#   --cost-bps N     Override cost in basis points (ignored when --costs is set)
#   --regimes        Run regime-split validation (bull/bear/high_vol/low_vol)
#   --no-regimes     Skip regime split (classic backtest only)

using QuantEngine
using Printf

function main()
    if isempty(ARGS)
        println("Usage: julia --project=. bin/run_backtest.jl TICKER --cpcv --costs [options]")
        println("REQUIRED: --cpcv/--no-cpcv AND --costs/--no-costs")
        println("Options:  --fast, --folds N, --capital N, --regimes, --no-regimes")
        return
    end

    ticker = ARGS[1]

    # ── Mandatory safety flags ──────────────────────────────────
    # Prevent accidental backtests without costs/CPCV.
    has_cpcv = "--cpcv" in ARGS || "--no-cpcv" in ARGS
    has_costs = "--costs" in ARGS || "--no-costs" in ARGS
    if !has_cpcv || !has_costs
        println("ERROR: --cpcv and --costs are REQUIRED flags.")
        println("  --cpcv     Use CPCV purged folds (recommended)")
        println("  --no-cpcv  Use naive expanding window (not recommended)")
        println("  --costs    Apply realistic transaction costs (recommended)")
        println("  --no-costs Skip cost modeling (not recommended)")
        println()
        println("Example: julia --project=. bin/run_backtest.jl BTC-USD --cpcv --costs")
        return
    end
    use_cpcv = "--cpcv" in ARGS
    use_costs = "--costs" in ARGS

    # Parse options
    fast = "--fast" in ARGS
    do_regimes = !("--no-regimes" in ARGS)  # regimes ON by default
    folds = 5
    capital = 10000.0
    cost_bps = 10.0

    for i in eachindex(ARGS)
        if ARGS[i] == "--folds" && i < length(ARGS)
            folds = parse(Int, ARGS[i+1])
        elseif ARGS[i] == "--capital" && i < length(ARGS)
            capital = parse(Float64, ARGS[i+1])
        elseif ARGS[i] == "--cost-bps" && i < length(ARGS)
            cost_bps = parse(Float64, ARGS[i+1])
        end
    end

    # When --costs is set, use realistic costs for the asset type
    asset_type = detect_asset_type(ticker)
    if use_costs
        costs = realistic_costs(asset_type)
        cost_bps = round_trip_cost_bps(costs)
        slippage_bps = costs.slippage_bps
        println("  Using realistic costs for $(asset_type): $(cost_bps) bps round-trip")
    else
        slippage_bps = 5.0
        println("  WARNING: Running WITHOUT realistic costs (--no-costs)")
    end

    # Standard walk-forward backtest
    config = BacktestConfig(
        initial_capital=capital,
        n_folds=folds,
        cost_bps=cost_bps,
        slippage_bps=slippage_bps,
        use_fast_models_only=fast,
        use_cpcv=use_cpcv
    )

    result = run_backtest(ticker, config; verbose=true)
    print_backtest_report(result)

    # Save chart
    output_dir = resolve_output_base()
    chart_path = save_backtest_chart(result, output_dir)
    if chart_path !== nothing
        println("  Chart saved: $chart_path")
    end

    # Regime-split validation (default: ON)
    if do_regimes
        println()
        println("═" ^ 64)
        println("  REGIME-SPLIT VALIDATION")
        println("═" ^ 64)
        try
            regime_results = run_regime_backtest(ticker; initial_capital=capital, verbose=true)

            # Validation summary
            if !isempty(regime_results)
                all_positive = all(r -> r.total_return >= 0, regime_results)
                min_sharpe = minimum(r -> r.sharpe, regime_results)
                max_dd = maximum(r -> r.max_drawdown, regime_results)

                println()
                println("  LAUNCH READINESS:")
                println("    ✓ Positive in all regimes: $(all_positive ? "YES" : "NO")")
                @printf("    %s Minimum Sharpe ≥ 1.8: %.2f\n", min_sharpe >= 1.8 ? "✓" : "✗", min_sharpe)
                @printf("    %s Max Drawdown < 12%%: %.1f%%\n", max_dd < 0.12 ? "✓" : "✗", max_dd * 100)

                ready = all_positive && min_sharpe >= 1.0 && max_dd < 0.15
                println("    $(ready ? "✓ READY FOR LIVE" : "✗ NEEDS MORE VALIDATION")")
            end
        catch e
            println("  Regime backtest failed: $(sprint(showerror, e)[1:min(80,end)])")
        end
    end
end

main()
