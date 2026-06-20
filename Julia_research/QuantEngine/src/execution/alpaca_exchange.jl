# ── Alpaca Exchange — Real Broker Integration ─────────────────
# Implements AbstractExchange for Alpaca Markets REST API v2.
# Supports both paper and live trading via URL selection.
# Security: API keys never logged, TLS enforced, rate limited.

"""Alpaca Markets exchange implementation."""
mutable struct AlpacaExchange <: AbstractExchange
    api_key::String
    secret_key::String
    base_url::String               # paper-api vs api.alpaca.markets
    execution_mode::ExecutionMode
    rate_limiter::RateLimiter
    last_prices::Dict{String, Float64}
    lock::ReentrantLock
end

"""
    AlpacaExchange(; execution_mode, api_key_env, secret_key_env)

Create an Alpaca exchange connection. Keys are read from environment
variables (never passed as string literals).
"""
function AlpacaExchange(; execution_mode::ExecutionMode=PAPER,
                         api_key_env::String="QE_ALPACA_API_KEY",
                         secret_key_env::String="QE_ALPACA_SECRET_KEY")
    api_key = get(ENV, api_key_env, "")
    secret_key = get(ENV, secret_key_env, "")

    if isempty(api_key) || isempty(secret_key)
        error("Alpaca API keys not set. Set $api_key_env and $secret_key_env environment variables.")
    end

    # URL selection enforced by execution mode
    base_url = if execution_mode == LIVE
        @warn "AlpacaExchange: LIVE mode — real money trading enabled"
        "https://api.alpaca.markets"
    else
        "https://paper-api.alpaca.markets"
    end

    # Alpaca rate limit: 200 req/min
    limiter = RateLimiter(max_per_minute=180, max_per_second=3)

    AlpacaExchange(api_key, secret_key, base_url, execution_mode,
                   limiter, Dict{String,Float64}(), ReentrantLock())
end

"""Build authenticated headers for Alpaca API calls."""
function _alpaca_headers(ex::AlpacaExchange)
    return ["APCA-API-KEY-ID" => ex.api_key,
            "APCA-API-SECRET-KEY" => ex.secret_key,
            "Content-Type" => "application/json"]
end

"""Make an authenticated GET request to Alpaca API."""
function _alpaca_get(ex::AlpacaExchange, endpoint::String)
    wait_for_slot!(ex.rate_limiter)
    url = "$(ex.base_url)$endpoint"
    resp = HTTP.get(url, _alpaca_headers(ex);
                    connect_timeout=10, readtimeout=15)
    return JSON.parse(String(resp.body))
end

"""Make an authenticated POST request to Alpaca API."""
function _alpaca_post(ex::AlpacaExchange, endpoint::String, body::Dict)
    wait_for_slot!(ex.rate_limiter)
    url = "$(ex.base_url)$endpoint"
    resp = HTTP.post(url, _alpaca_headers(ex), JSON.json(body);
                     connect_timeout=10, readtimeout=15)
    return JSON.parse(String(resp.body))
end

"""Make an authenticated DELETE request to Alpaca API."""
function _alpaca_delete(ex::AlpacaExchange, endpoint::String)
    wait_for_slot!(ex.rate_limiter)
    url = "$(ex.base_url)$endpoint"
    resp = HTTP.delete(url, _alpaca_headers(ex);
                       connect_timeout=10, readtimeout=15)
    return resp.status
end

# ── AbstractExchange Interface Implementation ─────────────────

function place_order(ex::AlpacaExchange, asset::String, direction::Symbol,
                     instrument::Symbol, size_dollars::Float64;
                     order_type::Symbol=:market, limit_price::Float64=0.0)
    lock(ex.lock) do
        # Get current price for quantity calculation
        price = get(ex.last_prices, asset, 0.0)
        if price <= 0.0
            try
                price = get_current_price(ex, asset)
            catch
                return (order_id="ERROR", status=:price_unavailable, fill_price=0.0)
            end
        end

        qty = max(floor(size_dollars / price, digits=2), 0.01)

        # Map direction to Alpaca side
        side = direction in (:buy, :long) ? "buy" : "sell"

        # Map order type
        alpaca_type = if order_type == :market
            "market"
        elseif order_type == :limit
            "limit"
        elseif order_type == :stop_limit
            "stop_limit"
        else
            "market"
        end

        body = Dict{String,Any}(
            "symbol" => uppercase(replace(asset, "-USD" => "USD")),
            "qty" => string(qty),
            "side" => side,
            "type" => alpaca_type,
            "time_in_force" => "day"
        )

        if order_type == :limit && limit_price > 0.0
            body["limit_price"] = string(round(limit_price, digits=2))
        elseif order_type == :stop_limit && limit_price > 0.0
            body["stop_price"] = string(round(limit_price, digits=2))
            body["limit_price"] = string(round(limit_price * 1.01, digits=2))
        end

        try
            result = _alpaca_post(ex, "/v2/orders", body)
            order_id = get(result, "id", "unknown")
            status_str = get(result, "status", "unknown")
            fill_price_str = get(result, "filled_avg_price", nothing)
            fill_price = fill_price_str !== nothing ? parse(Float64, fill_price_str) : price

            status = if status_str in ("filled", "partially_filled")
                :filled
            elseif status_str in ("new", "accepted", "pending_new")
                :pending
            else
                :rejected
            end

            return (order_id=order_id, status=status, fill_price=fill_price)
        catch e
            err_msg = sprint(showerror, e)[1:min(100, end)]
            @warn "Alpaca order failed: $err_msg"
            return (order_id="ERROR", status=:error, fill_price=0.0)
        end
    end
end

function get_balance(ex::AlpacaExchange)::Float64
    try
        account = _alpaca_get(ex, "/v2/account")
        return parse(Float64, get(account, "buying_power", "0"))
    catch e
        @warn "Alpaca get_balance failed: $(sprint(showerror, e)[1:min(60,end)])"
        return 0.0
    end
end

function get_current_price(ex::AlpacaExchange, asset::String)::Float64
    symbol = uppercase(replace(asset, "-USD" => "USD"))
    try
        data = _alpaca_get(ex, "/v2/stocks/$symbol/trades/latest")
        trade = get(data, "trade", Dict())
        price = parse(Float64, string(get(trade, "p", "0")))
        lock(ex.lock) do
            ex.last_prices[asset] = price
        end
        return price
    catch e
        # Fallback to cached price
        cached = lock(ex.lock) do
            get(ex.last_prices, asset, NaN)
        end
        if !isnan(cached)
            return cached
        end
        @warn "Alpaca price fetch failed for $asset: $(sprint(showerror, e)[1:min(60,end)])"
        return NaN
    end
end

function cancel_order(ex::AlpacaExchange, order_id::String)::Bool
    try
        status = _alpaca_delete(ex, "/v2/orders/$order_id")
        return status in (200, 204)
    catch e
        @warn "Alpaca cancel failed: $(sprint(showerror, e)[1:min(60,end)])"
        return false
    end
end

function get_open_orders(ex::AlpacaExchange)::Vector{NamedTuple}
    try
        orders = _alpaca_get(ex, "/v2/orders?status=open")
        return [(order_id=get(o, "id", ""),
                 asset=get(o, "symbol", ""),
                 side=Symbol(get(o, "side", "buy")),
                 qty=parse(Float64, get(o, "qty", "0")),
                 order_type=Symbol(get(o, "type", "market")),
                 status=Symbol(get(o, "status", "unknown")))
                for o in orders]
    catch e
        @warn "Alpaca get_open_orders failed: $(sprint(showerror, e)[1:min(60,end)])"
        return NamedTuple[]
    end
end
