# ── CPCV-Enforced Backtest Wrapper ────────────────────────────
# Forces Combinatorial Purged Cross-Validation on every backtest.
# Applies realistic transaction costs. Blocks launch if any fold
# has negative expectancy or Sharpe < threshold.

"""Result of a CPCV-enforced validation run."""
struct CPCVValidationResult
    ticker::String
    n_folds::Int
    fold_results::Vector{NamedTuple}   # per-fold: sharpe, return, trades, expectancy
    overall_sharpe::Float64
    overall_return::Float64
    overall_expectancy::Float64        # avg PnL per trade after costs
    worst_fold_sharpe::Float64
    worst_fold_return::Float64
    all_folds_positive::Bool
    passes_launch_check::Bool
    failure_reasons::Vector{String}
end

"""
    run_cpcv_backtest(ticker; n_groups, n_test_groups, purge, embargo,
                      min_sharpe, asset_type, verbose)

Run a CPCV-enforced backtest with realistic transaction costs.
This is the FINAL validation gate before live trading.

Uses combinatorial purged cross-validation (not simple train/test split)
to prevent ANY information leakage between folds.

Launch is BLOCKED if:
- Any fold has negative expectancy after costs
- Overall Sharpe < min_sharpe
- Fewer than 20 trades across all folds
"""
function run_cpcv_backtest(ticker::String;
                            n_groups::Int=6,
                            n_test_groups::Int=2,
                            purge::Int=10,
                            embargo::Int=5,
                            min_sharpe::Float64=1.0,
                            asset_type::Symbol=:stock,
                            verbose::Bool=true)
    ticker = validate_ticker(ticker)
    at = detect_asset_type(ticker)
    asset_type = at != :stock ? at : asset_type
    display = uppercase(replace(ticker, "-USD" => "-USD"))

    verbose && println("═" ^ 64)
    verbose && println("  CPCV VALIDATION — $display")
    verbose && println("  Groups: $n_groups | Test groups: $n_test_groups | Purge: $purge | Embargo: $embargo")
    verbose && println("═" ^ 64)

    # Fetch data
    stock = fetch_ohlcv(display; period="5y")
    prices = stock.adj
    returns = diff(log.(prices))
    volumes = stock.volume
    n = length(returns)

    if n < 200
        error("Need at least 200 data points for CPCV backtest, got $n")
    end

    # Get realistic costs for this asset
    costs = realistic_costs(asset_type)
    cost_per_trade = round_trip_cost_fraction(costs)
    min_edge = minimum_edge_required(asset_type)

    verbose && @printf("  Data: %d bars | Asset: %s | RT cost: %.0f bps | Min edge: %.2f%%\n",
                       n, asset_type, round_trip_cost_bps(costs), min_edge * 100)

    # Generate CPCV splits
    splits = cpcv_splits(n, n_groups, n_test_groups; purge=purge, embargo=embargo)
    verbose && println("  CPCV folds: $(length(splits))")

    # Compute features once
    X_all, y_all, _, _ = compute_features(prices, returns, volumes;
                                           high=stock.high, low=stock.low)
    n_samples = size(X_all, 1)

    if isempty(MODEL_DISPATCH)
        _register_models!()
    end

    fold_results = NamedTuple[]
    all_returns_vec = Float64[]

    for (fold_idx, (train_idx, test_idx)) in enumerate(splits)
        # Map indices to feature matrix range
        valid_train = filter(i -> i <= n_samples, train_idx)
        valid_test = filter(i -> i <= n_samples, test_idx)

        if length(valid_train) < 30 || length(valid_test) < 5
            continue
        end

        X_tr = X_all[valid_train, :]
        y_tr = y_all[valid_train]
        X_te = X_all[valid_test, :]
        y_te = y_all[valid_test]

        # Run fast models on this fold
        fast_models = [5, 6, 7, 10, 14, 17, 22, 23]
        predictions = Float64[]

        for mid in fast_models
            try
                result = if mid == 5
                    run_random_forest(X_tr, y_tr, X_te, y_te)
                elseif mid == 6
                    run_lightgbm(X_tr, y_tr, X_te, y_te)
                elseif mid == 7
                    run_xgboost(X_tr, y_tr, X_te, y_te, returns[valid_test], asset_type)
                else
                    continue
                end
                if result isa NamedTuple && hasproperty(result, :probability)
                    push!(predictions, result.probability)
                end
            catch
                continue
            end
        end

        if isempty(predictions)
            continue
        end

        # Ensemble prediction for this fold
        p_ensemble = mean(predictions)
        direction = p_ensemble > 0.5 ? 1.0 : -1.0

        # Simulate trading on test window with costs
        test_returns = returns[clamp.(valid_test, 1, length(returns))]
        signal_returns = direction .* test_returns .- cost_per_trade

        fold_total = sum(signal_returns)
        fold_sharpe = length(signal_returns) > 1 ?
            (mean(signal_returns) / max(std(signal_returns), 1e-10) * sqrt(252)) : 0.0
        fold_expectancy = mean(signal_returns)  # per-trade expectancy after costs

        push!(fold_results, (fold=fold_idx, n_test=length(valid_test),
                              total_return=fold_total * 100,
                              sharpe=fold_sharpe,
                              expectancy=fold_expectancy * 100,
                              direction=direction > 0 ? "LONG" : "SHORT"))
        append!(all_returns_vec, signal_returns)

        if verbose
            marker = fold_expectancy > 0 ? "✓" : "✗"
            @printf("  %s Fold %2d | Tests: %4d | Return: %+6.2f%% | Sharpe: %5.2f | E[r]: %+.3f%%\n",
                    marker, fold_idx, length(valid_test), fold_total * 100,
                    fold_sharpe, fold_expectancy * 100)
        end
    end

    # Overall metrics
    if isempty(fold_results)
        return CPCVValidationResult(display, 0, fold_results,
            0.0, 0.0, 0.0, 0.0, 0.0, false, false,
            ["No valid folds generated"])
    end

    overall_sharpe = length(all_returns_vec) > 1 ?
        mean(all_returns_vec) / max(std(all_returns_vec), 1e-10) * sqrt(252) : 0.0
    overall_return = sum(r.total_return for r in fold_results)
    overall_expectancy = mean(r.expectancy for r in fold_results)
    worst_sharpe = minimum(r.sharpe for r in fold_results)
    worst_return = minimum(r.total_return for r in fold_results)
    all_positive = all(r -> r.expectancy > 0, fold_results)
    n_trades = sum(r.n_test for r in fold_results)

    # Launch gate checks
    failures = String[]
    if !all_positive
        push!(failures, "Not all folds have positive expectancy")
    end
    if overall_sharpe < min_sharpe
        push!(failures, "Overall Sharpe $(round(overall_sharpe, digits=2)) < $(min_sharpe)")
    end
    if n_trades < 20
        push!(failures, "Too few trades: $n_trades (need 20+)")
    end
    passes = isempty(failures)

    if verbose
        println("  " * "─" ^ 60)
        @printf("  Overall: %d folds | %d trades | Return: %+.2f%% | Sharpe: %.2f\n",
                length(fold_results), n_trades, overall_return, overall_sharpe)
        @printf("  Worst fold: Sharpe %.2f | Return %+.2f%%\n", worst_sharpe, worst_return)
        @printf("  Per-trade expectancy: %+.4f%%\n", overall_expectancy)
        println()
        if passes
            println("  ✓ LAUNCH CHECK PASSED")
        else
            println("  ✗ LAUNCH CHECK FAILED:")
            for f in failures
                println("    → $f")
            end
        end
        println("═" ^ 64)
    end

    return CPCVValidationResult(display, length(fold_results), fold_results,
        overall_sharpe, overall_return, overall_expectancy,
        worst_sharpe, worst_return, all_positive, passes, failures)
end
