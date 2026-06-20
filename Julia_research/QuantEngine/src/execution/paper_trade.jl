# ── Paper Trading Exchange — Default Safe Implementation ──────

mutable struct PaperExchange <: AbstractExchange
    balance::Float64
    last_prices::Dict{String, Float64}
    order_log::Vector{NamedTuple}
    order_counter::Int
    lock::ReentrantLock
end

function PaperExchange(initial_balance::Float64)
    PaperExchange(initial_balance, Dict{String,Float64}(), NamedTuple[], 0, ReentrantLock())
end

function place_order(ex::PaperExchange, asset::String, direction::Symbol,
                     instrument::Symbol, size_dollars::Float64;
                     order_type::Symbol=:market, limit_price::Float64=0.0)
    lock(ex.lock) do
        # Validate balance
        if size_dollars > ex.balance
            return (order_id="REJECTED", status=:insufficient_funds, fill_price=0.0)
        end

        ex.order_counter += 1
        order_id = "PAPER-$(lpad(ex.order_counter, 6, '0'))"

        # Simulate fill at current/limit price
        fill_price = order_type == :limit ? limit_price :
                     get(ex.last_prices, asset, limit_price)

        entry = (id=order_id, timestamp=now(), asset=asset, direction=direction,
                 instrument=instrument, size=size_dollars, order_type=order_type,
                 fill_price=fill_price, status=:filled)
        push!(ex.order_log, entry)

        # Deduct from balance
        ex.balance -= size_dollars

        return (order_id=order_id, status=:filled, fill_price=fill_price)
    end
end

function get_balance(ex::PaperExchange)::Float64
    lock(ex.lock) do
        return ex.balance
    end
end

function get_current_price(ex::PaperExchange, asset::String)::Float64
    lock(ex.lock) do
        return get(ex.last_prices, asset, NaN)
    end
end

"""Update the latest known price for an asset (called by live feed)."""
function update_price!(ex::PaperExchange, asset::String, price::Float64)
    lock(ex.lock) do
        ex.last_prices[asset] = price
    end
end

function cancel_order(ex::PaperExchange, order_id::String)::Bool
    # Paper exchange: all orders fill immediately, nothing to cancel
    return false
end

function get_open_orders(ex::PaperExchange)::Vector{NamedTuple}
    return NamedTuple[]  # all orders fill immediately in paper mode
end
