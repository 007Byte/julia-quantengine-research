# ── Backtest Exchange — Simulated Fills at Historical Prices ──

"""Exchange that fills orders at historical prices with configurable slippage."""
mutable struct BacktestExchange <: AbstractExchange
    prices::Vector{Float64}         # full historical price array
    current_idx::Int                # current bar index
    balance::Float64
    cost_bps::Float64               # transaction cost in basis points
    slippage_bps::Float64           # slippage in basis points
    order_log::Vector{NamedTuple}
    lock::ReentrantLock
end

function BacktestExchange(prices::Vector{Float64}, initial_balance::Float64;
                          cost_bps::Float64=10.0, slippage_bps::Float64=5.0)
    BacktestExchange(prices, 1, initial_balance, cost_bps, slippage_bps,
                     NamedTuple[], ReentrantLock())
end

"""Set the current bar index (called by the walk-forward engine each step)."""
function set_bar!(ex::BacktestExchange, idx::Int)
    lock(ex.lock) do
        ex.current_idx = clamp(idx, 1, length(ex.prices))
    end
end

function place_order(ex::BacktestExchange, asset::String, direction::Symbol,
                     instrument::Symbol, size_dollars::Float64;
                     order_type::Symbol=:market, limit_price::Float64=0.0)
    lock(ex.lock) do
        if size_dollars > ex.balance
            return (order_id="rejected", status=:rejected, fill_price=0.0)
        end

        # Fill at next bar's price (if available), else current bar
        fill_idx = min(ex.current_idx + 1, length(ex.prices))
        base_price = ex.prices[fill_idx]

        # Apply slippage: buy at higher, sell at lower
        slip = base_price * ex.slippage_bps / 10000.0
        fill_price = direction == :buy ? base_price + slip : base_price - slip

        # Apply transaction cost
        cost = size_dollars * ex.cost_bps / 10000.0
        ex.balance -= cost

        order = (order_id="bt_$(ex.current_idx)_$(direction)",
                 status=:filled, fill_price=fill_price,
                 cost=cost, bar=ex.current_idx)
        push!(ex.order_log, order)

        return order
    end
end

function get_balance(ex::BacktestExchange)::Float64
    lock(ex.lock) do
        return ex.balance
    end
end

function get_current_price(ex::BacktestExchange, asset::String)::Float64
    lock(ex.lock) do
        return ex.prices[ex.current_idx]
    end
end

function cancel_order(ex::BacktestExchange, order_id::String)::Bool
    return false  # all orders fill immediately in backtest
end

function get_open_orders(ex::BacktestExchange)::Vector{NamedTuple}
    return NamedTuple[]  # all orders fill immediately
end
