# ── WebSocket Feed Infrastructure ─────────────────────────────
# Abstract feed interface with reconnection logic.
# Feeds push LiveSnapshots into a shared Channel for the pipeline to consume.

"""Abstract real-time data feed."""
abstract type AbstractFeed end

"""Configuration for a WebSocket feed with reconnection."""
struct FeedConfig
    url::String
    subscriptions::Vector{String}   # symbols/channels to subscribe to
    reconnect_delay_ms::Int         # delay between reconnection attempts
    max_reconnects::Int             # max reconnection attempts before giving up
    heartbeat_interval_ms::Int      # how often to send ping/heartbeat
end

function FeedConfig(url::String, subscriptions::Vector{String};
                    reconnect_delay_ms::Int=5000,
                    max_reconnects::Int=50,
                    heartbeat_interval_ms::Int=30000)
    FeedConfig(url, subscriptions, reconnect_delay_ms, max_reconnects,
               heartbeat_interval_ms)
end

"""State of a running feed connection."""
mutable struct FeedState
    connected::Bool
    reconnect_count::Int
    last_message_time::DateTime
    messages_received::Int
    errors::Int
    lock::ReentrantLock
end

FeedState() = FeedState(false, 0, now(), 0, 0, ReentrantLock())

"""Update feed state on message receipt (thread-safe)."""
function feed_message_received!(state::FeedState)
    lock(state.lock) do
        state.messages_received += 1
        state.last_message_time = now()
    end
end

"""Update feed state on connection (thread-safe)."""
function feed_connected!(state::FeedState)
    lock(state.lock) do
        state.connected = true
        state.reconnect_count = 0
    end
end

"""Update feed state on disconnection (thread-safe)."""
function feed_disconnected!(state::FeedState)
    lock(state.lock) do
        state.connected = false
        state.reconnect_count += 1
    end
end

"""Update feed state on error (thread-safe)."""
function feed_error!(state::FeedState)
    lock(state.lock) do
        state.errors += 1
    end
end

"""Get a snapshot of feed state (thread-safe)."""
function feed_snapshot(state::FeedState)
    lock(state.lock) do
        return (connected=state.connected,
                reconnect_count=state.reconnect_count,
                last_message=state.last_message_time,
                messages=state.messages_received,
                errors=state.errors,
                stale=now() - state.last_message_time > Second(60))
    end
end

"""
    run_feed_with_reconnect(connect_fn, config, state; on_message, on_error)

Generic reconnection wrapper for any WebSocket feed.
`connect_fn(config, on_message)` should establish a connection and block until closed.
Automatically reconnects on failure up to max_reconnects.
"""
function run_feed_with_reconnect(connect_fn::Function, config::FeedConfig,
                                  state::FeedState;
                                  on_error::Function=e -> @warn("Feed error: $e"))
    while state.reconnect_count < config.max_reconnects
        try
            feed_connected!(state)
            connect_fn(config, state)  # blocks until connection drops
        catch e
            feed_error!(state)
            on_error(e)
        end

        feed_disconnected!(state)

        if state.reconnect_count >= config.max_reconnects
            @warn "Feed max reconnects reached ($(config.max_reconnects)) — stopping"
            break
        end

        delay_s = config.reconnect_delay_ms / 1000.0
        @warn "Feed disconnected — reconnecting in $(delay_s)s (attempt $(state.reconnect_count)/$(config.max_reconnects))"
        sleep(delay_s)
    end
end
