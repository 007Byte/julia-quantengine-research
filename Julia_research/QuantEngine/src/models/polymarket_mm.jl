# ── Polymarket Market-Making Module ───────────────────────────
# Quotes around fair probability on liquid contracts.
# Uses LMSR + EV Gap + Kalman to set bid/ask spreads.
# Only activates on liquid markets (volume > threshold).

"""Market-making configuration."""
struct MMConfig
    spread_multiplier::Float64     # how wide to quote (1.0 = minimum profitable)
    max_position_shares::Float64   # max shares to hold per side
    min_volume::Float64            # minimum 24h volume to quote
    refresh_interval_sec::Int      # how often to re-quote
    max_inventory_skew::Float64    # max ratio of longs to shorts
end

function MMConfig(; spread_multiplier::Float64=1.5,
                   max_position_shares::Float64=500.0,
                   min_volume::Float64=10000.0,
                   refresh_interval_sec::Int=30,
                   max_inventory_skew::Float64=3.0)
    MMConfig(spread_multiplier, max_position_shares, min_volume,
             refresh_interval_sec, max_inventory_skew)
end

"""A two-sided quote (bid + ask) for market making."""
struct MMQuote
    bid_price::Float64
    ask_price::Float64
    bid_size::Float64
    ask_size::Float64
    fair_price::Float64
    spread::Float64
    edge_per_share::Float64
end

"""
    compute_mm_quotes(fair_prob, current_book, inventory; config)

Compute optimal bid/ask quotes for market making.
- Quotes centered on fair_prob
- Spread sized to cover fees + edge
- Inventory-adjusted: skew quotes away from heavy side
"""
function compute_mm_quotes(fair_prob::Float64, fee_rate::Float64,
                            inventory::Float64=0.0;
                            config::MMConfig=MMConfig())
    p = clamp(fair_prob, 0.02, 0.98)

    # Base spread: must cover round-trip fees + margin
    min_spread = 2.0 * fee_rate + 0.005  # 2x fee + 0.5% minimum profit
    target_spread = min_spread * config.spread_multiplier

    # Inventory adjustment: skew quotes to reduce inventory
    # Positive inventory = long → lower bid (less buying), raise ask (encourage selling)
    skew = clamp(inventory / max(config.max_position_shares, 1.0), -1.0, 1.0) * 0.01

    bid_price = clamp(p - target_spread / 2.0 - skew, 0.01, 0.98)
    ask_price = clamp(p + target_spread / 2.0 - skew, 0.02, 0.99)

    # Ensure bid < ask
    if bid_price >= ask_price
        mid = (bid_price + ask_price) / 2.0
        bid_price = mid - 0.005
        ask_price = mid + 0.005
    end

    # Size: reduce when inventory is high
    inventory_ratio = abs(inventory) / max(config.max_position_shares, 1.0)
    size_scale = clamp(1.0 - inventory_ratio * 0.5, 0.1, 1.0)
    base_size = config.max_position_shares * 0.1  # 10% of max per quote

    bid_size = base_size * size_scale
    ask_size = base_size * size_scale

    # If heavily long, reduce bid size (less buying), increase ask size (more selling)
    if inventory > 0
        bid_size *= (1.0 - inventory_ratio * 0.3)
        ask_size *= (1.0 + inventory_ratio * 0.3)
    elseif inventory < 0
        bid_size *= (1.0 + inventory_ratio * 0.3)
        ask_size *= (1.0 - inventory_ratio * 0.3)
    end

    spread = ask_price - bid_price
    edge_per_share = spread / 2.0 - fee_rate  # expected profit per share traded

    return MMQuote(bid_price, ask_price, bid_size, ask_size,
                   p, spread, edge_per_share)
end

"""
    should_market_make(volume, spread, fair_prob; config)

Decide whether to activate market making for a contract.
Only make markets on liquid contracts with wide enough spreads.
"""
function should_market_make(volume::Float64, spread::Float64,
                             fair_prob::Float64;
                             config::MMConfig=MMConfig())
    # Volume check
    if volume < config.min_volume
        return (make=false, reason="Volume too low: $(volume) < $(config.min_volume)")
    end

    # Don't MM on extreme probabilities (near resolution)
    if fair_prob < 0.05 || fair_prob > 0.95
        return (make=false, reason="Too extreme: p=$(fair_prob)")
    end

    # Spread must be wide enough to be profitable
    min_profitable_spread = 0.02  # 2 cents minimum
    if spread < min_profitable_spread
        return (make=false, reason="Spread too tight: $(spread) < $(min_profitable_spread)")
    end

    return (make=true, reason="Profitable opportunity: vol=$(volume), spread=$(spread)")
end

"""
    check_adverse_selection(cvd_signal, book_pressure, inventory) → (safe, reason)

Adverse selection guard: stop quoting when order flow turns against inventory.
"""
function check_adverse_selection(cvd_signal::Symbol, book_pressure::Float64,
                                   inventory::Float64)
    # Long inventory + bearish flow → stop buying
    if inventory > 0 && (cvd_signal == :distribution || book_pressure < -0.3)
        return (safe=false, reason="ADVERSE: long + bearish flow → stop buying")
    end
    # Short inventory + bullish flow → stop selling
    if inventory < 0 && (cvd_signal == :accumulation || book_pressure > 0.3)
        return (safe=false, reason="ADVERSE: short + bullish flow → stop selling")
    end
    # Strong directional flow → pause MM entirely
    if abs(book_pressure) > 0.6
        return (safe=false, reason="ADVERSE: strong flow ($(round(book_pressure, digits=2))) → pause")
    end
    return (safe=true, reason="No adverse selection")
end

"""Print market-making quote."""
function print_mm_quote(slug::String, mm::MMQuote)
    @printf("  MM %-25s | Bid: %.3f (%.0f) | Ask: %.3f (%.0f) | Fair: %.3f | Edge: %.4f/sh\n",
            slug, mm.bid_price, mm.bid_size, mm.ask_price, mm.ask_size,
            mm.fair_price, mm.edge_per_share)
end

"""
    check_inventory_limits(inventory, config) → (safe, action, reason)

Hard inventory limit check. Returns unwind instructions if exceeded.
"""
function check_inventory_limits(inventory::Float64;
                                 config::MMConfig=MMConfig())
    abs_inv = abs(inventory)

    if abs_inv > config.max_position_shares
        direction = inventory > 0 ? :sell : :buy
        excess = abs_inv - config.max_position_shares
        return (safe=false, action=:unwind, direction=direction,
                excess_shares=excess,
                reason="Inventory $(round(inventory, digits=0)) exceeds max $(config.max_position_shares)")
    end

    # Warning at 80% of max
    if abs_inv > config.max_position_shares * 0.8
        return (safe=true, action=:reduce_quotes,
                direction=inventory > 0 ? :sell_bias : :buy_bias,
                excess_shares=0.0,
                reason="Inventory $(round(inventory, digits=0)) at $(round(abs_inv/config.max_position_shares*100))% of max")
    end

    return (safe=true, action=:none, direction=:none,
            excess_shares=0.0, reason="Inventory within limits")
end

"""
    auto_unwind_size(inventory, config) → Float64

Calculate how many shares to unwind to return to safe inventory levels.
"""
function auto_unwind_size(inventory::Float64;
                           config::MMConfig=MMConfig(),
                           target_pct::Float64=0.5)  # unwind to 50% of max
    target = config.max_position_shares * target_pct
    excess = abs(inventory) - target
    return max(0.0, excess)
end
