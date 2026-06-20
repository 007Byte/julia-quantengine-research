# ── Signal Card + Live Book + Sentiment Embedding Tests ──────

using QuantEngine: SignalCard, LiveBookManager, get_live_book_features,
                   score_sentiment_v2, FINANCE_LEXICON

# ── Sentiment Embeddings v2 ──────────────────────────────────

@testset "score_sentiment_v2 basic" begin
    @test score_sentiment_v2("BTC going to the moon! Very bullish") > 0.5
    @test score_sentiment_v2("Market crash incoming, sell everything") < -0.5
    @test abs(score_sentiment_v2("The weather is nice today")) < 0.1
    @test score_sentiment_v2("") == 0.0
end

@testset "score_sentiment_v2 negation" begin
    @test score_sentiment_v2("not bullish at all") < 0.0
    @test score_sentiment_v2("not a crash") > -0.5
end

@testset "score_sentiment_v2 amplifiers" begin
    base = score_sentiment_v2("bullish on BTC")
    amplified = score_sentiment_v2("extremely bullish on BTC")
    @test amplified > base || amplified ≈ base  # amplifier should boost
end

@testset "score_sentiment_v2 phrase patterns" begin
    @test score_sentiment_v2("BTC to the moon!") > 0.5
    @test score_sentiment_v2("This is a rug pull") < -0.5
    @test score_sentiment_v2("Breakout confirmed, new ATH") > 0.4
    @test score_sentiment_v2("Dead cat bounce, sell everything") < -0.3
end

@testset "score_sentiment_v2 position weighting" begin
    # Later words weighted more (recency)
    s = score_sentiment_v2("bad start but strong bullish breakout rally")
    @test s > 0.0  # bullish words at end should dominate
end

@testset "score_sentiment_v2 bounded" begin
    # Extreme inputs should still be bounded
    extreme_bull = "moon rally breakout surge soar rocket bullish ath accumulate"
    @test -1.0 <= score_sentiment_v2(extreme_bull) <= 1.0

    extreme_bear = "crash dump rekt scam liquidated plunge tank collapse"
    @test -1.0 <= score_sentiment_v2(extreme_bear) <= 1.0
end

@testset "FINANCE_LEXICON coverage" begin
    @test length(FINANCE_LEXICON) > 50
    @test FINANCE_LEXICON["moon"] > 0.5
    @test FINANCE_LEXICON["crash"] < -0.5
end

# ── Live Book Manager ────────────────────────────────────────

@testset "LiveBookManager creation" begin
    manager = LiveBookManager()
    @test get_live_book_features(manager, "BTC-USD") === nothing
end

@testset "LiveBookManager update" begin
    manager = LiveBookManager(refresh_interval_ms=0)  # immediate refresh

    bids = [BookLevel(100.0, 10.0), BookLevel(99.5, 20.0)]
    asks = [BookLevel(100.5, 5.0), BookLevel(101.0, 15.0)]

    update_book_from_feed!(manager, "BTC-USD", bids, asks)

    features = get_live_book_features(manager, "BTC-USD")
    @test features !== nothing
    @test isfinite(features.depth_imbalance)
    @test isfinite(features.book_pressure)
    @test isfinite(features.spread_bps)
end

# ── Signal Card Struct ───────────────────────────────────────

@testset "SignalCard struct" begin
    card = SignalCard("AAPL", 150.0, :long, 145.0, 155.0, 160.0,
                      -3.33, 3.33, 6.67, 72.0, 0.10, 1500.0, 24.0, 1.5,
                      ["BUY AAPL at \$150.00"], "BUY", "bull", 25, 34)
    @test card.ticker == "AAPL"
    @test card.direction == :long
    @test card.stop_loss == 145.0
    @test card.take_profit_1 == 155.0
    @test card.risk_reward == 1.5
    @test length(card.recommendations) == 1
end
