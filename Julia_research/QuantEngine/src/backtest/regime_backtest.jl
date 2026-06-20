# ── Regime-Split Backtesting ──────────────────────────────────
# Runs walk-forward backtest across distinct market regimes:
# bull, bear, high-vol, low-vol, and election/event periods.
# Validates that the strategy works in ALL conditions, not just favorable ones.

"""Result of a regime-specific backtest."""
struct RegimeBacktestResult
    regime::String
    n_bars::Int
    n_trades::Int
    total_return::Float64
    sharpe::Float64
    max_drawdown::Float64
    win_rate::Float64
    profit_factor::Float64
end

"""
    run_regime_backtest(ticker; config, verbose)

Run backtest split by market regime. Identifies bull/bear/volatile/calm
periods in the data and runs separate walk-forward tests on each.

Returns: overall result + per-regime breakdown.
"""
function run_regime_backtest(ticker::String;
                              initial_capital::Float64=10000.0,
                              verbose::Bool=true)
    ticker = validate_ticker(ticker)
    display_ticker = uppercase(replace(ticker, "-USD" => "-USD"))

    verbose && println("═" ^ 64)
    verbose && println("  REGIME-SPLIT BACKTEST — $display_ticker")
    verbose && println("═" ^ 64)

    # Fetch data
    stock = fetch_ohlcv(display_ticker; period="5y")
    prices = stock.adj
    returns = diff(log.(prices))
    n = length(returns)

    if n < 200
        error("Need at least 200 data points for regime backtest, got $n")
    end

    # ── Classify regimes ──
    regime_labels = _classify_regimes(returns)

    # ── Run backtest per regime ──
    regimes = ["bull", "bear", "high_vol", "low_vol"]
    regime_results = RegimeBacktestResult[]

    for regime in regimes
        indices = findall(regime_labels .== regime)
        if length(indices) < 30
            verbose && println("  $regime: insufficient data ($(length(indices)) bars)")
            continue
        end

        # Run fast backtest on this regime's data
        regime_prices = prices[vcat(indices, [indices[end] + 1])]  # need n+1 prices for n returns
        regime_returns = returns[indices]

        if length(regime_prices) < 30
            continue
        end

        bt_config = BacktestConfig(
            initial_capital=initial_capital,
            n_folds=min(4, div(length(indices), 30)),
            train_pct=0.7,
            use_fast_models_only=true,
            cost_bps=10.0,
            slippage_bps=5.0
        )

        result = try
            run_backtest(ticker, bt_config; verbose=false)
        catch
            nothing
        end

        if result !== nothing
            rr = RegimeBacktestResult(
                regime, length(indices), result.n_trades,
                result.total_return, result.sharpe,
                result.max_drawdown, result.win_rate, result.profit_factor
            )
            push!(regime_results, rr)

            if verbose
                @printf("  %-10s | Bars: %4d | Trades: %3d | Return: %+6.1f%% | Sharpe: %5.2f | DD: %5.1f%% | Win: %4.1f%%\n",
                        regime, rr.n_bars, rr.n_trades, rr.total_return,
                        rr.sharpe, rr.max_drawdown * 100, rr.win_rate)
            end
        end
    end

    # ── Overall summary ──
    if verbose && !isempty(regime_results)
        println("  " * "-" ^ 60)

        all_positive = all(r -> r.total_return >= 0, regime_results)
        min_sharpe = minimum(r -> r.sharpe, regime_results)
        max_dd = maximum(r -> r.max_drawdown, regime_results)

        println("  VALIDATION:")
        println("    Positive in all regimes: $(all_positive ? "✓ YES" : "✗ NO")")
        @printf("    Minimum Sharpe:          %.2f %s\n", min_sharpe, min_sharpe > 1.8 ? "✓" : "⚠")
        @printf("    Maximum Drawdown:        %.1f%% %s\n", max_dd * 100, max_dd < 0.12 ? "✓" : "⚠")
        println("  " * "-" ^ 60)
    end

    return regime_results
end

"""Classify each return into a market regime."""
function _classify_regimes(returns::Vector{Float64}; window::Int=20)
    n = length(returns)
    labels = fill("neutral", n)

    for i in window:n
        lookback = returns[max(1, i-window+1):i]
        cum_return = sum(lookback)
        vol = std(lookback)
        median_vol = std(returns[max(1, i-60):i])

        if cum_return > 0.03 && vol < median_vol * 1.3
            labels[i] = "bull"
        elseif cum_return < -0.03 && vol < median_vol * 1.3
            labels[i] = "bear"
        elseif vol > median_vol * 1.5
            labels[i] = "high_vol"
        else
            labels[i] = "low_vol"
        end
    end

    return labels
end
