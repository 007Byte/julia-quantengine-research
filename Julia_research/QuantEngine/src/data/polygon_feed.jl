# ── Polygon.io WebSocket Feed (Stocks) ────────────────────────
# Real-time trade/quote stream via wss://socket.polygon.io
# Requires Polygon.io API key (QE_POLYGON_API_KEY).

"""Polygon.io WebSocket feed for real-time stock prices."""
struct PolygonFeed <: AbstractFeed
    config::FeedConfig
    state::FeedState
    history::RollingHistory
    api_key::String
    callback::Function             # called with (asset, LiveSnapshot)
end

"""Create a Polygon.io feed for the given stock symbols."""
function PolygonFeed(symbols::Vector{String}, history::RollingHistory;
                     callback::Function=(asset, snap) -> nothing,
                     api_key_env::String="QE_POLYGON_API_KEY")
    api_key = get(ENV, api_key_env, "")
    if isempty(api_key)
        error("Polygon.io API key not set. Set $api_key_env environment variable.")
    end

    url = "wss://socket.polygon.io/stocks"

    config = FeedConfig(url, [uppercase(s) for s in symbols];
                        reconnect_delay_ms=5000,
                        max_reconnects=100,
                        heartbeat_interval_ms=30000)

    PolygonFeed(config, FeedState(), history, api_key, callback)
end

"""Start the Polygon.io WebSocket feed (blocking — run in a Task)."""
function start_feed!(feed::PolygonFeed)
    run_feed_with_reconnect(feed.config, feed.state) do config, state
        HTTP.WebSockets.open(config.url) do ws
            # Authenticate
            auth_msg = JSON.json(Dict("action" => "auth", "params" => feed.api_key))
            write(ws, auth_msg)

            # Subscribe to trade channels
            for symbol in config.subscriptions
                sub_msg = JSON.json(Dict("action" => "subscribe",
                                         "params" => "T.$symbol"))
                write(ws, sub_msg)
            end

            feed_connected!(state)

            while !eof(ws)
                msg = String(readavailable(ws))
                if isempty(msg)
                    continue
                end

                try
                    events = JSON.parse(msg)
                    if events isa Vector
                        for event in events
                            _process_polygon_message!(feed, event)
                        end
                    else
                        _process_polygon_message!(feed, events)
                    end
                    feed_message_received!(state)
                catch e
                    feed_error!(state)
                end
            end
        end
    end
end

"""Process a Polygon.io trade message and update history."""
function _process_polygon_message!(feed::PolygonFeed, data::Dict)
    ev = get(data, "ev", "")

    if ev == "T"  # Trade event
        symbol = get(data, "sym", "")
        price = Float64(get(data, "p", 0.0))
        size = Float64(get(data, "s", 0.0))
        timestamp = get(data, "t", 0)  # nanosecond timestamp

        if price <= 0.0 || isempty(symbol)
            return
        end

        asset = uppercase(symbol)
        snap = LiveSnapshot(price, size, price, price,
                            unix2datetime(timestamp / 1e9), data)

        update_history!(feed.history, asset, snap)
        feed.callback(asset, snap)

    elseif ev == "status"
        status = get(data, "status", "")
        message = get(data, "message", "")
        if status == "auth_success"
            @info "Polygon.io authenticated successfully"
        elseif status == "auth_failed"
            @warn "Polygon.io authentication failed: $message"
        end
    end
end
