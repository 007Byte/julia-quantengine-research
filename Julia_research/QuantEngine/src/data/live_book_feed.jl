# ── Live Order Book Feed Integration ──────────────────────────
# Wires real-time L2 depth from Binance/Polymarket into the
# feature matrix as features 15-17 (DepthImbalance, BookPressure, SpreadBps).

"""
Manages live order book feeds and provides real-time book features
for the pipeline. Updates on every WebSocket tick.
"""
mutable struct LiveBookManager
    cache::OrderBookCache
    feature_cache::Dict{String, NamedTuple}  # asset → latest book features
    refresh_interval_ms::Int
    last_refresh::Dict{String, DateTime}
    lock::ReentrantLock
end

function LiveBookManager(; refresh_interval_ms::Int=1000)
    LiveBookManager(OrderBookCache(), Dict{String,NamedTuple}(),
                    refresh_interval_ms, Dict{String,DateTime}(), ReentrantLock())
end

"""Update book from a WebSocket price feed callback."""
function update_book_from_feed!(manager::LiveBookManager, asset::String,
                                  bids::Vector{BookLevel}, asks::Vector{BookLevel})
    update_book!(manager.cache, asset, bids, asks)

    # Recompute features if enough time has passed
    lock(manager.lock) do
        last = get(manager.last_refresh, asset, DateTime(0))
        if (now() - last) > Millisecond(manager.refresh_interval_ms)
            book = get_book(manager.cache, asset)
            if book !== nothing
                features = compute_book_features(book)
                manager.feature_cache[asset] = features
                manager.last_refresh[asset] = now()
            end
        end
    end
end

"""Get the latest book features for an asset (for feature matrix injection)."""
function get_live_book_features(manager::LiveBookManager, asset::String)::Union{NamedTuple, Nothing}
    lock(manager.lock) do
        return get(manager.feature_cache, asset, nothing)
    end
end

"""
    start_binance_book_feed!(manager, symbols; depth)

Launch a background task that polls Binance order books and updates
the manager. Runs alongside the main WebSocket price feed.
"""
function start_binance_book_feed!(manager::LiveBookManager, symbols::Vector{String};
                                    depth::Int=20, poll_ms::Int=2000)
    @async begin
        while true
            for symbol in symbols
                try
                    book = fetch_binance_orderbook(symbol; depth=depth)
                    if !isempty(book.bids) && !isempty(book.asks)
                        update_book!(manager.cache, symbol, book.bids, book.asks)
                        features = compute_book_features(book)
                        lock(manager.lock) do
                            manager.feature_cache[symbol] = features
                            manager.last_refresh[symbol] = now()
                        end
                    end
                catch; end
            end
            sleep(poll_ms / 1000.0)
        end
    end
end

"""
    start_polymarket_book_feed!(manager, token_ids; poll_ms)

Launch a background task that polls Polymarket CLOB order books.
"""
function start_polymarket_book_feed!(manager::LiveBookManager, token_ids::Vector{String};
                                       poll_ms::Int=5000)
    @async begin
        while true
            for tid in token_ids
                try
                    book = fetch_polymarket_orderbook(tid)
                    if !isempty(book.bids) && !isempty(book.asks)
                        asset = "poly:$(tid)"
                        update_book!(manager.cache, asset, book.bids, book.asks)
                        features = compute_book_features(book)
                        lock(manager.lock) do
                            manager.feature_cache[asset] = features
                            manager.last_refresh[asset] = now()
                        end
                    end
                catch; end
            end
            sleep(poll_ms / 1000.0)
        end
    end
end
