# ── Polymarket Exchange — CLOB Order Placement ───────────────
# Implements AbstractExchange for Polymarket's Central Limit Order Book.
# Uses Polymarket's REST API for order placement and position management.
# Requires API key + secret for authenticated endpoints.

"""Polymarket exchange implementation via CLOB API."""
mutable struct PolymarketExchange <: AbstractExchange
    api_key::String
    api_secret::String
    base_url::String
    execution_mode::ExecutionMode
    rate_limiter::RateLimiter
    positions::Dict{String, Float64}    # market_id → shares held
    balance::Float64
    lock::ReentrantLock
end

"""Create a Polymarket exchange connection."""
function PolymarketExchange(; execution_mode::ExecutionMode=PAPER,
                              api_key_env::String="QE_POLYMARKET_API_KEY",
                              api_secret_env::String="QE_POLYMARKET_SECRET",
                              initial_balance::Float64=2000.0)
    api_key = get(ENV, api_key_env, "")
    api_secret = get(ENV, api_secret_env, "")

    base_url = "https://clob.polymarket.com"

    # Rate limit: Polymarket CLOB has moderate limits
    limiter = RateLimiter(max_per_minute=60, max_per_second=3)

    if execution_mode == LIVE && (isempty(api_key) || isempty(api_secret))
        error("Polymarket LIVE mode requires API key and secret. " *
              "Set $api_key_env and $api_secret_env.")
    end

    if execution_mode == LIVE
        @warn "PolymarketExchange: LIVE mode — real money trading on Polymarket"
    end

    PolymarketExchange(api_key, api_secret, base_url, execution_mode,
                       limiter, Dict{String,Float64}(), initial_balance, ReentrantLock())
end

"""Build authenticated headers for Polymarket CLOB API."""
function _poly_headers(ex::PolymarketExchange)
    headers = ["Content-Type" => "application/json"]
    if !isempty(ex.api_key)
        push!(headers, "POLY-API-KEY" => ex.api_key)
        push!(headers, "POLY-API-SECRET" => ex.api_secret)
    end
    return headers
end

function place_order(ex::PolymarketExchange, asset::String, direction::Symbol,
                     instrument::Symbol, size_dollars::Float64;
                     order_type::Symbol=:market, limit_price::Float64=0.0)
    lock(ex.lock) do
        if size_dollars > ex.balance
            return (order_id="rejected", status=:insufficient_funds, fill_price=0.0)
        end

        if ex.execution_mode == PAPER
            # Paper trading: simulate fill at current market price
            fill_price = limit_price > 0 ? limit_price : 0.5
            shares = size_dollars / max(fill_price, 0.01)

            ex.balance -= size_dollars
            market_key = "$(asset)_$(direction)"
            ex.positions[market_key] = get(ex.positions, market_key, 0.0) + shares

            return (order_id="POLY-PAPER-$(hash(now()))",
                    status=:filled, fill_price=fill_price)
        end

        # Live: place order via CLOB API
        wait_for_slot!(ex.rate_limiter)

        side = direction in (:buy, :long) ? "BUY" : "SELL"
        token_id = asset  # Polymarket uses token IDs for outcomes

        body = Dict{String,Any}(
            "tokenID" => token_id,
            "side" => side,
            "size" => string(round(size_dollars, digits=2)),
            "type" => order_type == :limit ? "GTC" : "FOK",
        )
        if order_type == :limit && limit_price > 0
            body["price"] = string(round(limit_price, digits=4))
        end

        try
            resp = HTTP.post("$(ex.base_url)/order", _poly_headers(ex),
                            JSON.json(body); connect_timeout=10, readtimeout=15)
            result = JSON.parse(String(resp.body))

            order_id = get(result, "orderID", get(result, "id", "unknown"))
            status_str = get(result, "status", "unknown")
            fill_price_raw = get(result, "averagePrice", limit_price)
            fill_price = fill_price_raw isa String ? parse(Float64, fill_price_raw) : Float64(fill_price_raw)

            status = status_str in ("MATCHED", "FILLED") ? :filled : :pending

            if status == :filled
                ex.balance -= size_dollars
            end

            return (order_id=order_id, status=status, fill_price=fill_price)
        catch e
            @warn "Polymarket order failed: $(sprint(showerror, e)[1:min(80,end)])"
            return (order_id="ERROR", status=:error, fill_price=0.0)
        end
    end
end

function get_balance(ex::PolymarketExchange)::Float64
    lock(ex.lock) do
        if ex.execution_mode == PAPER
            return ex.balance
        end
        # Live: query CLOB API for balance
        try
            wait_for_slot!(ex.rate_limiter)
            resp = HTTP.get("$(ex.base_url)/balance", _poly_headers(ex);
                           connect_timeout=10, readtimeout=10)
            data = JSON.parse(String(resp.body))
            return parse(Float64, get(data, "balance", "0"))
        catch
            return ex.balance  # fallback to cached
        end
    end
end

function get_current_price(ex::PolymarketExchange, asset::String)::Float64
    try
        # Use gamma API for current prices
        slug = replace(asset, "poly:" => "")
        data = fetch_polymarket_data(slug)
        return data.prices[1]
    catch
        return NaN
    end
end

function cancel_order(ex::PolymarketExchange, order_id::String)::Bool
    if ex.execution_mode == PAPER
        return false  # paper orders fill immediately
    end
    try
        wait_for_slot!(ex.rate_limiter)
        HTTP.delete("$(ex.base_url)/order/$(order_id)", _poly_headers(ex);
                    connect_timeout=10, readtimeout=10)
        return true
    catch
        return false
    end
end

function get_open_orders(ex::PolymarketExchange)::Vector{NamedTuple}
    if ex.execution_mode == PAPER
        return NamedTuple[]
    end
    try
        wait_for_slot!(ex.rate_limiter)
        resp = HTTP.get("$(ex.base_url)/orders?status=LIVE", _poly_headers(ex);
                       connect_timeout=10, readtimeout=10)
        orders = JSON.parse(String(resp.body))
        return [(order_id=get(o, "id", ""), asset=get(o, "tokenID", ""),
                 side=Symbol(lowercase(get(o, "side", "buy"))),
                 size=parse(Float64, get(o, "size", "0")))
                for o in orders]
    catch
        return NamedTuple[]
    end
end

"""Get current positions on Polymarket."""
function polymarket_get_positions(ex::PolymarketExchange)
    lock(ex.lock) do
        if ex.execution_mode == PAPER
            return [(market=k, shares=v) for (k, v) in ex.positions]
        end
        try
            wait_for_slot!(ex.rate_limiter)
            resp = HTTP.get("$(ex.base_url)/positions", _poly_headers(ex);
                           connect_timeout=10, readtimeout=10)
            data = JSON.parse(String(resp.body))
            return [(market=get(p, "tokenID", ""),
                     shares=parse(Float64, get(p, "size", "0")),
                     avg_price=parse(Float64, get(p, "avgPrice", "0")))
                    for p in data]
        catch
            return NamedTuple[]
        end
    end
end
