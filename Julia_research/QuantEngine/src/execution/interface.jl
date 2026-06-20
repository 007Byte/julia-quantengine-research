# ── Abstract Exchange Interface ───────────────────────────────
# Every exchange implementation must satisfy this contract.

abstract type AbstractExchange end

"""Place an order. Returns (order_id, status, fill_price)."""
function place_order(ex::AbstractExchange, asset::String, direction::Symbol,
                     instrument::Symbol, size_dollars::Float64;
                     order_type::Symbol=:market, limit_price::Float64=0.0)
    error("place_order not implemented for $(typeof(ex))")
end

"""Get current account balance."""
function get_balance(ex::AbstractExchange)::Float64
    error("get_balance not implemented for $(typeof(ex))")
end

"""Get current price for an asset."""
function get_current_price(ex::AbstractExchange, asset::String)::Float64
    error("get_current_price not implemented for $(typeof(ex))")
end

"""Cancel an open order."""
function cancel_order(ex::AbstractExchange, order_id::String)::Bool
    error("cancel_order not implemented for $(typeof(ex))")
end

"""Get all open orders."""
function get_open_orders(ex::AbstractExchange)::Vector{NamedTuple}
    error("get_open_orders not implemented for $(typeof(ex))")
end
