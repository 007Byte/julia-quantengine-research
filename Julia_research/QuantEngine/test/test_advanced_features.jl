# ── Advanced Features Tests ───────────────────────────────────

using QuantEngine: BookLevel, OrderBookSnapshot, OrderBookCache,
                   update_book!, get_book, compute_book_features,
                   CorrelationTracker, add_return!, asset_correlation,
                   correlation_matrix, correlation_adjusted_kelly,
                   portfolio_correlation_risk,
                   ModelRegistry, register_model!, registered_model_ids,
                   run_registered_model, is_registered, get_registry,
                   MMConfig, MMQuote, compute_mm_quotes, should_market_make

# ── Order Book Tests ─────────────────────────────────────────

@testset "OrderBookSnapshot creation" begin
    book = OrderBookSnapshot("BTC-USD")
    @test book.asset == "BTC-USD"
    @test isempty(book.bids)
    @test isempty(book.asks)
end

@testset "OrderBookCache update and get" begin
    cache = OrderBookCache()

    bids = [BookLevel(100.0, 5.0), BookLevel(99.5, 10.0), BookLevel(99.0, 15.0)]
    asks = [BookLevel(100.5, 3.0), BookLevel(101.0, 8.0), BookLevel(101.5, 12.0)]

    update_book!(cache, "BTC-USD", bids, asks)

    book = get_book(cache, "BTC-USD")
    @test book !== nothing
    @test length(book.bids) == 3
    @test length(book.asks) == 3
    @test book.bids[1].price == 100.0  # best bid first
    @test book.asks[1].price == 100.5  # best ask first
end

@testset "compute_book_features" begin
    book = OrderBookSnapshot("TEST")
    book.bids = [BookLevel(100.0, 10.0), BookLevel(99.5, 20.0)]
    book.asks = [BookLevel(100.5, 5.0), BookLevel(101.0, 15.0)]

    features = compute_book_features(book)

    @test features.bid_ask_spread ≈ 0.5
    @test features.spread_bps > 0
    @test -1.0 <= features.depth_imbalance <= 1.0
    @test features.bid_depth > 0
    @test features.ask_depth > 0
    @test isfinite(features.weighted_mid)
    @test features.weighted_mid > 99.0
    @test features.weighted_mid < 101.0
end

@testset "compute_book_features empty book" begin
    book = OrderBookSnapshot("EMPTY")
    features = compute_book_features(book)
    @test isnan(features.bid_ask_spread)
end

@testset "compute_book_features depth imbalance" begin
    # Heavy buy side → positive imbalance
    book = OrderBookSnapshot("BUY-HEAVY")
    book.bids = [BookLevel(100.0, 100.0)]  # big bid
    book.asks = [BookLevel(100.5, 1.0)]     # tiny ask

    features = compute_book_features(book)
    @test features.depth_imbalance > 0.5  # strong buy pressure
end

# ── Correlation Tests ────────────────────────────────────────

@testset "CorrelationTracker basic" begin
    tracker = CorrelationTracker(window=30)

    Random.seed!(42)
    # Add correlated returns (BTC and ETH move together)
    for _ in 1:30
        r = randn() * 0.02
        add_return!(tracker, "BTC-USD", r)
        add_return!(tracker, "ETH-USD", r + randn() * 0.005)  # correlated
        add_return!(tracker, "AAPL", randn() * 0.01)            # uncorrelated
    end

    # BTC-ETH should be highly correlated
    btc_eth = asset_correlation(tracker, "BTC-USD", "ETH-USD")
    @test btc_eth > 0.5

    # BTC-AAPL should be weakly correlated
    btc_aapl = asset_correlation(tracker, "BTC-USD", "AAPL")
    @test abs(btc_aapl) < abs(btc_eth)
end

@testset "correlation_matrix" begin
    tracker = CorrelationTracker(window=20)
    Random.seed!(42)
    for _ in 1:20
        add_return!(tracker, "A", randn())
        add_return!(tracker, "B", randn())
    end

    result = correlation_matrix(tracker)
    @test length(result.assets) == 2
    @test size(result.matrix) == (2, 2)
    @test result.matrix[1,1] ≈ 1.0  # self-correlation
    @test result.matrix[2,2] ≈ 1.0
end

@testset "correlation_adjusted_kelly" begin
    tracker = CorrelationTracker(window=20)
    Random.seed!(42)
    for _ in 1:20
        r = randn()
        add_return!(tracker, "BTC-USD", r)
        add_return!(tracker, "ETH-USD", r * 0.9)  # very correlated
    end

    # Kelly should be reduced when adding ETH while holding BTC
    base_kelly = 0.10
    adjusted = correlation_adjusted_kelly(base_kelly, "ETH-USD", ["BTC-USD"], tracker)

    @test adjusted < base_kelly  # reduced due to high correlation
    @test adjusted > 0.0

    # No existing positions → no reduction
    no_adj = correlation_adjusted_kelly(base_kelly, "ETH-USD", String[], tracker)
    @test no_adj == base_kelly
end

@testset "portfolio_correlation_risk" begin
    tracker = CorrelationTracker(window=20)
    Random.seed!(42)
    for _ in 1:20
        r = randn()
        add_return!(tracker, "A", r)
        add_return!(tracker, "B", r * 0.95)  # very correlated
    end

    risk = portfolio_correlation_risk(tracker, ["A", "B"])
    @test risk > 0.5  # high correlation = high risk

    # Single position = no correlation risk
    @test portfolio_correlation_risk(tracker, ["A"]) == 0.0
end

# ── Model Registry Tests ─────────────────────────────────────

@testset "register_model! and retrieve" begin
    registry = get_registry()

    register_model!(99, "Test Model", :fast,
                    (ctx) -> (probability=0.55, accuracy=0.6, model="TestRegistered"))

    @test is_registered(99)
    @test !is_registered(9999)

    ids = registered_model_ids()
    @test 99 in ids
end

@testset "run_registered_model" begin
    register_model!(98, "Another Test", :fast,
                    (ctx) -> (probability=0.7, accuracy=0.65, model="Test98"))

    result = run_registered_model(98, nothing)
    @test result !== nothing
    @test result.probability == 0.7
end

@testset "registered model phases" begin
    register_model!(97, "Fast Test", :fast, (ctx) -> nothing)
    register_model!(96, "Heavy Test", :heavy, (ctx) -> nothing)
    register_model!(95, "Phase2 Test", :phase2, (ctx) -> nothing)

    fast = registered_fast_models()
    @test 97 in fast

    heavy = registered_heavy_models()
    @test 96 in heavy
end

# ── Market-Making Tests ──────────────────────────────────────

@testset "compute_mm_quotes basic" begin
    config = MMConfig()
    mm = compute_mm_quotes(0.60, 0.02; config=config)

    @test mm.bid_price < mm.ask_price
    @test mm.fair_price ≈ 0.60
    @test mm.spread > 0
    @test mm.bid_size > 0
    @test mm.ask_size > 0
    @test mm.edge_per_share > 0  # should be profitable
end

@testset "compute_mm_quotes inventory skew" begin
    config = MMConfig()

    # No inventory: symmetric
    mm_neutral = compute_mm_quotes(0.50, 0.02, 0.0; config=config)

    # Long inventory: should lower bid, raise ask
    mm_long = compute_mm_quotes(0.50, 0.02, 200.0; config=config)

    @test mm_long.bid_price < mm_neutral.bid_price  # less aggressive buying
    @test mm_long.ask_price < mm_neutral.ask_price   # more aggressive selling
end

@testset "should_market_make" begin
    config = MMConfig(min_volume=10000.0)

    # Good opportunity
    result = should_market_make(50000.0, 0.03, 0.50; config=config)
    @test result.make == true

    # Low volume
    result = should_market_make(100.0, 0.03, 0.50; config=config)
    @test result.make == false

    # Extreme probability (near resolution)
    result = should_market_make(50000.0, 0.03, 0.98; config=config)
    @test result.make == false

    # Tight spread
    result = should_market_make(50000.0, 0.01, 0.50; config=config)
    @test result.make == false
end
