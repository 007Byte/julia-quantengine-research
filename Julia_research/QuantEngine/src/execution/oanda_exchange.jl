# ── OANDA Exchange — FX REST v20 Adapter ───────────────────────────────
# Implements AbstractExchange for OANDA v20 REST API.
#
# Operational model:
# - Initial full account snapshot on connect
# - Incremental update by transaction ID (OANDA best practice)
# - Periodic account refresh as safety net
# - Financing/rollover awareness
# - Session-aware (Sydney/Tokyo/London/NY)
#
# Uses positive/negative units for buy/sell (OANDA convention).

using HTTP
using JSON
using Dates

const OANDA_PRACTICE_URL = "https://api-fxpractice.oanda.com"
const OANDA_LIVE_URL = "https://api-fxtrade.oanda.com"
const OANDA_STREAM_PRACTICE = "https://stream-fxpractice.oanda.com"
const OANDA_STREAM_LIVE = "https://stream-fxtrade.oanda.com"

"""OANDA v20 exchange implementation."""
mutable struct OandaExchange <: AbstractExchange
    api_token::String
    account_id::String
    base_url::String
    stream_url::String
    execution_mode::ExecutionMode
    rate_limiter::RateLimiter
    last_transaction_id::String    # for incremental sync
    last_prices::Dict{String, Float64}
    last_account_refresh::Float64
    lock::ReentrantLock
end

function OandaExchange(;
    execution_mode::ExecutionMode = PAPER,
    api_token_env::String = "QE_OANDA_API_TOKEN",
    account_id_env::String = "QE_OANDA_ACCOUNT_ID",
)
    api_token = get(ENV, api_token_env, "")
    account_id = get(ENV, account_id_env, "")

    if isempty(api_token) || isempty(account_id)
        error("OANDA credentials not set. Set $api_token_env and $account_id_env")
    end

    base_url = execution_mode == LIVE ? OANDA_LIVE_URL : OANDA_PRACTICE_URL
    stream_url = execution_mode == LIVE ? OANDA_STREAM_LIVE : OANDA_STREAM_PRACTICE

    if execution_mode == LIVE
        @warn "OandaExchange: LIVE mode — real money trading enabled"
    end

    limiter = RateLimiter(max_per_minute=120, max_per_second=10)

    OandaExchange(
        api_token, account_id, base_url, stream_url, execution_mode,
        limiter, "", Dict{String,Float64}(), 0.0, ReentrantLock(),
    )
end

function _oanda_headers(ex::OandaExchange)
    ["Authorization" => "Bearer $(ex.api_token)",
     "Content-Type" => "application/json",
     "Accept-Datetime-Format" => "RFC3339"]
end

function _oanda_request(ex::OandaExchange, method::Symbol, endpoint::String;
                        body::Union{String, Nothing}=nothing)
    wait_for_slot!(ex.rate_limiter)
    url = "$(ex.base_url)$endpoint"

    resp = if method == :GET
        HTTP.get(url, _oanda_headers(ex);
                 connect_timeout=10, readtimeout=15, status_exception=false)
    elseif method == :POST
        HTTP.post(url, _oanda_headers(ex), something(body, "");
                  connect_timeout=10, readtimeout=15, status_exception=false)
    elseif method == :PUT
        HTTP.put(url, _oanda_headers(ex), something(body, "");
                 connect_timeout=10, readtimeout=15, status_exception=false)
    else
        error("Unsupported method: $method")
    end

    if resp.status >= 400
        @error "OANDA API error: $(resp.status) — $(String(resp.body))"
        error("OANDA API error $(resp.status)")
    end

    return JSON.parse(String(resp.body))
end

# ── Initial Snapshot ──────────────────────────────────────────

"""Full account snapshot — call on connect and periodically."""
function oanda_account_snapshot!(ex::OandaExchange)
    result = _oanda_request(ex, :GET, "/v3/accounts/$(ex.account_id)")
    account = get(result, "account", Dict())
    ex.last_transaction_id = get(account, "lastTransactionID", "")
    ex.last_account_refresh = time()

    @info "OANDA snapshot: balance=$(get(account, "balance", "?")) " *
          "NAV=$(get(account, "NAV", "?")) " *
          "lastTxn=$(ex.last_transaction_id)"

    return account
end

# ── Incremental Sync by Transaction ID ───────────────────────

"""
Poll for changes since last transaction ID.
OANDA best practice: don't re-fetch everything, use sinceTransactionID.
"""
function oanda_poll_changes!(ex::OandaExchange)::Vector{Dict{String,Any}}
    if isempty(ex.last_transaction_id)
        return Dict{String,Any}[]
    end

    result = _oanda_request(ex, :GET,
        "/v3/accounts/$(ex.account_id)/changes?sinceTransactionID=$(ex.last_transaction_id)")

    changes = get(result, "changes", Dict())
    ex.last_transaction_id = get(result, "lastTransactionID", ex.last_transaction_id)

    events = Dict{String,Any}[]
    for order in get(changes, "ordersFilled", [])
        push!(events, Dict("type" => "order_filled", "data" => order))
    end
    for order in get(changes, "ordersCancelled", [])
        push!(events, Dict("type" => "order_cancelled", "data" => order))
    end
    for trade in get(changes, "tradesOpened", [])
        push!(events, Dict("type" => "trade_opened", "data" => trade))
    end
    for trade in get(changes, "tradesClosed", [])
        push!(events, Dict("type" => "trade_closed", "data" => trade))
    end

    return events
end

# ── AbstractExchange Implementation ───────────────────────────

function place_order(ex::OandaExchange, asset::String, direction::Symbol,
                     instrument::Symbol, size_dollars::Float64;
                     order_type::Symbol=:market, limit_price::Float64=0.0)

    current_price = get_current_price(ex, asset)
    if current_price <= 0
        error("Cannot get price for $asset")
    end

    # OANDA uses units: positive=buy, negative=sell
    units = round(Int, size_dollars / current_price)
    if direction == :sell || direction == :short
        units = -units
    end

    order_body = Dict{String,Any}(
        "order" => Dict{String,Any}(
            "instrument" => asset,
            "units" => string(units),
            "type" => uppercase(string(order_type)),
            "timeInForce" => order_type == :market ? "FOK" : "GTC",
        )
    )

    if order_type == :limit && limit_price > 0
        order_body["order"]["price"] = string(round(limit_price, digits=5))
    end

    result = _oanda_request(ex, :POST,
        "/v3/accounts/$(ex.account_id)/orders";
        body=JSON.json(order_body))

    # OANDA returns different structures for immediate fills vs pending
    fill_txn = get(result, "orderFillTransaction", Dict())
    create_txn = get(result, "orderCreateTransaction", Dict())
    txn = !isempty(fill_txn) ? fill_txn : create_txn

    order_id = string(get(txn, "id", ""))
    fill_price = if !isempty(fill_txn)
        parse(Float64, get(fill_txn, "price", string(current_price)))
    else
        current_price
    end
    status = !isempty(fill_txn) ? "FILLED" : "PENDING"

    @info "OANDA order: $asset $(direction) $(abs(units)) units @ $fill_price → txn=$order_id"

    return (order_id=order_id, status=status, fill_price=fill_price)
end

function get_balance(ex::OandaExchange)::Float64
    result = _oanda_request(ex, :GET, "/v3/accounts/$(ex.account_id)/summary")
    account = get(result, "account", Dict())
    return parse(Float64, get(account, "balance", "0"))
end

function get_current_price(ex::OandaExchange, asset::String)::Float64
    # Check cache
    cached = get(ex.last_prices, asset, 0.0)
    if cached > 0 && time() - get(ex.last_prices, "_ts_$asset", 0.0) < 5.0
        return cached
    end

    result = _oanda_request(ex, :GET,
        "/v3/accounts/$(ex.account_id)/pricing?instruments=$asset")
    prices = get(result, "prices", [])

    if isempty(prices)
        return 0.0
    end

    bid = parse(Float64, get(prices[1], "bids", [Dict("price"=>"0")])[1]["price"])
    ask = parse(Float64, get(prices[1], "asks", [Dict("price"=>"0")])[1]["price"])
    mid = (bid + ask) / 2.0

    lock(ex.lock) do
        ex.last_prices[asset] = mid
        ex.last_prices["_ts_$asset"] = time()
    end
    return mid
end

function cancel_order(ex::OandaExchange, order_id::String)::Bool
    try
        _oanda_request(ex, :PUT,
            "/v3/accounts/$(ex.account_id)/orders/$order_id/cancel")
        return true
    catch
        return false
    end
end

function get_open_orders(ex::OandaExchange)::Vector{NamedTuple}
    result = _oanda_request(ex, :GET,
        "/v3/accounts/$(ex.account_id)/pendingOrders")

    return [(
        broker_order_id = string(get(o, "id", "")),
        symbol = get(o, "instrument", ""),
        side = parse(Float64, get(o, "units", "0")) > 0 ? "buy" : "sell",
        quantity = string(abs(parse(Float64, get(o, "units", "0")))),
        status = get(o, "state", "PENDING"),
        type = get(o, "type", ""),
    ) for o in get(result, "orders", [])]
end

# ── Reconciliation Queries ────────────────────────────────────

"""Get open positions from OANDA for reconciliation."""
function oanda_get_positions(ex::OandaExchange)::Vector{NamedTuple}
    result = _oanda_request(ex, :GET,
        "/v3/accounts/$(ex.account_id)/openPositions")

    positions = NamedTuple[]
    for p in get(result, "positions", [])
        long_units = parse(Float64, get(get(p, "long", Dict()), "units", "0"))
        short_units = parse(Float64, get(get(p, "short", Dict()), "units", "0"))
        net = long_units + short_units  # short is negative

        if abs(net) > 1e-8
            push!(positions, (
                symbol = get(p, "instrument", ""),
                quantity = net,
                unrealized_pnl = parse(Float64, get(p, "unrealizedPL", "0")),
                financing = parse(Float64, get(p, "financing", "0")),
            ))
        end
    end
    return positions
end

"""Get account summary for reconciliation."""
function oanda_get_account_summary(ex::OandaExchange)::NamedTuple
    result = _oanda_request(ex, :GET, "/v3/accounts/$(ex.account_id)/summary")
    acct = get(result, "account", Dict())
    return (
        balance = parse(Float64, get(acct, "balance", "0")),
        unrealized_pnl = parse(Float64, get(acct, "unrealizedPL", "0")),
        nav = parse(Float64, get(acct, "NAV", "0")),
        margin_used = parse(Float64, get(acct, "marginUsed", "0")),
        margin_available = parse(Float64, get(acct, "marginAvailable", "0")),
        financing = parse(Float64, get(acct, "financing", "0")),
        open_trade_count = parse(Int, get(acct, "openTradeCount", "0")),
    )
end

"""Get financing rates for an instrument."""
function oanda_get_financing(ex::OandaExchange, instrument::String)
    try
        result = _oanda_request(ex, :GET,
            "/v3/accounts/$(ex.account_id)/instruments/$instrument/candles?count=1&granularity=D")
        return result
    catch
        return Dict()
    end
end
