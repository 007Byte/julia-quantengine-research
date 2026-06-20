# ── WebSocket Feed Tests ──────────────────────────────────────
# Unit tests only (no actual WebSocket connections).

using QuantEngine: FeedConfig, FeedState, feed_message_received!, feed_connected!,
                   feed_disconnected!, feed_error!, feed_snapshot,
                   BinanceFeed, _binance_to_ticker, _ticker_to_binance,
                   _process_binance_message!

@testset "FeedConfig creation" begin
    config = FeedConfig("wss://test.com", ["BTC-USD", "ETH-USD"])
    @test config.url == "wss://test.com"
    @test length(config.subscriptions) == 2
    @test config.reconnect_delay_ms == 5000
    @test config.max_reconnects == 50
end

@testset "FeedState lifecycle" begin
    state = FeedState()

    @test state.connected == false
    @test state.messages_received == 0
    @test state.errors == 0

    feed_connected!(state)
    @test state.connected == true
    @test state.reconnect_count == 0

    feed_message_received!(state)
    feed_message_received!(state)
    @test state.messages_received == 2

    feed_error!(state)
    @test state.errors == 1

    feed_disconnected!(state)
    @test state.connected == false
    @test state.reconnect_count == 1
end

@testset "feed_snapshot" begin
    state = FeedState()
    feed_connected!(state)
    feed_message_received!(state)

    snap = feed_snapshot(state)
    @test snap.connected == true
    @test snap.messages == 1
    @test snap.errors == 0
    @test snap.stale == false  # just received a message
end

@testset "Binance symbol conversion" begin
    @test _binance_to_ticker("BTCUSDT") == "BTC-USD"
    @test _binance_to_ticker("ETHUSDT") == "ETH-USD"
    @test _binance_to_ticker("SOLUSDT") == "SOL-USD"
    @test _binance_to_ticker("btcusdt") == "BTC-USD"

    @test _ticker_to_binance("BTC-USD") == "btcusdt"
    @test _ticker_to_binance("ETH-USD") == "ethusdt"
end

@testset "BinanceFeed creation" begin
    history = RollingHistory(max_entries=100)
    feed = BinanceFeed(["BTC-USD", "ETH-USD"], history)

    @test feed.config.url |> !isempty
    @test occursin("stream.binance.com", feed.config.url)
    @test length(feed.config.subscriptions) == 2
    @test feed.state.connected == false
end

@testset "Binance message processing" begin
    history = RollingHistory(max_entries=100)
    received = Ref{String}("")
    received_price = Ref{Float64}(0.0)

    feed = BinanceFeed(["BTC-USD"], history;
        callback=(asset, snap) -> begin
            received[] = asset
            received_price[] = snap.price
        end)

    # Simulate a trade message
    msg = Dict(
        "data" => Dict(
            "e" => "trade",
            "s" => "BTCUSDT",
            "p" => "45123.50",
            "q" => "0.001",
            "T" => round(Int, datetime2unix(now()) * 1000)
        )
    )

    _process_binance_message!(feed, msg)

    @test received[] == "BTC-USD"
    @test received_price[] ≈ 45123.50

    # History should be updated
    prices = get_recent_prices(history, "BTC-USD")
    @test length(prices) == 1
    @test prices[1] ≈ 45123.50
end

@testset "Binance ignores non-trade messages" begin
    history = RollingHistory(max_entries=100)
    callback_count = Ref(0)
    feed = BinanceFeed(["BTC-USD"], history;
        callback=(a, s) -> callback_count[] += 1)

    # Non-trade event
    msg = Dict("data" => Dict("e" => "kline", "s" => "BTCUSDT"))
    _process_binance_message!(feed, msg)

    @test callback_count[] == 0
end

@testset "Binance handles invalid price" begin
    history = RollingHistory(max_entries=100)
    callback_count = Ref(0)
    feed = BinanceFeed(["BTC-USD"], history;
        callback=(a, s) -> callback_count[] += 1)

    msg = Dict("data" => Dict("e" => "trade", "s" => "BTCUSDT", "p" => "0", "q" => "1", "T" => 0))
    _process_binance_message!(feed, msg)

    @test callback_count[] == 0  # price <= 0 should be ignored
end

@testset "PolygonFeed requires API key" begin
    # Should error without key set
    history = RollingHistory(max_entries=100)
    @test_throws ErrorException PolygonFeed(
        ["AAPL"], history;
        api_key_env="NONEXISTENT_POLYGON_KEY_12345"
    )
end

@testset "PolygonFeed creation with key" begin
    history = RollingHistory(max_entries=100)
    withenv("QE_TEST_POLYGON_KEY" => "test_key_123") do
        feed = PolygonFeed(["AAPL", "MSFT"], history;
                           api_key_env="QE_TEST_POLYGON_KEY")

        @test occursin("polygon.io", feed.config.url)
        @test length(feed.config.subscriptions) == 2
        @test feed.api_key == "test_key_123"
    end
end

@testset "FeedState thread safety" begin
    state = FeedState()

    tasks = Task[]
    for _ in 1:20
        push!(tasks, @async begin
            feed_message_received!(state)
            feed_error!(state)
        end)
    end
    for t in tasks; wait(t); end

    @test state.messages_received == 20
    @test state.errors == 20
end
