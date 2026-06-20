# ── X (Twitter) Streaming Feed ────────────────────────────────
# Real-time tweet ingestion via X API v2 filtered stream.
# Feeds sentiment evidence into Bayesian Update (m21) and pipeline triggers.
# Requires QE_X_BEARER_TOKEN (Academic/Enterprise tier).

"""Buffer of recent tweets for sentiment analysis."""
mutable struct TweetBuffer
    tweets::Vector{NamedTuple}     # (text, sentiment, asset, timestamp)
    max_size::Int
    lock::ReentrantLock
end

TweetBuffer(; max_size::Int=500) = TweetBuffer(NamedTuple[], max_size, ReentrantLock())

"""Add a tweet to the buffer (thread-safe, bounded)."""
function add_tweet!(buf::TweetBuffer, tweet::NamedTuple)
    lock(buf.lock) do
        push!(buf.tweets, tweet)
        while length(buf.tweets) > buf.max_size
            popfirst!(buf.tweets)
        end
    end
end

"""Get recent tweets for an asset within a time window (thread-safe)."""
function get_recent_tweets(buf::TweetBuffer, asset::String;
                           window_minutes::Int=30)::Vector{NamedTuple}
    cutoff = now() - Minute(window_minutes)
    lock(buf.lock) do
        return filter(t -> t.asset == asset && t.timestamp >= cutoff, buf.tweets)
    end
end

"""Get aggregate sentiment for an asset from recent tweets."""
function get_tweet_sentiment(buf::TweetBuffer, asset::String;
                              window_minutes::Int=30)
    tweets = get_recent_tweets(buf, asset; window_minutes)
    if isempty(tweets)
        return (sentiment=0.0, n_tweets=0, bullish_pct=50.0, bearish_pct=50.0,
                avg_score=0.0, signal=:neutral)
    end

    scores = [t.sentiment for t in tweets]
    n = length(scores)
    avg = mean(scores)
    bullish = count(s -> s > 0.1, scores)
    bearish = count(s -> s < -0.1, scores)

    signal = if avg > 0.2 && bullish > bearish * 2
        :bullish
    elseif avg < -0.2 && bearish > bullish * 2
        :bearish
    else
        :neutral
    end

    return (sentiment=avg, n_tweets=n,
            bullish_pct=bullish / n * 100.0,
            bearish_pct=bearish / n * 100.0,
            avg_score=avg, signal=signal)
end

# ── Sentiment Scoring ─────────────────────────────────────────

# Keyword-based sentiment (fast, no ML dependency)
const BULLISH_WORDS = Set(["bull", "bullish", "buy", "long", "moon", "pump", "rally",
    "breakout", "green", "profit", "gains", "ath", "higher", "surge", "soar",
    "rocket", "launch", "accumulate", "dip", "cheap", "undervalued", "upgrade"])

const BEARISH_WORDS = Set(["bear", "bearish", "sell", "short", "crash", "dump", "drop",
    "red", "loss", "rekt", "liquidated", "lower", "plunge", "tank",
    "bubble", "overvalued", "downgrade", "warning", "fear", "panic", "scam"])

const AMPLIFIERS = Set(["very", "extremely", "huge", "massive", "insane", "crazy"])
const NEGATORS = Set(["not", "no", "never", "don't", "dont", "won't", "cant", "cannot", "isn't", "aren't"])

"""Score tweet sentiment from -1.0 (bearish) to +1.0 (bullish).
Uses negation-aware keyword matching with amplifiers and bigram patterns."""
function score_sentiment(text::String)::Float64
    words = split(lowercase(text), r"[\s,\.!?;:\-\(\)\[\]\"\']+")
    words = filter(!isempty, words)

    if isempty(words)
        return 0.0
    end

    bull_count = 0.0
    bear_count = 0.0
    amplifier = 1.0
    negated = false

    for (i, word) in enumerate(words)
        if word in NEGATORS
            negated = true
            continue
        end
        if word in AMPLIFIERS
            amplifier = 1.5
            continue
        end

        if word in BULLISH_WORDS
            if negated
                bear_count += amplifier  # "not bullish" = bearish
            else
                bull_count += amplifier
            end
            amplifier = 1.0
            negated = false
        elseif word in BEARISH_WORDS
            if negated
                bull_count += amplifier * 0.5  # "not bearish" = weakly bullish
            else
                bear_count += amplifier
            end
            amplifier = 1.0
            negated = false
        else
            # Reset negation after 2 words without a sentiment word
            if negated && i > 1
                negated = false
            end
            amplifier = 1.0
        end
    end

    # Bigram boost: check for strong 2-word patterns
    text_lower = lowercase(text)
    for pattern in ["to the moon", "all time high", "new ath", "going up",
                     "price target", "strong buy", "accumulate"]
        if occursin(pattern, text_lower)
            bull_count += 1.5
        end
    end
    for pattern in ["dead cat", "going to zero", "rug pull", "exit scam",
                     "liquidation", "margin call", "flash crash"]
        if occursin(pattern, text_lower)
            bear_count += 1.5
        end
    end

    total = bull_count + bear_count
    if total == 0
        return 0.0
    end

    return clamp((bull_count - bear_count) / total, -1.0, 1.0)
end

"""Map a tweet to the relevant asset based on keywords/cashtags."""
function detect_tweet_asset(text::String, watched_assets::Vector{String})::String
    text_upper = uppercase(text)
    for asset in watched_assets
        # Check for cashtag ($AAPL) or plain mention
        ticker = uppercase(replace(asset, "-USD" => "", "poly:" => ""))
        if occursin("\$$ticker", text_upper) || occursin(" $ticker ", " $text_upper ")
            return asset
        end
    end
    # Check for common crypto mentions
    if occursin("BTC", text_upper) || occursin("BITCOIN", text_upper)
        return "BTC-USD"
    elseif occursin("ETH", text_upper) || occursin("ETHEREUM", text_upper)
        return "ETH-USD"
    end
    return ""  # no asset match
end

# ── X API v2 Streaming ────────────────────────────────────────

"""
    start_x_stream(keywords, watched_assets, tweet_buffer; bearer_token_env, callback)

Start streaming tweets from X API v2 filtered stream.
Blocking — run in a @async Task.

Each matching tweet is:
1. Scored for sentiment
2. Mapped to an asset
3. Added to the tweet buffer
4. Passed to the callback function
"""
function start_x_stream(keywords::Vector{String},
                         watched_assets::Vector{String},
                         tweet_buffer::TweetBuffer;
                         bearer_token_env::String="QE_X_BEARER_TOKEN",
                         callback::Function=(asset, sentiment, text) -> nothing)
    token = get(ENV, bearer_token_env, "")
    if isempty(token)
        error("X bearer token not set. Set $bearer_token_env environment variable.")
    end

    headers = ["Authorization" => "Bearer $token",
               "Content-Type" => "application/json"]

    # Set up filter rules (X API v2 filtered stream)
    # First, delete existing rules
    try
        existing = HTTP.get("https://api.twitter.com/2/tweets/search/stream/rules",
                           headers; connect_timeout=10, readtimeout=10)
        rules_data = JSON.parse(String(existing.body))
        rule_ids = [get(r, "id", "") for r in get(rules_data, "data", [])]
        if !isempty(rule_ids)
            HTTP.post("https://api.twitter.com/2/tweets/search/stream/rules",
                     headers,
                     JSON.json(Dict("delete" => Dict("ids" => rule_ids)));
                     connect_timeout=10, readtimeout=10)
        end
    catch; end

    # Add new rules
    rule_value = join(keywords, " OR ")
    try
        HTTP.post("https://api.twitter.com/2/tweets/search/stream/rules",
                 headers,
                 JSON.json(Dict("add" => [Dict("value" => rule_value)]));
                 connect_timeout=10, readtimeout=10)
    catch e
        @warn "Failed to set X stream rules: $(sprint(showerror, e)[1:min(80,end)])"
    end

    # Connect to filtered stream
    stream_url = "https://api.twitter.com/2/tweets/search/stream?tweet.fields=created_at,public_metrics"

    @info "X stream connecting with keywords: $rule_value"

    while true
        try
            HTTP.open("GET", stream_url, headers;
                      connect_timeout=15, readtimeout=0) do io
                @info "X stream connected"
                while !eof(io)
                    line = String(readavailable(io))
                    for chunk in split(line, "\r\n")
                        chunk = strip(chunk)
                        isempty(chunk) && continue
                        try
                            data = JSON.parse(chunk)
                            tweet_data = get(data, "data", Dict())
                            text = get(tweet_data, "text", "")
                            if !isempty(text)
                                _process_tweet!(text, watched_assets,
                                               tweet_buffer, callback)
                            end
                        catch; end
                    end
                end
            end
        catch e
            @warn "X stream disconnected: $(sprint(showerror, e)[1:min(60,end)])"
        end

        @warn "X stream reconnecting in 5 seconds..."
        sleep(5.0)
    end
end

"""Process a single tweet: score, map to asset, buffer, callback."""
function _process_tweet!(text::String, watched_assets::Vector{String},
                          tweet_buffer::TweetBuffer, callback::Function)
    sentiment = score_sentiment(text)
    asset = detect_tweet_asset(text, watched_assets)

    if isempty(asset)
        return  # no relevant asset mentioned
    end

    tweet = (text=text, sentiment=sentiment, asset=asset, timestamp=now())
    add_tweet!(tweet_buffer, tweet)
    callback(asset, sentiment, text)
end
