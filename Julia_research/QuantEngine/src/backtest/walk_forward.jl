# ── Walk-Forward Backtest Engine ──────────────────────────────
# Slices historical data into folds. For each fold:
#   1. Train models on the training window
#   2. Generate trade signal from composite + decision layer
#   3. Simulate execution on the test window
#   4. Track PnL and equity curve
# No look-ahead bias: each fold uses only past data.

"""
    run_backtest(ticker, bt_config; verbose) → BacktestResult

Walk-forward backtest on historical data. Fetches data once, then
slices into folds for out-of-sample evaluation.
"""
function run_backtest(ticker::String, bt_config::BacktestConfig=BacktestConfig();
                      verbose::Bool=true)
    ticker = validate_ticker(ticker)
    asset_type = detect_asset_type(ticker)
    display_ticker = asset_type == :polymarket ? replace(ticker, "poly:" => "") : uppercase(ticker)

    verbose && println("═" ^ 64)
    verbose && println("  BACKTEST — $display_ticker")
    verbose && println("  Capital: \$$(bt_config.initial_capital) | Folds: $(bt_config.n_folds)")
    verbose && println("═" ^ 64)

    # ── Fetch all historical data once ──
    if asset_type == :polymarket
        error("Backtest not supported for Polymarket (no historical OHLCV)")
    end

    stock = fetch_ohlcv(display_ticker; period="5y")
    all_dates = stock.dates
    all_prices = stock.adj
    all_volumes = stock.volume
    all_high = stock.high
    all_low = stock.low
    all_returns = diff(log.(all_prices))
    n_total = length(all_returns)

    verbose && println("  Data: $(length(all_prices)) bars ($(all_dates[1]) → $(all_dates[end]))")

    # Apply index bounds
    start_i = max(bt_config.start_idx, 1)
    end_i = bt_config.end_idx > 0 ? min(bt_config.end_idx, n_total) : n_total

    if end_i - start_i < 100
        error("Need at least 100 data points for backtest, got $(end_i - start_i)")
    end

    # ── Generate walk-forward folds ──
    if bt_config.use_cpcv
        # CPCV purged folds — no information leakage
        cpcv_raw = cpcv_splits(end_i - start_i + 1, bt_config.n_folds + 1, 2;
                               purge=10, embargo=5)
        # Convert Vector{Int} indices to ranges offset by start_i
        folds = Tuple{UnitRange{Int}, UnitRange{Int}}[]
        for (train_idx, test_idx) in cpcv_raw
            ti = train_idx .+ (start_i - 1)
            te = test_idx .+ (start_i - 1)
            # Use contiguous ranges (first:last) for compatibility with simulation loop
            if !isempty(ti) && !isempty(te)
                push!(folds, (first(ti):last(ti), first(te):last(te)))
            end
        end
        verbose && println("  Folds: $(length(folds)) CPCV purged windows (purge=10, embargo=5)")
    else
        folds = _generate_folds(start_i, end_i, bt_config.n_folds, bt_config.train_pct)
        verbose && println("  Folds: $(length(folds)) walk-forward windows")
    end

    result = BacktestResult(display_ticker, bt_config)
    equity = bt_config.initial_capital
    pipeline_config = load_pipeline_config()

    # Select which models to run
    model_ids = if bt_config.use_fast_models_only
        sort(collect(FAST_MODELS))
    else
        collect(1:N_MODELS)
    end

    # ── Run each fold ──
    for (fold_num, (train_range, test_range)) in enumerate(folds)
        verbose && println("\n  ── Fold $fold_num/$(length(folds)) ──")
        verbose && println("    Train: bars $(train_range[1])→$(train_range[end]) ($(length(train_range)))")
        verbose && println("    Test:  bars $(test_range[1])→$(test_range[end]) ($(length(test_range)))")

        # Build context from training window only (no look-ahead)
        ctx = _build_backtest_context(
            ticker, asset_type, display_ticker,
            all_dates, all_prices, all_returns, all_volumes, all_high, all_low,
            train_range
        )

        # Run models
        if isempty(MODEL_DISPATCH)
            _register_models!()
        end

        for m in model_ids
            if m in PHASE2_MODELS
                continue  # run after phase 1
            end
            run_model(ctx, m; verbose=false)
        end
        # Phase 2
        for m in sort(collect(PHASE2_MODELS))
            if m in model_ids
                run_model(ctx, m; verbose=false)
            end
        end

        # Composite signal
        composite = compute_composite(ctx.results)
        verbose && @printf("    Signal: %s (p=%.3f, score=%.3f)\n",
                           composite.direction, composite.p_true, composite.score)

        # Extract key model outputs for trade sizing
        kelly_r = get(ctx.results, "17. Kelly Criterion", nothing)
        garch_r = get(ctx.results, "14. EGARCH/GARCH Family", nothing)

        kelly_frac = if kelly_r isa NamedTuple && hasproperty(kelly_r, :kelly_quarter)
            clamp(kelly_r.kelly_quarter, 0.01, 0.20)
        else
            0.05
        end

        daily_vol = if garch_r isa NamedTuple && hasproperty(garch_r, :σ_annual_forecast)
            garch_r.σ_annual_forecast / sqrt(252)
        else
            std(all_returns[train_range])
        end

        # ── Simulate trading on test window ──
        if composite.direction in ["BUY", "LEAN BUY"] && composite.p_true > 0.52
            direction = :long
        elseif composite.direction in ["DO NOT BUY", "LEAN SELL"] && composite.p_true < 0.48
            direction = :short
        else
            verbose && println("    → HOLD (no trade this fold)")
            # Still track equity through test window (no change)
            for idx in test_range
                push!(result.equity_curve, equity)
                if idx <= length(all_dates)
                    push!(result.equity_dates, all_dates[idx])
                end
            end
            continue
        end

        # Position sizing
        size_frac = clamp(kelly_frac, 0.01, 0.15)
        size_dollars = equity * size_frac

        # TP/SL from volatility
        hold_bars = clamp(round(Int, 3.0 / max(daily_vol, 0.001)), 2, length(test_range))
        tp_pct = daily_vol * sqrt(hold_bars) * 1.5 * 100.0
        sl_pct = max(tp_pct / 2.0, 0.5)
        tp_pct = clamp(tp_pct, 0.5, 20.0)
        sl_pct = clamp(sl_pct, 0.3, 10.0)

        # Execute on test window
        entry_idx = test_range[1]
        entry_price = all_prices[min(entry_idx + 1, length(all_prices))]  # fill at next bar

        # Apply costs
        cost = bt_config.include_costs ? size_dollars * bt_config.cost_bps / 10000.0 : 0.0
        slip = entry_price * bt_config.slippage_bps / 10000.0
        entry_price_adj = direction == :long ? entry_price + slip : entry_price - slip

        # Walk through test bars, check TP/SL/time
        exit_idx = entry_idx
        exit_price = entry_price_adj
        exit_reason = :end_of_fold
        bars_held = 0

        for idx in test_range
            current_price = all_prices[min(idx, length(all_prices))]
            bars_held += 1

            if direction == :long
                pnl_pct = (current_price / entry_price_adj - 1.0) * 100.0
            else
                pnl_pct = (1.0 - current_price / entry_price_adj) * 100.0
            end

            # Check exits
            if pnl_pct >= tp_pct
                exit_idx = idx
                exit_price = current_price
                exit_reason = :take_profit
                break
            elseif pnl_pct <= -sl_pct
                exit_idx = idx
                exit_price = current_price
                exit_reason = :stop_loss
                break
            elseif bars_held >= hold_bars
                exit_idx = idx
                exit_price = current_price
                exit_reason = :time_expired
                break
            end

            exit_idx = idx
            exit_price = current_price
        end

        # Calculate PnL
        if direction == :long
            trade_pnl_pct = (exit_price / entry_price_adj - 1.0) * 100.0
        else
            trade_pnl_pct = (1.0 - exit_price / entry_price_adj) * 100.0
        end
        trade_pnl = size_dollars * trade_pnl_pct / 100.0 - cost

        # Record trade
        trade = BacktestTrade(
            fold_num, entry_idx, exit_idx, direction,
            entry_price_adj, exit_price, size_dollars,
            trade_pnl, trade_pnl_pct, bars_held,
            exit_reason, composite.confidence,
            composite.direction
        )
        push!(result.trades, trade)

        # Update equity
        equity += trade_pnl

        verbose && @printf("    Trade: %s @ \$%.2f → \$%.2f | PnL: %+.2f (%.1f%%) | %s after %d bars\n",
                           uppercase(string(direction)), entry_price_adj, exit_price,
                           trade_pnl, trade_pnl_pct, exit_reason, bars_held)

        # Track equity through all test bars
        for idx in test_range
            push!(result.equity_curve, equity)
            if idx <= length(all_dates)
                push!(result.equity_dates, all_dates[idx])
            end
        end
    end

    # ── Compute metrics ──
    # Use test-window prices for benchmark comparison
    test_indices = vcat([collect(f[2]) for f in folds]...)
    test_prices = all_prices[clamp.(test_indices, 1, length(all_prices))]
    test_dates = all_dates[clamp.(test_indices, 1, length(all_dates))]

    compute_backtest_metrics!(result, test_prices, test_dates)

    if verbose
        println("\n" * "═" ^ 64)
        println("  BACKTEST RESULTS — $display_ticker")
        println("═" ^ 64)
        @printf("  Total Return:     %+.1f%%\n", result.total_return)
        @printf("  Sharpe Ratio:     %.2f\n", result.sharpe)
        @printf("  Sortino Ratio:    %.2f\n", result.sortino)
        @printf("  Max Drawdown:     %.1f%%\n", result.max_drawdown * 100)
        @printf("  Calmar Ratio:     %.2f\n", result.calmar)
        @printf("  Win Rate:         %.1f%% (%d trades)\n", result.win_rate, result.n_trades)
        @printf("  Profit Factor:    %.2f\n", result.profit_factor)
        @printf("  Avg Hold:         %.1f bars\n", result.avg_hold_bars)
        println("  ──────────────────────────────────────")
        @printf("  Buy & Hold:       %+.1f%% (Sharpe %.2f)\n",
                result.buy_hold_return, result.buy_hold_sharpe)
        println("═" ^ 64)
    end

    return result
end

"""Generate walk-forward fold ranges (train, test) with expanding or rolling window."""
function _generate_folds(start_i::Int, end_i::Int, n_folds::Int, train_pct::Float64)
    total = end_i - start_i + 1
    fold_size = div(total, n_folds)

    folds = Tuple{UnitRange{Int}, UnitRange{Int}}[]
    for k in 1:n_folds
        fold_end = start_i + k * fold_size - 1
        fold_end = min(fold_end, end_i)

        # Expanding window: train on everything before the test window
        test_start = start_i + (k - 1) * fold_size
        test_end = fold_end

        # Training window: from start up to test_start
        # Need minimum 50 bars for training
        train_end = test_start - 1
        train_start = max(start_i, train_end - round(Int, fold_size / (1 - train_pct) * train_pct))
        train_start = max(start_i, train_start)

        if train_end - train_start < 50 || test_end - test_start < 5
            continue
        end

        push!(folds, (train_start:train_end, test_start:test_end))
    end
    return folds
end

"""Build an AnalysisContext from a slice of historical data (no API calls)."""
function _build_backtest_context(ticker, asset_type, display_ticker,
                                  all_dates, all_prices, all_returns,
                                  all_volumes, all_high, all_low,
                                  train_range)
    # Slice data to training window (price indices are +1 vs return indices)
    price_range = train_range[1]:min(train_range[end] + 1, length(all_prices))
    prices = all_prices[price_range]
    returns = all_returns[train_range]
    volumes = all_volumes[price_range]
    high = all_high[price_range]
    low = all_low[price_range]
    dates = all_dates[price_range]
    S0 = prices[end]

    # Feature engineering
    if length(returns) > 30
        X_all, y_all, _, _ = compute_features(prices, returns, volumes)
        n_samples = size(X_all, 1)
        split_idx = round(Int, n_samples * 0.8)
        split_idx = max(split_idx, 1)
        split_end = max(split_idx + 1, n_samples)
        X_train = X_all[1:split_idx, :]
        y_train = y_all[1:split_idx]
        X_test = X_all[split_end:end, :]
        y_test = y_all[split_end:end]
        n_features = size(X_all, 2)
    else
        X_train = zeros(1, 18); y_train = [0.5]
        X_test = zeros(1, 18); y_test = [0.5]
        n_features = 18
    end

    seq_len = min(10, max(2, div(size(X_train, 1), 5)))
    if size(X_train, 1) > seq_len + 2
        Xseq_train, yseq_train = make_sequences(X_train, y_train, seq_len)
        Xseq_test, yseq_test = make_sequences(X_test, y_test, seq_len)
    else
        Xseq_train = [reshape(X_train[1,:], 1, :)]
        yseq_train = [y_train[1]]
        Xseq_test = Xseq_train
        yseq_test = yseq_train
    end

    out_dir = mktempdir()

    return AnalysisContext(
        ticker, asset_type, display_ticker, out_dir,
        dates, prices, returns, volumes, high, low, S0,
        X_train, y_train, X_test, y_test,
        Xseq_train, yseq_train, Xseq_test, yseq_test,
        n_features, seq_len,
        nothing, Float64[],  # no poly data, no benchmark in backtest
        Dict{String, Any}(), RalphLog[], ReentrantLock(),
        nothing  # weight_cache
    )
end
