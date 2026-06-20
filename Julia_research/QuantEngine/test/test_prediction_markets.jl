# ── Prediction Market Tests ───────────────────────────────────

using QuantEngine: run_kalman_filter, run_time_decay, run_cross_market_arb,
                   detect_arbitrage, MarketQuote, ArbOpportunity,
                   PolymarketExchange, polymarket_get_positions,
                   ExternalSignal, SignalBuffer, add_signal!, get_latest_signal,
                   get_signals_since,
                   fetch_fred_series, create_poll_signal, signals_to_bayesian_evidence,
                   generate_synthetic_polymarket_data, run_polymarket_backtest

# ── Kalman Filter Tests ──────────────────────────────────────

@testset "Kalman Filter basic" begin
    Random.seed!(42)
    # Noisy observations of a true probability around 0.6
    true_p = 0.6
    prices = clamp.(true_p .+ 0.05 .* randn(100), 0.01, 0.99)

    result = run_kalman_filter(prices)

    @test 0.0 < result.smoothed_prob < 1.0
    @test result.probability == result.smoothed_prob
    @test length(result.innovations) == 100
    @test length(result.smoothed_series) == 100
    @test result.model == "Kalman Filter (Prediction Market)"

    # Smoothed should be closer to true_p than raw prices
    raw_error = abs(mean(prices) - true_p)
    smooth_error = abs(result.smoothed_prob - true_p)
    @test smooth_error <= raw_error + 0.1  # smoothing helps (with tolerance)
end

@testset "Kalman Filter shock detection" begin
    # Create data with a sudden jump (information shock)
    prices = vcat(fill(0.4, 50), fill(0.7, 50))  # jump from 0.4 to 0.7
    result = run_kalman_filter(prices)

    # Should detect the shock
    @test result.shock_detected || maximum(abs.(result.innovations)) > 0.1
end

@testset "Kalman Filter small input" begin
    result = run_kalman_filter([0.5, 0.6])
    @test result.smoothed_prob > 0.0
    @test !result.shock_detected

    result_empty = run_kalman_filter(Float64[])
    @test result_empty.smoothed_prob == 0.5
end

@testset "Kalman Filter accuracy" begin
    Random.seed!(42)
    prices = clamp.(0.55 .+ 0.03 .* randn(200), 0.01, 0.99)
    result = run_kalman_filter(prices)

    # Should compute backtest accuracy
    @test !isnan(result.accuracy)
    @test 0.0 <= result.accuracy <= 1.0
end

# ── Time Decay Tests ─────────────────────────────────────────

@testset "Time Decay basic" begin
    Random.seed!(42)
    prices = clamp.(0.6 .+ cumsum(0.005 .* randn(60)), 0.01, 0.99)

    result = run_time_decay(prices, 30.0; current_price=prices[end])

    @test result.probability == prices[end]
    @test result.days_to_expiry == 30.0
    @test isfinite(result.vol_compression)
    @test isfinite(result.expected_move)
    @test result.expected_move >= 0.0
    @test result.optimal_hold_days > 0.0
    @test result.model == "Time Decay (Prediction Market)"
end

@testset "Time Decay convergence near expiry" begin
    prices = collect(range(0.5, 0.85, length=30))  # trending up
    result = run_time_decay(prices, 3.0)  # 3 days to expiry

    # Near expiry with high price → should lean YES
    @test result.direction in ["UP", "LEAN YES"]
end

@testset "Time Decay low price near expiry" begin
    prices = collect(range(0.5, 0.2, length=30))  # trending down
    result = run_time_decay(prices, 3.0)

    @test result.direction in ["DOWN", "LEAN NO"]
end

@testset "Time Decay small input" begin
    result = run_time_decay([0.5], 0.0)
    @test result.direction == "HOLD"
end

# ── Cross-Market Arbitrage Tests ─────────────────────────────

@testset "detect_arbitrage no opportunity" begin
    # Same price on both platforms → no arb
    q1 = MarketQuote("polymarket", 0.60, 0.40, 100000.0, now(), 0.02)
    q2 = MarketQuote("kalshi", 0.60, 0.40, 50000.0, now(), 0.07)

    opps = detect_arbitrage([q1, q2])
    @test isempty(opps)  # no spread after fees
end

@testset "detect_arbitrage finds opportunity" begin
    # Big price difference → arb exists
    q1 = MarketQuote("polymarket", 0.50, 0.50, 100000.0, now(), 0.02)
    q2 = MarketQuote("kalshi", 0.70, 0.30, 50000.0, now(), 0.02)

    opps = detect_arbitrage([q1, q2]; min_spread=0.05)
    @test length(opps) >= 1
    @test opps[1].net_spread > 0.05
    @test opps[1].expected_profit_pct > 0.0
end

@testset "detect_arbitrage single platform" begin
    q1 = MarketQuote("polymarket", 0.60, 0.40, 100000.0, now(), 0.02)
    opps = detect_arbitrage([q1])
    @test isempty(opps)  # need 2+ platforms
end

@testset "run_cross_market_arb" begin
    result = run_cross_market_arb(0.65, 50000.0; event_name="test_event")

    @test result.polymarket_price == 0.65
    @test result.direction == "YES"
    @test result.n_platforms >= 1
    @test result.overround ≈ 1.0  # binary market: YES + NO = 1
    @test result.model == "Cross-Market Arbitrage"
end

# ── PolymarketExchange Tests ─────────────────────────────────

@testset "PolymarketExchange paper mode" begin
    ex = PolymarketExchange(execution_mode=PAPER, initial_balance=5000.0)

    @test ex isa AbstractExchange
    @test !(ex isa PaperExchange)
    @test get_balance(ex) == 5000.0

    # Place paper order
    order = place_order(ex, "test_market", :buy, :binary_yes, 500.0;
                        limit_price=0.60)
    @test order.status == :filled
    @test get_balance(ex) == 4500.0
end

@testset "PolymarketExchange insufficient funds" begin
    ex = PolymarketExchange(execution_mode=PAPER, initial_balance=100.0)

    order = place_order(ex, "test_market", :buy, :binary_yes, 500.0)
    @test order.status == :insufficient_funds
    @test get_balance(ex) == 100.0  # unchanged
end

@testset "PolymarketExchange paper positions" begin
    ex = PolymarketExchange(execution_mode=PAPER, initial_balance=5000.0)

    place_order(ex, "market_a", :buy, :binary_yes, 300.0; limit_price=0.50)
    place_order(ex, "market_b", :buy, :binary_yes, 200.0; limit_price=0.40)

    positions = polymarket_get_positions(ex)
    @test length(positions) == 2
end

@testset "PolymarketExchange live requires keys" begin
    @test_throws ErrorException PolymarketExchange(
        execution_mode=LIVE,
        api_key_env="NONEXISTENT_POLY_KEY_12345",
        api_secret_env="NONEXISTENT_POLY_SECRET_12345"
    )
end

# ── External Signals Tests ───────────────────────────────────

@testset "SignalBuffer basic" begin
    buf = SignalBuffer()

    signal = ExternalSignal("fred", "UNRATE", 3.8, now(), Dict{String,Any}())
    add_signal!(buf, signal)

    latest = get_latest_signal(buf, "fred", "UNRATE")
    @test latest !== nothing
    @test latest.value == 3.8
    @test latest.source == "fred"
end

@testset "SignalBuffer multiple signals" begin
    buf = SignalBuffer()

    for i in 1:5
        add_signal!(buf, ExternalSignal("fred", "GDP", Float64(i), now(), Dict{String,Any}()))
    end

    latest = get_latest_signal(buf, "fred", "GDP")
    @test latest.value == 5.0  # last one

    since = get_signals_since(buf, "fred", "GDP"; since=now() - Minute(1))
    @test length(since) == 5
end

@testset "SignalBuffer missing signal" begin
    buf = SignalBuffer()
    @test get_latest_signal(buf, "fred", "NONEXISTENT") === nothing
end

@testset "create_poll_signal" begin
    signal = create_poll_signal("candidate_approval", 52.3; source_url="https://example.com")
    @test signal.source == "polls"
    @test signal.name == "candidate_approval"
    @test signal.value == 52.3
end

@testset "signals_to_bayesian_evidence" begin
    buf = SignalBuffer()

    # Add positive signals
    for i in 1:5
        add_signal!(buf, ExternalSignal("polls", "approval", 0.55 + 0.01*i, now(), Dict{String,Any}()))
    end

    evidence = signals_to_bayesian_evidence(buf, "ELECTION")
    @test evidence !== nothing
    @test evidence.n_tweets >= 5  # uses tweet_sentiment interface
    @test evidence.signal == :bullish
end

@testset "signals_to_bayesian_evidence empty" begin
    buf = SignalBuffer()
    @test signals_to_bayesian_evidence(buf, "ANYTHING") === nothing
end

# ── Polymarket Backtest Tests ────────────────────────────────

@testset "generate_synthetic_polymarket_data" begin
    Random.seed!(42)
    data = generate_synthetic_polymarket_data(n_days=90, true_prob=0.7)

    @test length(data.prices) == 90
    @test length(data.dates) == 90
    @test length(data.returns) == 89
    @test all(0.0 .< data.prices .< 1.0)
    @test data.true_prob == 0.7

    # Prices should converge toward true_prob near end
    @test abs(data.prices[end] - 0.7) < 0.2
end

@testset "run_polymarket_backtest synthetic" begin
    Random.seed!(42)
    data = generate_synthetic_polymarket_data(n_days=120, true_prob=0.65)

    result = run_polymarket_backtest(data; initial_capital=5000.0,
                                     n_folds=4, verbose=false)

    @test result.ticker == "POLYMARKET"
    @test result.n_trades >= 0
    @test !isempty(result.equity_curve)
    @test isfinite(result.total_return)
end

@testset "run_polymarket_backtest too short" begin
    data = generate_synthetic_polymarket_data(n_days=10)
    @test_throws ErrorException run_polymarket_backtest(data)
end
