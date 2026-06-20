# ── Realistic Slippage & Cost Model ──────────────────────────
# Hard-coded realistic transaction costs for each asset class.
# These are applied to EVERY edge calculation, Kelly sizing,
# and backtest simulation. They cannot be disabled.

"""Realistic all-in transaction costs per asset class."""
struct TransactionCosts
    fee_bps::Float64               # exchange fee in basis points
    slippage_bps::Float64          # expected slippage in basis points
    spread_bps::Float64            # typical half-spread in basis points
    funding_rate_daily_bps::Float64 # for perpetual futures (0 for spot)
end

"""Get realistic transaction costs for an asset type."""
function realistic_costs(asset_type::Symbol)::TransactionCosts
    if asset_type == :crypto
        # Binance taker: 10 bps, slippage: 5-20 bps on thin books
        TransactionCosts(10.0, 15.0, 5.0, 1.0)
    elseif asset_type == :polymarket
        # Polymarket: 100-200 bps effective (fee + spread + thin CLOB)
        TransactionCosts(50.0, 100.0, 50.0, 0.0)
    else  # :stock
        # Alpaca: ~0 commission, but SEC fee + spread + slippage
        TransactionCosts(1.0, 5.0, 3.0, 0.0)
    end
end

"""
    realistic_costs_limit(asset_type) → TransactionCosts

Costs when using LIMIT orders on liquid pairs (BTC, ETH, SOL, BNB).
Maker fees, minimal slippage (you pick your price), tight spreads.
Only valid for top-10 crypto by volume; use realistic_costs() otherwise.
"""
function realistic_costs_limit(asset_type::Symbol)::TransactionCosts
    if asset_type == :crypto
        # Binance maker: 1 bps, limit order slippage: ~2 bps, tight spread: 1-2 bps
        TransactionCosts(1.0, 2.0, 2.0, 1.0)
    else
        realistic_costs(asset_type)
    end
end

"""Total round-trip cost in basis points."""
function round_trip_cost_bps(costs::TransactionCosts)::Float64
    return 2.0 * (costs.fee_bps + costs.slippage_bps + costs.spread_bps) + costs.funding_rate_daily_bps
end

"""Total round-trip cost as a fraction (for return adjustment)."""
function round_trip_cost_fraction(costs::TransactionCosts)::Float64
    return round_trip_cost_bps(costs) / 10000.0
end

"""
    adjust_returns_for_costs(returns, asset_type)

Subtract realistic round-trip costs from every return.
This is the CONSERVATIVE approach: assumes every bar has a trade.
For Kelly and EV calculations, this prevents inflated edge estimates.
"""
function adjust_returns_for_costs(returns::Vector{Float64}, asset_type::Symbol)::Vector{Float64}
    costs = realistic_costs(asset_type)
    cost_per_trade = round_trip_cost_fraction(costs)
    return returns .- cost_per_trade
end

"""
    minimum_edge_required(asset_type) → Float64

The minimum EV (in fraction) needed to overcome all transaction costs.
Trades with edge below this should NEVER be taken.
"""
function minimum_edge_required(asset_type::Symbol)::Float64
    costs = realistic_costs(asset_type)
    # Need to clear round-trip costs + 50% buffer for safety
    return round_trip_cost_fraction(costs) * 1.5
end

"""Print cost summary for an asset type."""
function print_cost_summary(asset_type::Symbol)
    costs = realistic_costs(asset_type)
    rtc = round_trip_cost_bps(costs)
    min_edge = minimum_edge_required(asset_type)
    @printf("  %-12s | Fee: %4.0f bps | Slip: %4.0f bps | Spread: %4.0f bps | RT: %5.0f bps | Min edge: %.2f%%\n",
            asset_type, costs.fee_bps, costs.slippage_bps, costs.spread_bps,
            rtc, min_edge * 100)
end
