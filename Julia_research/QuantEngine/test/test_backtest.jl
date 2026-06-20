# ── Backtest Engine Tests ─────────────────────────────────────

@testset "BacktestConfig defaults" begin
    config = BacktestConfig()
    @test config.initial_capital == 10000.0
    @test config.n_folds == 5
    @test config.train_pct == 0.8
    @test config.include_costs == true
    @test config.cost_bps == 10.0
    @test config.use_fast_models_only == false
end

@testset "BacktestConfig validation" begin
    # train_pct bounds
    @test_throws AssertionError BacktestConfig(train_pct=0.3)
    @test_throws AssertionError BacktestConfig(train_pct=0.99)

    # n_folds minimum
    @test_throws AssertionError BacktestConfig(n_folds=1)

    # capital must be positive
    @test_throws AssertionError BacktestConfig(initial_capital=-100.0)
end

@testset "BacktestResult creation" begin
    config = BacktestConfig()
    result = BacktestResult("AAPL", config)

    @test result.ticker == "AAPL"
    @test isempty(result.trades)
    @test isempty(result.equity_curve)
    @test result.n_trades == 0
    @test result.sharpe == 0.0
end

@testset "BacktestExchange" begin
    prices = collect(100.0:0.1:110.0)  # 101 prices
    ex = BacktestExchange(prices, 10000.0)

    @test get_balance(ex) == 10000.0
    @test get_current_price(ex, "TEST") == prices[1]

    # Move to bar 50
    set_bar!(ex, 50)
    @test get_current_price(ex, "TEST") == prices[50]

    # Place order
    order = place_order(ex, "TEST", :buy, :spot_buy, 1000.0)
    @test order.status == :filled
    @test order.fill_price > 0.0

    # Balance reduced by cost
    @test get_balance(ex) < 10000.0

    # Reject order larger than balance
    big_order = place_order(ex, "TEST", :buy, :spot_buy, 999999.0)
    @test big_order.status == :rejected
end

@testset "_compute_max_drawdown" begin
    # No drawdown
    equity = [100.0, 110.0, 120.0, 130.0]
    dd, dur = _compute_max_drawdown(equity)
    @test dd == 0.0

    # Simple drawdown
    equity = [100.0, 120.0, 90.0, 110.0]
    dd, dur = _compute_max_drawdown(equity)
    @test dd ≈ (120.0 - 90.0) / 120.0
    @test dur > 0

    # Full drawdown at end
    equity = [100.0, 50.0]
    dd, dur = _compute_max_drawdown(equity)
    @test dd ≈ 0.5
end

@testset "_generate_folds" begin
    folds = _generate_folds(1, 500, 5, 0.8)

    @test length(folds) > 0
    @test length(folds) <= 5

    for (train, test) in folds
        # Train comes before test
        @test train[end] < test[1]

        # Both have reasonable size
        @test length(train) >= 50
        @test length(test) >= 5

        # No overlap
        @test isempty(intersect(train, test))
    end
end

@testset "compute_backtest_metrics!" begin
    config = BacktestConfig()
    result = BacktestResult("TEST", config)

    # Simulate some trades
    push!(result.trades, BacktestTrade(1, 10, 20, :long, 100.0, 105.0, 1000.0,
                                        50.0, 5.0, 10, :take_profit, 65.0, "BUY"))
    push!(result.trades, BacktestTrade(2, 30, 35, :long, 102.0, 99.0, 1000.0,
                                        -29.4, -2.94, 5, :stop_loss, 55.0, "BUY"))
    push!(result.trades, BacktestTrade(3, 50, 65, :long, 101.0, 108.0, 1000.0,
                                        69.3, 6.93, 15, :take_profit, 70.0, "BUY"))

    # Simulate equity curve
    result.equity_curve = [10000.0, 10050.0, 10020.6, 10089.9]

    prices = collect(100.0:0.1:110.0)
    dates = [DateTime(2024, 1, 1) + Day(i) for i in 1:length(prices)]

    compute_backtest_metrics!(result, prices, dates)

    @test result.n_trades == 3
    @test result.win_rate ≈ 200.0/3  # 2 wins out of 3
    @test result.profit_factor > 1.0  # more profit than loss
    @test result.avg_hold_bars == 10.0
    @test result.total_return > 0  # ended up positive
    @test isfinite(result.sharpe)
    @test result.max_drawdown >= 0.0
    @test result.buy_hold_return > 0  # prices went up
end
