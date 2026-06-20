# ── Adaptive Model Selector + Minute Processor Tests ─────────

using QuantEngine: AdaptiveEngine, DataProfile, AdaptiveStrategy,
                   profile_data, select_models, record_model_outcome!,
                   update_bankroll!, goal_progress, print_goal_progress,
                   model_leaderboard,
                   MinuteBarWindow, MinuteDataManager, add_bar!, ingest_tick!,
                   window_snapshot, aggregate_bars, should_analyze,
                   bar_count, get_window!

# ── Data Profiling ───────────────────────────────────────────

@testset "profile_data basic" begin
    Random.seed!(42)
    n = 100
    prices = cumsum(randn(n) * 0.5) .+ 100.0
    returns = diff(log.(max.(prices, 1.0)))
    volumes = abs.(randn(n)) .* 1e6 .+ 1e5

    profile = profile_data(prices, returns, volumes; asset="AAPL", asset_type=:stock)

    @test profile.asset == "AAPL"
    @test profile.asset_type == :stock
    @test -1.0 <= profile.trend_strength <= 1.0
    @test profile.volatility_regime in [:low, :normal, :high, :extreme]
    @test profile.volume_regime in [:thin, :normal, :heavy]
    @test profile.momentum_direction in [:bullish, :bearish, :neutral]
end

@testset "profile_data polymarket" begin
    prices = clamp.(0.6 .+ cumsum(0.01 .* randn(50)), 0.01, 0.99)
    returns = diff(prices)
    volumes = fill(50000.0, 50)

    profile = profile_data(prices, returns, volumes;
                           asset="poly:test", asset_type=:polymarket,
                           hours_to_event=24.0)

    @test profile.asset_type == :polymarket
    @test profile.hours_to_event == 24.0
end

# ── Model Selection ──────────────────────────────────────────

@testset "select_models stock" begin
    engine = AdaptiveEngine()
    profile = DataProfile("AAPL", :stock, 0.6, :normal, :normal,
                          :bullish, :normal, :neutral, Inf, 0.0)

    strategy = select_models(profile, engine)

    @test !isempty(strategy.model_ids)
    @test strategy.strategy_type in [:trend_follow, :mean_revert, :arb, :mm, :event_driven]
    @test strategy.kelly_multiplier > 0.0
    @test !isempty(strategy.reasoning)

    # Trending stock should include LSTM/GRU
    @test 1 in strategy.model_ids || 2 in strategy.model_ids || 34 in strategy.model_ids
end

@testset "select_models polymarket" begin
    engine = AdaptiveEngine()
    profile = DataProfile("poly:election", :polymarket, 0.1, :normal, :normal,
                          :neutral, :normal, :neutral, 24.0, 0.0)

    strategy = select_models(profile, engine)

    @test strategy.strategy_type in [:event_driven, :mean_revert]  # regime routing may override
    @test 31 in strategy.model_ids  # Kalman filter
    @test strategy.urgency == :immediate  # near expiry
    @test strategy.kelly_multiplier < 1.0  # reduced near expiry
end

@testset "select_models extreme vol" begin
    engine = AdaptiveEngine()
    profile = DataProfile("BTC-USD", :crypto, 0.0, :extreme, :heavy,
                          :bearish, :wide, :distribution, Inf, 0.0)

    strategy = select_models(profile, engine)

    @test strategy.kelly_multiplier < 0.5  # heavily reduced
    @test strategy.strategy_type == :mean_revert
end

@testset "select_models adapts from history" begin
    engine = AdaptiveEngine()

    # Record poor performance for model 5 in bull regime (need 500+ for demotion)
    for _ in 1:510
        record_model_outcome!(engine, 5, :bull, false, -10.0)
    end

    profile = DataProfile("AAPL", :stock, 0.6, :normal, :normal,
                          :bullish, :normal, :neutral, Inf, 0.0)

    strategy = select_models(profile, engine)

    # Model 5 should be demoted after 500+ bad predictions
    @test !(5 in strategy.model_ids)
end

# ── Goal Tracking ────────────────────────────────────────────

@testset "goal_progress" begin
    engine = AdaptiveEngine(goal_target=10_000_000.0, initial_bankroll=10_000.0)

    progress = goal_progress(engine)
    @test progress.completion_pct ≈ 0.1 atol=0.01  # 10k/10M = 0.1%
    @test progress.current_bankroll == 10_000.0
    @test progress.target == 10_000_000.0
end

@testset "goal_progress after growth" begin
    engine = AdaptiveEngine(goal_target=10_000_000.0, initial_bankroll=10_000.0)
    update_bankroll!(engine, 15_000.0)

    progress = goal_progress(engine)
    @test progress.current_bankroll == 15_000.0
    @test progress.total_return_pct ≈ 50.0 atol=1.0
    @test progress.completion_pct > 0.1
end

@testset "model_leaderboard" begin
    engine = AdaptiveEngine()

    record_model_outcome!(engine, 7, :bull, true, 50.0)
    record_model_outcome!(engine, 7, :bull, true, 30.0)
    record_model_outcome!(engine, 7, :bull, false, -20.0)
    record_model_outcome!(engine, 7, :bull, true, 40.0)
    record_model_outcome!(engine, 7, :bull, true, 25.0)

    record_model_outcome!(engine, 14, :bull, true, 10.0)
    record_model_outcome!(engine, 14, :bull, false, -30.0)
    record_model_outcome!(engine, 14, :bull, false, -20.0)
    record_model_outcome!(engine, 14, :bull, true, 15.0)
    record_model_outcome!(engine, 14, :bull, false, -25.0)

    board = model_leaderboard(engine, :bull)
    @test length(board) == 2
    @test board[1].model_id == 7  # better accuracy → first
    @test board[1].accuracy > board[2].accuracy
end

# ── Minute Bar Window ────────────────────────────────────────

@testset "MinuteBarWindow" begin
    window = MinuteBarWindow("BTC-USD"; max_bars=100)

    for i in 1:50
        add_bar!(window, 100.0 + i * 0.1, 1000.0 + i, 101.0, 99.0, now())
    end

    @test bar_count(window) == 50

    snap = window_snapshot(window)
    @test snap.n == 50
    @test length(snap.prices) == 50
end

@testset "MinuteBarWindow bounded" begin
    window = MinuteBarWindow("TEST"; max_bars=10)

    for i in 1:20
        add_bar!(window, Float64(i), 100.0, Float64(i+1), Float64(i-1), now())
    end

    @test bar_count(window) == 10  # bounded
    snap = window_snapshot(window)
    @test snap.prices[1] == 11.0  # oldest dropped
end

@testset "aggregate_bars" begin
    window = MinuteBarWindow("TEST"; max_bars=100)

    for i in 1:20
        add_bar!(window, Float64(100 + i), Float64(i * 1000),
                 Float64(101 + i), Float64(99 + i), now() + Minute(i))
    end

    agg = aggregate_bars(window, 5)  # 5-minute bars
    @test agg.n == 4  # 20 / 5 = 4 bars
    @test length(agg.prices) == 4
    @test agg.volumes[1] > 0  # summed volumes
end

@testset "MinuteDataManager" begin
    manager = MinuteDataManager(max_bars=100)

    ingest_tick!(manager, "BTC-USD", 45000.0, 1e6)
    ingest_tick!(manager, "ETH-USD", 3000.0, 5e5)
    ingest_tick!(manager, "BTC-USD", 45010.0, 1.1e6)

    @test bar_count(get_window!(manager, "BTC-USD")) == 2
    @test bar_count(get_window!(manager, "ETH-USD")) == 1
end

@testset "should_analyze" begin
    window = MinuteBarWindow("TEST"; max_bars=100)

    # Not enough bars
    for i in 1:10
        add_bar!(window, 100.0, 1000.0, 101.0, 99.0, now())
    end
    @test !should_analyze(window; min_bars=30)

    # Enough bars, on the interval
    for i in 1:25
        add_bar!(window, 100.0, 1000.0, 101.0, 99.0, now())
    end
    @test should_analyze(window; min_bars=30, analyze_every_n=5)
end
