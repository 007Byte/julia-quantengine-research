# ── Alpaca Position Reconciliation ────────────────────────────
# Syncs our PositionTracker with Alpaca's server-side positions.
# Called on startup and periodically to detect fills, cancellations,
# and corporate actions.

"""Fetch all open positions from Alpaca."""
function alpaca_get_positions(ex::AlpacaExchange)
    try
        positions = _alpaca_get(ex, "/v2/positions")
        return [(asset=get(p, "symbol", ""),
                 side=Symbol(get(p, "side", "long")),
                 qty=parse(Float64, get(p, "qty", "0")),
                 entry_price=parse(Float64, get(p, "avg_entry_price", "0")),
                 current_price=parse(Float64, get(p, "current_price", "0")),
                 market_value=parse(Float64, get(p, "market_value", "0")),
                 unrealized_pnl=parse(Float64, get(p, "unrealized_pl", "0")),
                 unrealized_pnl_pct=parse(Float64, get(p, "unrealized_plpc", "0")) * 100)
                for p in positions]
    catch e
        @warn "Failed to fetch Alpaca positions: $(sprint(showerror, e)[1:min(80,end)])"
        return NamedTuple[]
    end
end

"""Fetch Alpaca account info."""
function alpaca_get_account(ex::AlpacaExchange)
    try
        acct = _alpaca_get(ex, "/v2/account")
        return (equity=parse(Float64, get(acct, "equity", "0")),
                buying_power=parse(Float64, get(acct, "buying_power", "0")),
                cash=parse(Float64, get(acct, "cash", "0")),
                portfolio_value=parse(Float64, get(acct, "portfolio_value", "0")),
                day_trade_count=parse(Int, get(acct, "daytrade_count", "0")),
                pattern_day_trader=get(acct, "pattern_day_trader", false),
                status=get(acct, "status", "UNKNOWN"))
    catch e
        @warn "Failed to fetch Alpaca account: $(sprint(showerror, e)[1:min(80,end)])"
        return nothing
    end
end

"""
    reconcile_positions!(tracker, ex; verbose)

Reconcile our PositionTracker with Alpaca's server-side positions.
- Detects positions that were filled/closed on Alpaca but not in our tracker
- Updates current prices for all tracked positions
- Logs discrepancies for audit
"""
function reconcile_positions!(tracker::PositionTracker, ex::AlpacaExchange;
                               verbose::Bool=true)
    alpaca_positions = alpaca_get_positions(ex)
    alpaca_assets = Set(p.asset for p in alpaca_positions)

    our_positions = lock(tracker.lock) do
        collect(keys(tracker.positions))
    end

    discrepancies = String[]

    # Check for positions we track that Alpaca doesn't have (closed externally)
    for asset in our_positions
        if !(uppercase(replace(asset, "-USD" => "USD")) in alpaca_assets)
            push!(discrepancies, "CLOSED_EXTERNALLY: $asset (in tracker but not on Alpaca)")
        end
    end

    # Check for positions on Alpaca that we don't track (opened externally)
    for pos in alpaca_positions
        found = any(uppercase(replace(a, "-USD" => "USD")) == pos.asset for a in our_positions)
        if !found
            push!(discrepancies, "OPENED_EXTERNALLY: $(pos.asset) (on Alpaca but not in tracker)")
        end
    end

    # Update prices for matched positions
    for pos in alpaca_positions
        for asset in our_positions
            if uppercase(replace(asset, "-USD" => "USD")) == pos.asset
                lock(tracker.lock) do
                    if haskey(tracker.positions, asset)
                        tracker.positions[asset].current_price = pos.current_price
                        tracker.positions[asset].pnl = pos.unrealized_pnl
                        tracker.positions[asset].pnl_pct = pos.unrealized_pnl_pct
                    end
                end
            end
        end
    end

    if verbose && !isempty(discrepancies)
        println("  ⚠ Position reconciliation found $(length(discrepancies)) discrepancies:")
        for d in discrepancies
            println("    → $d")
        end
    end

    return (n_alpaca=length(alpaca_positions),
            n_tracker=length(our_positions),
            discrepancies=discrepancies)
end

"""Close all positions on Alpaca (emergency function)."""
function alpaca_close_all_positions!(ex::AlpacaExchange)
    try
        _alpaca_delete(ex, "/v2/positions")
        @warn "All Alpaca positions closed"
        return true
    catch e
        @warn "Failed to close all positions: $(sprint(showerror, e)[1:min(80,end)])"
        return false
    end
end
