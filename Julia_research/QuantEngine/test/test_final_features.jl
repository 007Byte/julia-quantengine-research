# ── Final Features Tests (CVD, Regime Backtest, Learning Loop) ──

using QuantEngine: compute_cvd, cvd_to_features, _linear_slope,
                   run_regime_backtest, RegimeBacktestResult,
                   LearningConfig, LearningState, should_retrain,
                   should_update_calibration, record_trade_for_learning!,
                   trigger_retrain!, learning_status,
                   fetch_polymarket_markets,
                   generate_synthetic_polymarket_data, run_polymarket_backtest

# ── CVD Tests ────────────────────────────────────────────────

@testset "compute_cvd basic" begin
    Random.seed!(42)
    n = 100
    prices = cumsum(randn(n) * 0.5) .+ 100.0
    volumes = abs.(randn(n)) .* 1e6 .+ 1e5

    result = compute_cvd(prices, volumes)

    @test length(result.cvd) == n
    @test length(result.delta) == n
    @test result.divergence isa Symbol
    @test result.divergence in [:bullish_divergence, :bearish_divergence,
                                 :bullish_confirmation, :bearish_confirmation, :none]
    @test isfinite(result.cvd_slope)
    @test isfinite(result.price_slope)
    @test isfinite(result.cvd_current)
end

@testset "compute_cvd with high/low" begin
    Random.seed!(42)
    n = 50
    prices = cumsum(randn(n) * 0.3) .+ 50.0
    volumes = abs.(randn(n)) .* 5e5 .+ 1e4
    high = prices .+ abs.(randn(n)) .* 0.5
    low = prices .- abs.(randn(n)) .* 0.5

    result = compute_cvd(prices, volumes; high=high, low=low)
    @test length(result.cvd) == n
    @test !any(isnan, result.delta)
end

@testset "compute_cvd small input" begin
    result = compute_cvd([100.0], [1000.0])
    @test result.divergence == :none
    @test result.cvd_current == 0.0
end

@testset "cvd_to_features" begin
    Random.seed!(42)
    prices = cumsum(randn(100) * 0.5) .+ 100.0
    volumes = abs.(randn(100)) .* 1e6 .+ 1e5

    cvd_result = compute_cvd(prices, volumes)
    features = cvd_to_features(cvd_result, 100)

    @test length(features.cvd_normalized) == 100
    @test isfinite(features.slope)
    @test -1.0 <= features.divergence_score <= 1.0
end

@testset "_linear_slope" begin
    x = collect(1.0:10.0)
    y = 2.0 .* x .+ 1.0  # perfect linear: slope = 2
    @test _linear_slope(x, y) ≈ 2.0 atol=1e-10

    y_flat = fill(5.0, 10)
    @test _linear_slope(x, y_flat) ≈ 0.0 atol=1e-10
end

@testset "18-feature matrix includes CVD" begin
    Random.seed!(42)
    n = 300
    prices = cumsum(randn(n)) .+ 100.0
    prices = max.(prices, 1.0)
    returns = diff(log.(prices))
    volumes = abs.(randn(n)) .* 1e6 .+ 1.0

    X, y, _, _ = compute_features(prices, returns, volumes)
    @test size(X, 2) == 18
    @test !any(isnan, X)
end

# ── Learning Loop Tests ──────────────────────────────────────

@testset "LearningConfig defaults" begin
    config = LearningConfig()
    @test config.retrain_interval_hours == 24
    @test config.calibration_update_trades == 10
    @test config.auto_promote_ab == true
end

@testset "LearningState lifecycle" begin
    state = LearningState()
    config = LearningConfig(retrain_interval_hours=1)

    @test !should_retrain(state, config)  # just created
    @test !should_update_calibration(state, config)

    # Record trades
    for _ in 1:10
        record_trade_for_learning!(state)
    end
    @test should_update_calibration(state, config)

    status = learning_status(state)
    @test status.trades_since_cal == 10
    @test status.total_retrains == 0
end

@testset "trigger_retrain! clears cache" begin
    dir = mktempdir()
    cache = WeightCache(dir)

    store_weights!(cache, 1, "AAPL", 18, [1.0, 2.0], [(1,2)], 0.6, 0.3, UInt64(0))
    @test get_cached_weights(cache, 1, "AAPL", 18) !== nothing

    trigger_retrain!(cache, "AAPL", 18)
    @test get_cached_weights(cache, 1, "AAPL", 18) === nothing
end

# ── Polymarket Backtest Tests ────────────────────────────────

@testset "synthetic polymarket backtest" begin
    Random.seed!(42)
    data = generate_synthetic_polymarket_data(n_days=120, true_prob=0.65)

    result = run_polymarket_backtest(data; initial_capital=5000.0,
                                     n_folds=3, verbose=false)

    @test result.ticker == "POLYMARKET"
    @test !isempty(result.equity_curve)
    @test isfinite(result.total_return)
end
