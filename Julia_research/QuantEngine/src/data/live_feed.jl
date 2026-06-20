# ── Live Data Feed Adapters ───────────────────────────────────
# Polling-based now; WebSocket-ready interface for future upgrade.

"""Snapshot of current market state for one asset."""
struct LiveSnapshot
    price::Float64
    volume::Float64
    high::Float64
    low::Float64
    timestamp::DateTime
    raw::Any  # original API response for debugging
end

"""Fetch a live snapshot for any asset type."""
function fetch_live_snapshot(asset::String, asset_type::Symbol)::LiveSnapshot
    asset = validate_ticker(asset)
    if asset_type == :polymarket
        return _fetch_polymarket_live(replace(asset, "poly:" => ""))
    elseif asset_type == :crypto
        return _fetch_yahoo_live(uppercase(asset))
    else  # :stock
        return _fetch_yahoo_live(uppercase(asset))
    end
end

function _fetch_yahoo_live(ticker::String)::LiveSnapshot
    ohlcv = fetch_ohlcv(ticker; period="5d")
    sanitize_ohlcv(ohlcv.dates, ohlcv.high, ohlcv.low, ohlcv.close, ohlcv.volume, ohlcv.adj)
    LiveSnapshot(
        sanitize_price(ohlcv.adj[end]; label="$ticker adj_close"),
        sanitize_volume(ohlcv.volume[end]; label="$ticker volume"),
        sanitize_price(ohlcv.high[end]; label="$ticker high"),
        sanitize_price(ohlcv.low[end]; label="$ticker low"),
        ohlcv.dates[end],
        ohlcv
    )
end

function _fetch_polymarket_live(slug::String)::LiveSnapshot
    poly = fetch_polymarket_data(slug)
    price = Float64(poly.prices[1])
    sanitize_polymarket(Float64.(poly.prices), poly.outcomes)
    vol = tryparse(Float64, string(poly.volume))
    vol = vol === nothing ? 0.0 : vol
    LiveSnapshot(
        sanitize_price(price; label="poly:$slug"),
        sanitize_volume(vol; label="poly:$slug volume"),
        price, price, now(), poly
    )
end

"""Rolling history tracker — bounded to prevent memory growth."""
mutable struct RollingHistory
    data::Dict{String, Vector{Float64}}   # asset → recent prices
    volumes::Dict{String, Vector{Float64}} # asset → recent volumes
    max_entries::Int
    lock::ReentrantLock
end

function RollingHistory(; max_entries::Int=1000)
    RollingHistory(Dict(), Dict(), max_entries, ReentrantLock())
end

"""Update rolling history with new snapshot (thread-safe, bounded)."""
function update_history!(history::RollingHistory, asset::String, snapshot::LiveSnapshot)
    lock(history.lock) do
        if !haskey(history.data, asset)
            history.data[asset] = Float64[]
            history.volumes[asset] = Float64[]
        end
        push!(history.data[asset], snapshot.price)
        push!(history.volumes[asset], snapshot.volume)
        # Bound: remove oldest if over limit
        while length(history.data[asset]) > history.max_entries
            popfirst!(history.data[asset])
            popfirst!(history.volumes[asset])
        end
    end
end

"""Get recent prices for an asset (thread-safe copy)."""
function get_recent_prices(history::RollingHistory, asset::String)::Vector{Float64}
    lock(history.lock) do
        return copy(get(history.data, asset, Float64[]))
    end
end

"""Get recent volumes for an asset (thread-safe copy)."""
function get_recent_volumes(history::RollingHistory, asset::String)::Vector{Float64}
    lock(history.lock) do
        return copy(get(history.volumes, asset, Float64[]))
    end
end
