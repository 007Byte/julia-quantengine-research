# ── Position Tracker — Thread-Safe Portfolio State ────────────

mutable struct PositionTracker
    positions::Dict{String, PositionState}
    bankroll::Float64
    daily_pnl::Float64
    daily_pnl_reset_date::Date
    peak_bankroll::Float64
    total_trades::Int
    winning_trades::Int
    losing_trades::Int
    consecutive_losses::Int
    cooling_countdown::Int          # iterations remaining in cooling period
    lock::ReentrantLock
end

function PositionTracker(bankroll::Float64)
    PositionTracker(
        Dict{String, PositionState}(),
        bankroll, 0.0, Dates.today(), bankroll,
        0, 0, 0, 0, 0, ReentrantLock()
    )
end

"""Check if we can open a new position (thread-safe)."""
function can_open_position(tracker::PositionTracker, config::PipelineConfig, asset::String)::Bool
    lock(tracker.lock) do
        # Already in this asset
        haskey(tracker.positions, asset) && return false
        # Max concurrent positions
        length(tracker.positions) >= config.max_concurrent_positions && return false
        # Daily loss limit
        if tracker.daily_pnl < -config.max_daily_loss_pct * tracker.peak_bankroll
            return false
        end
        # Drawdown limit
        drawdown = (tracker.peak_bankroll - tracker.bankroll) / max(tracker.peak_bankroll, 1.0)
        drawdown > config.max_drawdown_pct && return false
        # Cooling period active
        tracker.cooling_countdown > 0 && return false
        # Bankroll too low for minimum trade
        tracker.bankroll < 10.0 && return false
        return true
    end
end

"""Open a new position (thread-safe)."""
function open_position!(tracker::PositionTracker, pos::PositionState)
    lock(tracker.lock) do
        tracker.positions[pos.asset] = pos
        tracker.bankroll -= pos.size_dollars
    end
end

"""Close a position and update PnL (thread-safe)."""
function close_position!(tracker::PositionTracker, asset::String, exit_price::Float64)
    lock(tracker.lock) do
        if !haskey(tracker.positions, asset)
            @warn "No open position for $asset"
            return nothing
        end
        pos = tracker.positions[asset]
        # Calculate PnL
        if pos.direction == :long
            pnl = pos.size_dollars * (exit_price / pos.entry_price - 1.0)
        else  # :short
            pnl = pos.size_dollars * (1.0 - exit_price / pos.entry_price)
        end

        # Update tracker
        tracker.bankroll += pos.size_dollars + pnl
        tracker.daily_pnl += pnl
        tracker.total_trades += 1
        if pnl > 0
            tracker.winning_trades += 1
            tracker.consecutive_losses = 0
        else
            tracker.losing_trades += 1
            tracker.consecutive_losses += 1
        end
        # Update peak
        tracker.peak_bankroll = max(tracker.peak_bankroll, tracker.bankroll)

        delete!(tracker.positions, asset)
        return (asset=asset, pnl=pnl, exit_price=exit_price, bankroll=tracker.bankroll)
    end
end

"""Get current portfolio heat (% of bankroll at risk)."""
function portfolio_heat(tracker::PositionTracker)::Float64
    lock(tracker.lock) do
        if isempty(tracker.positions) || tracker.bankroll <= 0
            return 0.0
        end
        total_at_risk = sum(p.size_dollars for p in values(tracker.positions))
        return total_at_risk / (tracker.bankroll + total_at_risk) * 100.0
    end
end

"""Reset daily PnL at start of new trading day."""
function maybe_reset_daily!(tracker::PositionTracker)
    lock(tracker.lock) do
        if Dates.today() > tracker.daily_pnl_reset_date
            tracker.daily_pnl = 0.0
            tracker.daily_pnl_reset_date = Dates.today()
        end
    end
end

"""Get a snapshot of current state (thread-safe read)."""
function tracker_snapshot(tracker::PositionTracker)
    lock(tracker.lock) do
        (bankroll=tracker.bankroll, daily_pnl=tracker.daily_pnl,
         n_positions=length(tracker.positions),
         total_trades=tracker.total_trades,
         win_rate=tracker.total_trades > 0 ? tracker.winning_trades/tracker.total_trades*100 : 0.0,
         consecutive_losses=tracker.consecutive_losses,
         cooling=tracker.cooling_countdown > 0,
         drawdown=(tracker.peak_bankroll - tracker.bankroll) / max(tracker.peak_bankroll, 1.0) * 100)
    end
end
