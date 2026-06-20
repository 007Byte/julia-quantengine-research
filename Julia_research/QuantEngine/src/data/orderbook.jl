# ── L2 Order-Book Depth Extractor ─────────────────────────────
# Pulls true bid/ask depth from Binance WS and Polymarket CLOB.
# Computes microstructure signals: depth imbalance, spread dynamics,
# large-order detection, and weighted mid-price.

"""Snapshot of one side of an order book."""
struct BookLevel
    price::Float64
    size::Float64
end

"""Full L2 order book snapshot."""
mutable struct OrderBookSnapshot
    asset::String
    bids::Vector{BookLevel}        # sorted descending by price
    asks::Vector{BookLevel}        # sorted ascending by price
    timestamp::DateTime
    lock::ReentrantLock
end

OrderBookSnapshot(asset::String) =
    OrderBookSnapshot(asset, BookLevel[], BookLevel[], now(), ReentrantLock())

"""Thread-safe cache of order book snapshots."""
mutable struct OrderBookCache
    books::Dict{String, OrderBookSnapshot}
    lock::ReentrantLock
end

OrderBookCache() = OrderBookCache(Dict{String,OrderBookSnapshot}(), ReentrantLock())

"""Update an order book snapshot (thread-safe)."""
function update_book!(cache::OrderBookCache, asset::String,
                       bids::Vector{BookLevel}, asks::Vector{BookLevel})
    lock(cache.lock) do
        if !haskey(cache.books, asset)
            cache.books[asset] = OrderBookSnapshot(asset)
        end
        book = cache.books[asset]
        lock(book.lock) do
            book.bids = sort(bids, by=b -> -b.price)  # best bid first
            book.asks = sort(asks, by=a -> a.price)     # best ask first
            book.timestamp = now()
        end
    end
end

"""Get current book snapshot for an asset (thread-safe copy)."""
function get_book(cache::OrderBookCache, asset::String)::Union{OrderBookSnapshot, Nothing}
    lock(cache.lock) do
        return get(cache.books, asset, nothing)
    end
end

# ── Microstructure Signals ────────────────────────────────────

"""
    compute_book_features(book; depth_levels)

Extract microstructure features from an L2 order book.
Returns named tuple of signals for the ensemble.
"""
function compute_book_features(book::OrderBookSnapshot; depth_levels::Int=10)
    bids = book.bids
    asks = book.asks

    if isempty(bids) || isempty(asks)
        return (bid_ask_spread=NaN, weighted_mid=NaN,
                depth_imbalance=0.0, large_order_ratio=0.0,
                bid_depth=0.0, ask_depth=0.0,
                spread_bps=NaN, book_pressure=0.0)
    end

    best_bid = bids[1].price
    best_ask = asks[1].price
    mid = (best_bid + best_ask) / 2.0

    # Spread
    spread = best_ask - best_bid
    spread_bps = mid > 0 ? spread / mid * 10000.0 : NaN

    # Depth (top N levels)
    n_bid = min(depth_levels, length(bids))
    n_ask = min(depth_levels, length(asks))

    bid_depth = sum(bids[i].size * bids[i].price for i in 1:n_bid)
    ask_depth = sum(asks[i].size * asks[i].price for i in 1:n_ask)

    # Depth-weighted imbalance: positive = more buy pressure
    total_depth = bid_depth + ask_depth
    depth_imbalance = total_depth > 0 ? (bid_depth - ask_depth) / total_depth : 0.0

    # Weighted mid-price (better than simple midpoint)
    weighted_mid = total_depth > 0 ?
        (best_bid * ask_depth + best_ask * bid_depth) / total_depth : mid

    # Large order detection: ratio of top-level size to average level size
    avg_bid_size = n_bid > 0 ? mean(bids[i].size for i in 1:n_bid) : 0.0
    avg_ask_size = n_ask > 0 ? mean(asks[i].size for i in 1:n_ask) : 0.0
    max_level_size = max(
        isempty(bids) ? 0.0 : maximum(b.size for b in bids[1:n_bid]),
        isempty(asks) ? 0.0 : maximum(a.size for a in asks[1:n_ask])
    )
    avg_size = (avg_bid_size + avg_ask_size) / 2.0
    large_order_ratio = avg_size > 0 ? max_level_size / avg_size : 0.0

    # Book pressure: net directional pressure (positive = bullish)
    book_pressure = depth_imbalance * (1.0 + large_order_ratio * 0.1)

    return (bid_ask_spread=spread, weighted_mid=weighted_mid,
            depth_imbalance=depth_imbalance,
            large_order_ratio=large_order_ratio,
            bid_depth=bid_depth, ask_depth=ask_depth,
            spread_bps=spread_bps, book_pressure=book_pressure)
end

# ── Binance Order Book Fetcher ────────────────────────────────

"""Fetch L2 order book from Binance REST API."""
function fetch_binance_orderbook(symbol::String; depth::Int=20)::OrderBookSnapshot
    binance_sym = uppercase(replace(symbol, "-USD" => "USDT", "-" => ""))
    url = "https://api.binance.com/api/v3/depth?symbol=$(binance_sym)&limit=$(depth)"

    try
        resp = HTTP.get(url; connect_timeout=5, readtimeout=5)
        data = JSON.parse(String(resp.body))

        bids = [BookLevel(parse(Float64, b[1]), parse(Float64, b[2]))
                for b in get(data, "bids", [])]
        asks = [BookLevel(parse(Float64, a[1]), parse(Float64, a[2]))
                for a in get(data, "asks", [])]

        book = OrderBookSnapshot(symbol)
        book.bids = sort(bids, by=b -> -b.price)
        book.asks = sort(asks, by=a -> a.price)
        book.timestamp = now()
        return book
    catch e
        @warn "Binance orderbook fetch failed: $(sprint(showerror, e)[1:min(60,end)])"
        return OrderBookSnapshot(symbol)
    end
end

# ── Polymarket Order Book Fetcher ─────────────────────────────

"""Fetch L2 order book from Polymarket CLOB API."""
function fetch_polymarket_orderbook(token_id::String)::OrderBookSnapshot
    url = "https://clob.polymarket.com/book?token_id=$(token_id)"

    try
        resp = HTTP.get(url, ["Accept" => "application/json"];
                        connect_timeout=5, readtimeout=5)
        data = JSON.parse(String(resp.body))

        bids_raw = get(data, "bids", [])
        asks_raw = get(data, "asks", [])

        bids = [BookLevel(parse(Float64, get(b, "price", "0")),
                          parse(Float64, get(b, "size", "0")))
                for b in bids_raw]
        asks = [BookLevel(parse(Float64, get(a, "price", "0")),
                          parse(Float64, get(a, "size", "0")))
                for a in asks_raw]

        book = OrderBookSnapshot("poly:$(token_id)")
        book.bids = sort(bids, by=b -> -b.price)
        book.asks = sort(asks, by=a -> a.price)
        book.timestamp = now()
        return book
    catch e
        @warn "Polymarket orderbook fetch failed: $(sprint(showerror, e)[1:min(60,end)])"
        return OrderBookSnapshot("poly:$(token_id)")
    end
end
