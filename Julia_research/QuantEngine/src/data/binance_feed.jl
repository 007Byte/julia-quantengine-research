# ── Binance WebSocket Feed (Crypto) ───────────────────────────
# Real-time trade stream via wss://stream.binance.com
# No API key required for public trade streams.

"""Binance WebSocket feed for real-time crypto prices."""
struct BinanceFeed <: AbstractFeed
    config::FeedConfig
    state::FeedState
    history::RollingHistory
    callback::Function             # called with (asset, LiveSnapshot)
end

"""Create a Binance feed for the given crypto symbols."""
function BinanceFeed(symbols::Vector{String}, history::RollingHistory;
                     callback::Function=(asset, snap) -> nothing)
    # Binance uses lowercase symbol format: btcusdt, ethusdt
    streams = [lowercase(replace(s, "-USD" => "usdt", "-" => "")) * "@trade"
               for s in symbols]

    # Combined stream URL
    stream_path = join(streams, "/")
    url = "wss://stream.binance.com:9443/stream?streams=$stream_path"

    config = FeedConfig(url, symbols;
                        reconnect_delay_ms=3000,
                        max_reconnects=100,
                        heartbeat_interval_ms=30000)

    BinanceFeed(config, FeedState(), history, callback)
end

"""Start the Binance WebSocket feed (blocking — run in a Task)."""
function start_feed!(feed::BinanceFeed)
    run_feed_with_reconnect(feed.config, feed.state) do config, state
        HTTP.WebSockets.open(config.url) do ws
            feed_connected!(state)

            while !eof(ws)
                msg = String(readavailable(ws))
                if isempty(msg)
                    continue
                end

                try
                    data = JSON.parse(msg)
                    _process_binance_message!(feed, data)
                    feed_message_received!(state)
                catch e
                    feed_error!(state)
                end
            end
        end
    end
end

"""Process a Binance trade message and update history."""
function _process_binance_message!(feed::BinanceFeed, data::Dict)
    # Combined stream format: {"stream": "btcusdt@trade", "data": {...}}
    trade_data = get(data, "data", data)
    event_type = get(trade_data, "e", "")

    if event_type != "trade"
        return
    end

    # Extract fields
    symbol_raw = get(trade_data, "s", "")  # e.g., "BTCUSDT"
    price = parse(Float64, get(trade_data, "p", "0"))
    qty = parse(Float64, get(trade_data, "q", "0"))
    timestamp = get(trade_data, "T", 0)  # trade time in ms

    if price <= 0.0
        return
    end

    # Map back to our ticker format (BTCUSDT → BTC-USD)
    asset = _binance_to_ticker(symbol_raw)

    snap = LiveSnapshot(price, qty, price, price,
                        unix2datetime(timestamp / 1000), trade_data)

    update_history!(feed.history, asset, snap)
    feed.callback(asset, snap)
end

"""Convert Binance symbol to our ticker format."""
function _binance_to_ticker(symbol::String)
    s = uppercase(symbol)
    if endswith(s, "USDT")
        return replace(s, "USDT" => "-USD")
    elseif endswith(s, "USD")
        return replace(s, "USD" => "-USD")
    end
    return s
end

"""Convert our ticker to Binance symbol format."""
function _ticker_to_binance(ticker::String)
    return lowercase(replace(ticker, "-USD" => "usdt", "-" => ""))
end
