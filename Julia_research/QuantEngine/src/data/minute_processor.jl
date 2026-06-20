# ── Minute-by-Minute Data Processor ───────────────────────────
# Handles high-frequency data ingestion for live trading.
# Maintains rolling windows of minute bars, computes real-time
# features, and triggers the adaptive model selector.

"""Rolling window of minute-bar data for one asset."""
mutable struct MinuteBarWindow
    asset::String
    prices::Vector{Float64}
    volumes::Vector{Float64}
    highs::Vector{Float64}
    lows::Vector{Float64}
    timestamps::Vector{DateTime}
    max_bars::Int
    lock::ReentrantLock
end

function MinuteBarWindow(asset::String; max_bars::Int=1440)  # 24 hours of minute bars
    MinuteBarWindow(asset, Float64[], Float64[], Float64[], Float64[],
                    DateTime[], max_bars, ReentrantLock())
end

"""Add a minute bar to the window (thread-safe, bounded)."""
function add_bar!(window::MinuteBarWindow, price::Float64, volume::Float64,
                   high::Float64, low::Float64, ts::DateTime)
    lock(window.lock) do
        push!(window.prices, price)
        push!(window.volumes, volume)
        push!(window.highs, high)
        push!(window.lows, low)
        push!(window.timestamps, ts)
        while length(window.prices) > window.max_bars
            popfirst!(window.prices)
            popfirst!(window.volumes)
            popfirst!(window.highs)
            popfirst!(window.lows)
            popfirst!(window.timestamps)
        end
    end
end

"""Get current bar count."""
function bar_count(window::MinuteBarWindow)::Int
    lock(window.lock) do
        return length(window.prices)
    end
end

"""Get a snapshot of the window (thread-safe copy)."""
function window_snapshot(window::MinuteBarWindow)
    lock(window.lock) do
        return (prices=copy(window.prices),
                volumes=copy(window.volumes),
                highs=copy(window.highs),
                lows=copy(window.lows),
                timestamps=copy(window.timestamps),
                n=length(window.prices))
    end
end

"""Aggregate minute bars to N-minute bars for multi-timeframe analysis."""
function aggregate_bars(window::MinuteBarWindow, period::Int)
    snap = window_snapshot(window)
    n = snap.n
    if n < period
        return snap
    end

    n_agg = div(n, period)
    prices = Float64[]
    volumes = Float64[]
    highs = Float64[]
    lows = Float64[]
    timestamps = DateTime[]

    for i in 1:n_agg
        start_idx = (i - 1) * period + 1
        end_idx = min(i * period, n)
        push!(prices, snap.prices[end_idx])  # close of period
        push!(volumes, sum(snap.volumes[start_idx:end_idx]))
        push!(highs, maximum(snap.highs[start_idx:end_idx]))
        push!(lows, minimum(snap.lows[start_idx:end_idx]))
        push!(timestamps, snap.timestamps[end_idx])
    end

    return (prices=prices, volumes=volumes, highs=highs, lows=lows,
            timestamps=timestamps, n=length(prices))
end

"""Collection of minute bar windows for multiple assets."""
mutable struct MinuteDataManager
    windows::Dict{String, MinuteBarWindow}
    max_bars::Int
    lock::ReentrantLock
end

MinuteDataManager(; max_bars::Int=1440) =
    MinuteDataManager(Dict{String,MinuteBarWindow}(), max_bars, ReentrantLock())

"""Get or create a window for an asset."""
function get_window!(manager::MinuteDataManager, asset::String)::MinuteBarWindow
    lock(manager.lock) do
        if !haskey(manager.windows, asset)
            manager.windows[asset] = MinuteBarWindow(asset; max_bars=manager.max_bars)
        end
        return manager.windows[asset]
    end
end

"""Ingest a price update (from WebSocket or polling)."""
function ingest_tick!(manager::MinuteDataManager, asset::String,
                       price::Float64, volume::Float64;
                       high::Float64=price, low::Float64=price,
                       ts::DateTime=now())
    window = get_window!(manager, asset)
    add_bar!(window, price, volume, high, low, ts)
end

"""
    should_analyze(window; min_bars, analyze_every_n)

Determine if enough new data has arrived to warrant running analysis.
"""
function should_analyze(window::MinuteBarWindow;
                         min_bars::Int=30,
                         analyze_every_n::Int=5)::Bool
    lock(window.lock) do
        n = length(window.prices)
        return n >= min_bars && n % analyze_every_n == 0
    end
end

"""
    compute_realtime_features(window; timeframe)

Compute features from minute-bar data at a given timeframe aggregation.
Returns features compatible with the 18-feature matrix.
"""
function compute_realtime_features(window::MinuteBarWindow;
                                     timeframe::Int=5)  # 5-minute default
    agg = aggregate_bars(window, timeframe)
    if agg.n < 25
        return nothing
    end

    returns = diff(log.(max.(agg.prices, 0.01)))
    if length(returns) < 20
        return nothing
    end

    try
        X, y, μ, σ = compute_features(agg.prices, returns, agg.volumes;
                                        high=agg.highs, low=agg.lows)
        return (features=X, labels=y, prices=agg.prices, returns=returns,
                volumes=agg.volumes, n_bars=agg.n, timeframe=timeframe)
    catch
        return nothing
    end
end
