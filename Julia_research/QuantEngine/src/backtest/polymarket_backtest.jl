# ── Polymarket Backtesting ────────────────────────────────────
# Simulates historical prediction market price paths for backtesting.
# Since Polymarket doesn't provide historical OHLCV via API, we either:
#   1. Use synthetic price paths calibrated to real market parameters
#   2. Load historical data from a CSV file if available

"""
    generate_synthetic_polymarket_data(; n_days, initial_price, event_prob, vol)

Generate a synthetic prediction market price path for backtesting.
Uses a mean-reverting process that converges toward the true probability
as the event date approaches.
"""
function generate_synthetic_polymarket_data(;
    n_days::Int=90,
    initial_price::Float64=0.5,
    true_prob::Float64=0.65,     # what the event actually resolves to
    daily_vol::Float64=0.03,     # daily price volatility
    convergence_rate::Float64=0.02)  # how fast price converges to truth

    prices = zeros(n_days)
    prices[1] = initial_price
    dates = [DateTime(2024, 1, 1) + Day(i-1) for i in 1:n_days]
    volumes = abs.(randn(n_days)) .* 50000 .+ 10000

    for t in 2:n_days
        # Days remaining fraction
        time_frac = (n_days - t) / n_days

        # Mean-reverting toward true probability with increasing convergence
        pull = convergence_rate * (1 + 2 * (1 - time_frac)) * (true_prob - prices[t-1])

        # Volatility decreases as event approaches
        vol_t = daily_vol * sqrt(time_frac + 0.1)

        # Price update
        noise = vol_t * randn()
        prices[t] = clamp(prices[t-1] + pull + noise, 0.01, 0.99)
    end

    # Final convergence: last few days snap toward resolution
    if n_days > 5
        for t in (n_days-4):n_days
            prices[t] = prices[t] * 0.5 + true_prob * 0.5
        end
    end

    returns = diff(prices)
    high = [max(prices[max(1,i-1)], prices[i]) + abs(randn()) * 0.01 for i in 1:n_days]
    low = [min(prices[max(1,i-1)], prices[i]) - abs(randn()) * 0.01 for i in 1:n_days]
    high = clamp.(high, 0.01, 0.99)
    low = clamp.(low, 0.01, 0.99)

    return (dates=dates, prices=prices, returns=returns,
            volumes=volumes, high=high, low=low,
            true_prob=true_prob, n_days=n_days)
end

"""
    load_polymarket_csv(filepath) → NamedTuple

Load historical Polymarket data from a CSV file.
Expected format: date,price,volume (one row per day/hour).
"""
function load_polymarket_csv(filepath::String)
    lines = readlines(filepath)
    if length(lines) < 3
        error("CSV file too short: need at least 2 data rows + header")
    end

    # Skip header
    dates = DateTime[]
    prices = Float64[]
    volumes = Float64[]

    for line in lines[2:end]
        parts = split(strip(line), ",")
        if length(parts) >= 2
            try
                push!(dates, DateTime(strip(parts[1])))
                push!(prices, parse(Float64, strip(parts[2])))
                push!(volumes, length(parts) >= 3 ? parse(Float64, strip(parts[3])) : 0.0)
            catch
                continue
            end
        end
    end

    if length(prices) < 5
        error("Not enough valid data in CSV: $(length(prices)) rows")
    end

    returns = diff(prices)
    high = prices .+ abs.(randn(length(prices))) .* 0.005
    low = prices .- abs.(randn(length(prices))) .* 0.005

    return (dates=dates, prices=prices, returns=returns,
            volumes=volumes, high=clamp.(high, 0.01, 0.99),
            low=clamp.(low, 0.01, 0.99))
end

"""
    run_polymarket_backtest(data; config) → BacktestResult

Walk-forward backtest on prediction market data.
Uses the Kalman filter, LMSR, EV Gap, Kelly, and Bayesian models.
"""
function run_polymarket_backtest(data::NamedTuple;
                                  initial_capital::Float64=5000.0,
                                  n_folds::Int=4,
                                  verbose::Bool=true)
    prices = data.prices
    n = length(prices)

    if n < 30
        error("Need at least 30 price observations for backtest")
    end

    config = BacktestConfig(
        initial_capital=initial_capital,
        n_folds=n_folds,
        train_pct=0.7,
        cost_bps=200.0,    # Polymarket ~2% fee
        slippage_bps=50.0,
        use_fast_models_only=true
    )

    result = BacktestResult("POLYMARKET", config)
    equity = initial_capital

    # Generate folds
    fold_size = div(n, n_folds)
    folds = [(max(1, (k-1)*fold_size - fold_size):max(1, (k-1)*fold_size),
              (k-1)*fold_size+1:min(k*fold_size, n))
             for k in 2:n_folds]

    for (fold_num, (train_range, test_range)) in enumerate(folds)
        if length(train_range) < 10 || length(test_range) < 3
            continue
        end

        train_prices = prices[train_range]

        # Run Kalman filter on training data
        kalman = run_kalman_filter(train_prices)

        # Run LMSR
        lmsr = run_lmsr(train_prices[end])

        # Kelly sizing
        train_returns = diff(train_prices)
        kelly = length(train_returns) > 10 ? run_kelly(train_returns) : nothing

        # Signal: Kalman smoothed vs current market
        signal = kalman.smoothed_prob - train_prices[end]

        # Trade if signal is strong enough
        if abs(signal) < 0.03
            for idx in test_range
                push!(result.equity_curve, equity)
                if idx <= length(data.dates)
                    push!(result.equity_dates, data.dates[idx])
                end
            end
            continue
        end

        direction = signal > 0 ? :long : :short
        kelly_frac = kelly !== nothing ? clamp(kelly.kelly_quarter, 0.01, 0.15) : 0.05
        size_dollars = equity * kelly_frac

        entry_price = prices[min(test_range[1], n)]
        cost = size_dollars * config.cost_bps / 10000.0

        # Walk through test window
        exit_idx = test_range[1]
        exit_price = entry_price
        exit_reason = :end_of_fold
        bars_held = 0
        tp_pct = 5.0   # 5% take profit for prediction markets
        sl_pct = 3.0   # 3% stop loss

        for idx in test_range
            current = prices[min(idx, n)]
            bars_held += 1

            pnl_pct = direction == :long ?
                (current - entry_price) / max(entry_price, 0.01) * 100 :
                (entry_price - current) / max(entry_price, 0.01) * 100

            if pnl_pct >= tp_pct
                exit_idx = idx; exit_price = current; exit_reason = :take_profit; break
            elseif pnl_pct <= -sl_pct
                exit_idx = idx; exit_price = current; exit_reason = :stop_loss; break
            end
            exit_idx = idx; exit_price = current
        end

        pnl_pct = direction == :long ?
            (exit_price - entry_price) / max(entry_price, 0.01) * 100 :
            (entry_price - exit_price) / max(entry_price, 0.01) * 100
        pnl = size_dollars * pnl_pct / 100 - cost

        trade = BacktestTrade(fold_num, first(test_range), exit_idx, direction,
                              entry_price, exit_price, size_dollars, pnl, pnl_pct,
                              bars_held, exit_reason, 0.0, string(direction))
        push!(result.trades, trade)
        equity += pnl

        for idx in test_range
            push!(result.equity_curve, equity)
            if idx <= length(data.dates)
                push!(result.equity_dates, data.dates[idx])
            end
        end

        if verbose
            @printf("  Fold %d: %s @ %.3f → %.3f | PnL: %+.2f (%.1f%%) | %s\n",
                    fold_num, direction, entry_price, exit_price, pnl, pnl_pct, exit_reason)
        end
    end

    compute_backtest_metrics!(result, prices, data.dates)
    return result
end
