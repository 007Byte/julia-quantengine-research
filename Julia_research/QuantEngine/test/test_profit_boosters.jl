# ── Profit Booster Tests ──────────────────────────────────────

using QuantEngine: run_kelly, run_ev_gap, score_sentiment, ABConfig, ABTest,
                   create_ab_test, record_signal!, arm_stats, check_ab_winner!,
                   create_default_ab_test, get_cached_for_incremental,
                   NEGATORS

# ── Microstructure Features ──────────────────────────────────

@testset "18-feature compute_features" begin
    Random.seed!(42)
    n = 300
    prices = cumsum(randn(n)) .+ 100.0
    prices = max.(prices, 1.0)
    returns = diff(log.(prices))
    volumes = abs.(randn(n)) .* 1e6 .+ 1.0
    high = prices .+ abs.(randn(n)) .* 0.5
    low = prices .- abs.(randn(n)) .* 0.5

    X, y, _, _ = compute_features(prices, returns, volumes; high=high, low=low)

    @test size(X, 2) == 18  # 9 base + 2 fracdiff + 3 microstructure + 3 new + 1
    @test !any(isnan, X)

    # Feature 12 (Spread proxy) should be finite after standardization
    @test all(isfinite, X[:, 12])

    # Feature 13 (Order imbalance) should be finite
    @test all(isfinite, X[:, 13])

    # Feature 14 (Trade velocity) should be finite
    @test all(isfinite, X[:, 14])
end

# ── Dynamic Kelly ────────────────────────────────────────────

@testset "Kelly regime awareness" begin
    Random.seed!(42)
    returns = 0.001 .+ 0.02 .* randn(500)

    k_neutral = run_kelly(returns; regime=:neutral)
    k_volatile = run_kelly(returns; regime=:volatile)
    k_trending = run_kelly(returns; regime=:trending)

    # Volatile regime should produce smaller Kelly fraction
    @test abs(k_volatile.kelly_full) <= abs(k_neutral.kelly_full) + 0.01

    # Trending regime should produce larger Kelly fraction
    @test abs(k_trending.kelly_full) >= abs(k_neutral.kelly_full) - 0.01
end

@testset "Kelly cost adjustment" begin
    Random.seed!(42)
    returns = 0.001 .+ 0.02 .* randn(500)

    k_low_cost = run_kelly(returns; cost_bps=1.0, slippage_bps=1.0)
    k_high_cost = run_kelly(returns; cost_bps=50.0, slippage_bps=50.0)

    # Higher costs should reduce Kelly fraction (less attractive bets)
    @test k_high_cost.kelly_full <= k_low_cost.kelly_full + 0.05
end

# ── Dynamic EV Gap ───────────────────────────────────────────

@testset "EV Gap dynamic threshold" begin
    results = Dict{String,Any}(
        "Model A" => (probability=0.65, accuracy=0.6)
    )

    # Low vol: threshold should be lower → easier to trigger BUY
    ev_low_vol = run_ev_gap(results, 0.52, :stock; daily_vol=0.01)

    # High vol: threshold should be higher → harder to trigger BUY
    ev_high_vol = run_ev_gap(results, 0.52, :stock; daily_vol=0.05)

    @test ev_low_vol.dynamic_threshold < ev_high_vol.dynamic_threshold
end

@testset "EV Gap slippage cost" begin
    results = Dict{String,Any}(
        "Model A" => (probability=0.65, accuracy=0.6)
    )

    ev_no_slip = run_ev_gap(results, 0.52, :stock; slippage_bps=0.0)
    ev_high_slip = run_ev_gap(results, 0.52, :stock; slippage_bps=50.0)

    # Higher slippage → lower EV after fees
    @test ev_high_slip.ev_after_fees < ev_no_slip.ev_after_fees
    @test ev_high_slip.total_cost > ev_no_slip.total_cost
end

# ── Advanced Sentiment ───────────────────────────────────────

@testset "Sentiment negation handling" begin
    # "not bullish" should be bearish
    @test score_sentiment("This is not bullish at all") < 0.0

    # "not bearish" should be weakly bullish
    @test score_sentiment("This is not bearish") > 0.0

    # Negation with distance: "don't" is far from "crash" so negation expires
    # This tests that the system handles negation range correctly
    @test score_sentiment("not a crash, actually bullish") > -0.5
end

@testset "Sentiment bigram patterns" begin
    @test score_sentiment("BTC going to the moon!!") > 0.5
    @test score_sentiment("This looks like a rug pull") < -0.3
    @test score_sentiment("New ATH incoming, all time high") > 0.3
    @test score_sentiment("Flash crash warning, margin call") < -0.3
end

# ── A/B Testing ──────────────────────────────────────────────

@testset "ABTest creation" begin
    test = create_default_ab_test()
    @test test.arm_a.config.name == "Full-33"
    @test test.arm_b.config.name == "Fast-20"
    @test !test.decided
    @test test.min_trades_to_decide == 30
end

@testset "ABTest record and stats" begin
    config_a = ABConfig("A", [1,2,3], false, 1.0)
    config_b = ABConfig("B", [5,6,7], false, 1.0)
    test = create_ab_test(config_a, config_b; min_trades=5)

    # Arm A wins more
    for _ in 1:10
        record_signal!(test.arm_a, 50.0)   # winning trades
    end
    for _ in 1:10
        record_signal!(test.arm_b, -20.0)  # losing trades
    end

    stats_a = arm_stats(test.arm_a)
    stats_b = arm_stats(test.arm_b)

    @test stats_a.n_trades == 10
    @test stats_a.total_pnl == 500.0
    @test stats_a.win_rate == 100.0

    @test stats_b.n_trades == 10
    @test stats_b.total_pnl == -200.0
    @test stats_b.win_rate == 0.0
end

@testset "ABTest auto-promotion" begin
    config_a = ABConfig("Winner", [1,2,3], false, 1.0)
    config_b = ABConfig("Loser", [5,6,7], false, 1.0)
    test = create_ab_test(config_a, config_b; min_trades=5)

    # Not enough trades yet
    @test check_ab_winner!(test) == ""

    # Varying PnL so Sharpe can be computed (needs variance > 0)
    for i in 1:6
        record_signal!(test.arm_a, 80.0 + 40.0 * rand())   # positive, varying
        record_signal!(test.arm_b, -30.0 - 40.0 * rand())  # negative, varying
    end

    winner = check_ab_winner!(test)
    @test winner == "Winner"
    @test test.decided == true
end

# ── Incremental Retraining ───────────────────────────────────

@testset "get_cached_for_incremental" begin
    dir = mktempdir()
    cache = WeightCache(dir)

    # Empty cache returns nothing
    @test get_cached_for_incremental(cache, 1, "AAPL", 14) === nothing

    # Store weights
    store_weights!(cache, 1, "AAPL", 14,
        [1.0, 2.0, 3.0], [(2, 1), (1, 1)],
        0.65, 0.42, UInt64(12345))

    # Now should return warm-start θ
    θ_warm = get_cached_for_incremental(cache, 1, "AAPL", 14)
    @test θ_warm !== nothing
    @test θ_warm == [1.0, 2.0, 3.0]

    # Returns a copy (modifying doesn't affect cache)
    θ_warm[1] = 99.0
    θ_warm2 = get_cached_for_incremental(cache, 1, "AAPL", 14)
    @test θ_warm2[1] == 1.0  # original preserved
end
