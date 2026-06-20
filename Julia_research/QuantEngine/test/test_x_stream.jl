# ── X (Twitter) Stream Tests ──────────────────────────────────

using QuantEngine: TweetBuffer, add_tweet!, get_recent_tweets, get_tweet_sentiment,
                   score_sentiment, detect_tweet_asset, _process_tweet!,
                   BULLISH_WORDS, BEARISH_WORDS

@testset "score_sentiment" begin
    # Bullish text
    @test score_sentiment("BTC going to the moon, very bullish!") > 0.3
    @test score_sentiment("Time to buy the dip, rally incoming") > 0.3

    # Bearish text
    @test score_sentiment("Market crash incoming, sell everything") < -0.3
    @test score_sentiment("This is a scam, going to dump hard") < -0.3

    # Neutral text
    @test abs(score_sentiment("The weather is nice today")) < 0.1
    @test abs(score_sentiment("")) == 0.0

    # Amplifiers increase magnitude
    s_normal = score_sentiment("bullish on BTC")
    s_amplified = score_sentiment("extremely bullish on BTC")
    @test s_amplified >= s_normal

    # Mixed signals
    s_mixed = score_sentiment("buy the dip but fear the crash")
    @test abs(s_mixed) < 0.5  # conflicting signals → moderate

    # Score is bounded [-1, 1]
    @test -1.0 <= score_sentiment("buy buy buy moon rocket pump") <= 1.0
    @test -1.0 <= score_sentiment("sell crash dump panic fear rekt") <= 1.0
end

@testset "detect_tweet_asset" begin
    assets = ["AAPL", "BTC-USD", "ETH-USD", "MSFT"]

    @test detect_tweet_asset("\$AAPL looking strong today", assets) == "AAPL"
    @test detect_tweet_asset("Bitcoin pumping hard", assets) == "BTC-USD"
    @test detect_tweet_asset("Ethereum merge complete", assets) == "ETH-USD"
    @test detect_tweet_asset("\$MSFT earnings beat", assets) == "MSFT"

    # No match
    @test detect_tweet_asset("The weather is nice", assets) == ""
    @test detect_tweet_asset("Random tweet about nothing", assets) == ""
end

@testset "TweetBuffer creation and add" begin
    buf = TweetBuffer(max_size=5)
    @test isempty(buf.tweets)

    tweet = (text="Test tweet", sentiment=0.5, asset="AAPL", timestamp=now())
    add_tweet!(buf, tweet)
    @test length(buf.tweets) == 1
end

@testset "TweetBuffer bounded size" begin
    buf = TweetBuffer(max_size=3)

    for i in 1:5
        add_tweet!(buf, (text="Tweet $i", sentiment=0.1*i, asset="AAPL", timestamp=now()))
    end

    @test length(buf.tweets) == 3  # bounded to max_size
    @test buf.tweets[1].text == "Tweet 3"  # oldest dropped
end

@testset "get_recent_tweets filtering" begin
    buf = TweetBuffer(max_size=100)

    # Add tweets for different assets
    add_tweet!(buf, (text="AAPL up", sentiment=0.5, asset="AAPL", timestamp=now()))
    add_tweet!(buf, (text="BTC down", sentiment=-0.5, asset="BTC-USD", timestamp=now()))
    add_tweet!(buf, (text="AAPL more", sentiment=0.3, asset="AAPL", timestamp=now()))

    aapl_tweets = get_recent_tweets(buf, "AAPL")
    @test length(aapl_tweets) == 2

    btc_tweets = get_recent_tweets(buf, "BTC-USD")
    @test length(btc_tweets) == 1

    msft_tweets = get_recent_tweets(buf, "MSFT")
    @test isempty(msft_tweets)
end

@testset "get_tweet_sentiment" begin
    buf = TweetBuffer(max_size=100)

    # No tweets → neutral
    sentiment = get_tweet_sentiment(buf, "AAPL")
    @test sentiment.n_tweets == 0
    @test sentiment.signal == :neutral

    # Add bullish tweets
    for _ in 1:5
        add_tweet!(buf, (text="AAPL bullish", sentiment=0.6, asset="AAPL", timestamp=now()))
    end

    sentiment = get_tweet_sentiment(buf, "AAPL")
    @test sentiment.n_tweets == 5
    @test sentiment.avg_score > 0.3
    @test sentiment.bullish_pct > 50.0
    @test sentiment.signal == :bullish
end

@testset "get_tweet_sentiment bearish" begin
    buf = TweetBuffer(max_size=100)

    for _ in 1:5
        add_tweet!(buf, (text="BTC crash", sentiment=-0.7, asset="BTC-USD", timestamp=now()))
    end

    sentiment = get_tweet_sentiment(buf, "BTC-USD")
    @test sentiment.signal == :bearish
    @test sentiment.avg_score < -0.3
    @test sentiment.bearish_pct > 50.0
end

@testset "_process_tweet! integration" begin
    buf = TweetBuffer(max_size=100)
    received = Ref{String}("")

    _process_tweet!("BTC going to the moon! Very bullish \$BTC",
                    ["BTC-USD", "AAPL"], buf,
                    (asset, sentiment, text) -> received[] = asset)

    @test length(buf.tweets) == 1
    @test buf.tweets[1].asset == "BTC-USD"
    @test buf.tweets[1].sentiment > 0
    @test received[] == "BTC-USD"
end

@testset "_process_tweet! ignores irrelevant" begin
    buf = TweetBuffer(max_size=100)
    callback_count = Ref(0)

    _process_tweet!("The weather is nice today",
                    ["BTC-USD", "AAPL"], buf,
                    (a, s, t) -> callback_count[] += 1)

    @test isempty(buf.tweets)  # no asset match → not buffered
    @test callback_count[] == 0
end

@testset "Bayesian model with tweet sentiment" begin
    using QuantEngine: run_bayesian

    Random.seed!(42)
    returns = 0.001 .+ 0.02 .* randn(200)
    results = Dict{String,Any}()

    # Without tweets
    r1 = run_bayesian(returns, results)
    @test 0.0 < r1.posterior < 1.0
    @test r1.tweet_count == 0

    # With bullish tweets
    tweet_sent = (sentiment=0.6, n_tweets=10, bullish_pct=80.0,
                  bearish_pct=20.0, avg_score=0.5, signal=:bullish)
    r2 = run_bayesian(returns, results; tweet_sentiment=tweet_sent)
    @test r2.tweet_bullish == true
    @test r2.tweet_count == 10
    @test r2.posterior >= r1.posterior  # bullish tweets should push posterior up

    # With bearish tweets
    tweet_bear = (sentiment=-0.6, n_tweets=10, bullish_pct=20.0,
                  bearish_pct=80.0, avg_score=-0.5, signal=:bearish)
    r3 = run_bayesian(returns, results; tweet_sentiment=tweet_bear)
    @test r3.tweet_bearish == true
    @test r3.posterior <= r1.posterior  # bearish tweets should push posterior down
end

@testset "start_x_stream requires token" begin
    buf = TweetBuffer()
    @test_throws ErrorException start_x_stream(
        ["BTC"], ["BTC-USD"], buf;
        bearer_token_env="NONEXISTENT_X_TOKEN_12345"
    )
end

@testset "TweetBuffer thread safety" begin
    buf = TweetBuffer(max_size=200)

    tasks = Task[]
    for i in 1:20
        push!(tasks, @async begin
            add_tweet!(buf, (text="Tweet $i", sentiment=rand(), asset="AAPL", timestamp=now()))
        end)
    end
    for t in tasks; wait(t); end

    @test length(buf.tweets) == 20
end
