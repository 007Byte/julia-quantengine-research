# ── Circuit Breakers — Defense-in-Depth Layer 4 ──────────────

"""Preflight risk check — called before running any pipeline step."""
function preflight_risk_check(tracker::PositionTracker, config::PipelineConfig,
                              asset::String)::Tuple{Bool, String}
    maybe_reset_daily!(tracker)

    if !can_open_position(tracker, config, asset)
        snap = tracker_snapshot(tracker)
        reason = if haskey(tracker.positions, asset)
            "Already in position for $asset"
        elseif length(tracker.positions) >= config.max_concurrent_positions
            "Max concurrent positions reached ($(config.max_concurrent_positions))"
        elseif snap.daily_pnl < -config.max_daily_loss_pct * tracker.peak_bankroll
            "Daily loss limit breached: \$$(round(snap.daily_pnl, digits=2))"
        elseif snap.drawdown / 100 > config.max_drawdown_pct
            "Max drawdown breached: $(round(snap.drawdown, digits=1))%"
        elseif tracker.cooling_countdown > 0
            "Cooling period active: $(tracker.cooling_countdown) iterations remaining"
        else
            "Bankroll too low: \$$(round(tracker.bankroll, digits=2))"
        end
        return (false, reason)
    end
    return (true, "OK")
end

"""Post-trade risk check — called after every trade closes."""
function post_trade_risk_check!(tracker::PositionTracker, config::PipelineConfig)::Tuple{Bool, String}
    snap = tracker_snapshot(tracker)

    # Daily loss limit
    if snap.daily_pnl < -config.max_daily_loss_pct * tracker.peak_bankroll
        return (false, "DAILY LOSS LIMIT: \$$(round(snap.daily_pnl, digits=2)) — halting new trades")
    end

    # Drawdown limit
    if snap.drawdown / 100 > config.max_drawdown_pct
        return (false, "MAX DRAWDOWN: $(round(snap.drawdown, digits=1))% — halting")
    end

    # Consecutive losses → enter cooling period
    if snap.consecutive_losses >= 3
        lock(tracker.lock) do
            tracker.cooling_countdown = config.cooling_period_after_loss
        end
        return (true, "COOLING: $(config.cooling_period_after_loss) iterations after $(snap.consecutive_losses) consecutive losses")
    end

    return (true, "OK")
end

"""Decrement cooling countdown (call once per iteration in the main loop)."""
function tick_cooling!(tracker::PositionTracker)
    lock(tracker.lock) do
        if tracker.cooling_countdown > 0
            tracker.cooling_countdown -= 1
        end
    end
end

"""Check if open positions have hit stop-loss or take-profit."""
function check_position_exits!(tracker::PositionTracker, get_price::Function)::Vector{NamedTuple}
    exits = NamedTuple[]
    assets_to_check = lock(tracker.lock) do
        collect(keys(tracker.positions))
    end

    for asset in assets_to_check
        pos = lock(tracker.lock) do
            get(tracker.positions, asset, nothing)
        end
        pos === nothing && continue

        current_price = try
            get_price(asset)
        catch
            continue  # skip if price fetch fails
        end

        # Update current price
        lock(tracker.lock) do
            if haskey(tracker.positions, asset)
                tracker.positions[asset].current_price = current_price
                if pos.direction == :long
                    tracker.positions[asset].pnl_pct = (current_price / pos.entry_price - 1.0) * 100
                else
                    tracker.positions[asset].pnl_pct = (1.0 - current_price / pos.entry_price) * 100
                end
                tracker.positions[asset].pnl = pos.size_dollars * tracker.positions[asset].pnl_pct / 100
            end
        end

        pnl_pct = pos.direction == :long ?
            (current_price / pos.entry_price - 1.0) * 100 :
            (1.0 - current_price / pos.entry_price) * 100

        # Stop-loss hit
        if pnl_pct <= -pos.stop_loss_pct
            result = close_position!(tracker, asset, current_price)
            if result !== nothing
                push!(exits, (reason=:stop_loss, result...))
            end
        # Take-profit hit
        elseif pnl_pct >= pos.take_profit_pct
            result = close_position!(tracker, asset, current_price)
            if result !== nothing
                push!(exits, (reason=:take_profit, result...))
            end
        # Hold time expired
        elseif (now() - pos.entry_time) > Hour(round(Int, pos.target_hold_hours))
            result = close_position!(tracker, asset, current_price)
            if result !== nothing
                push!(exits, (reason=:time_expired, result...))
            end
        end
    end

    return exits
end
