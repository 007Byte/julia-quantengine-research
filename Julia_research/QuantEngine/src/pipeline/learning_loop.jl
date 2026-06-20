# ── Continuous Learning Loop ─────────────────────────────────
# Auto-retrains models and updates calibration after each trade cycle.
# Runs as a background task alongside the main pipeline.

"""Configuration for the learning loop."""
struct LearningConfig
    retrain_interval_hours::Int    # how often to retrain NN models (default: 24)
    calibration_update_trades::Int # update calibration table every N trades (default: 10)
    min_samples_for_retrain::Int   # minimum new samples before retraining (default: 50)
    auto_promote_ab::Bool          # auto-promote A/B test winner (default: true)
end

function LearningConfig(; retrain_interval_hours::Int=24,
                         calibration_update_trades::Int=10,
                         min_samples_for_retrain::Int=50,
                         auto_promote_ab::Bool=true)
    LearningConfig(retrain_interval_hours, calibration_update_trades,
                   min_samples_for_retrain, auto_promote_ab)
end

"""State of the learning loop."""
mutable struct LearningState
    last_retrain::DateTime
    trades_since_calibration::Int
    total_retrains::Int
    total_calibration_updates::Int
    lock::ReentrantLock
end

LearningState() = LearningState(now(), 0, 0, 0, ReentrantLock())

"""
    should_retrain(state, config) → Bool

Check if it's time to retrain NN models.
"""
function should_retrain(state::LearningState, config::LearningConfig)::Bool
    lock(state.lock) do
        hours_since = Dates.value(now() - state.last_retrain) / (1000 * 60 * 60)
        return hours_since >= config.retrain_interval_hours
    end
end

"""
    should_update_calibration(state, config) → Bool

Check if calibration table should be updated.
"""
function should_update_calibration(state::LearningState, config::LearningConfig)::Bool
    lock(state.lock) do
        return state.trades_since_calibration >= config.calibration_update_trades
    end
end

"""Record that a trade occurred (thread-safe)."""
function record_trade_for_learning!(state::LearningState)
    lock(state.lock) do
        state.trades_since_calibration += 1
    end
end

"""Record that retraining occurred (thread-safe)."""
function record_retrain!(state::LearningState)
    lock(state.lock) do
        state.last_retrain = now()
        state.total_retrains += 1
    end
end

"""Record that calibration was updated (thread-safe)."""
function record_calibration_update!(state::LearningState)
    lock(state.lock) do
        state.trades_since_calibration = 0
        state.total_calibration_updates += 1
    end
end

"""
    trigger_retrain!(cache, ticker, n_features)

Force retraining of all cached models for a ticker by clearing their cache.
Next run will train fresh with the latest data.
"""
function trigger_retrain!(cache, ticker::String, n_features::Int)
    if cache === nothing
        return
    end
    lock(cache.lock) do
        keys_to_remove = [k for k in keys(cache.entries)
                          if k[2] == ticker]
        for k in keys_to_remove
            delete!(cache.entries, k)
        end
    end
end

"""
    update_calibration_from_trades!(cal_table, trade_db; lookback_days)

Update the calibration table using recent resolved trades from the database.
Compares what the model predicted vs what actually happened.
"""
function update_calibration_from_trades!(cal_table::CalibrationTable,
                                          trade_db; lookback_days::Int=30)
    if trade_db === nothing
        return 0
    end
    trades = try
        db_get_trades(trade_db; limit=100)
    catch
        return 0
    end

    n_updated = 0
    for trade in trades
        # predicted probability ≈ confidence/100 (rough proxy)
        conf = get(trade, :confidence, nothing)
        pnl = get(trade, :pnl, nothing)
        if conf !== nothing && pnl !== nothing && !ismissing(conf) && !ismissing(pnl)
            predicted = clamp(Float64(conf) / 100.0, 0.01, 0.99)
            resolved_win = Float64(pnl) > 0
            record_prediction!(cal_table, predicted, resolved_win)
            n_updated += 1
        end
    end
    return n_updated
end

"""Get learning loop status."""
function learning_status(state::LearningState)
    lock(state.lock) do
        hours_since = Dates.value(now() - state.last_retrain) / (1000 * 60 * 60)
        return (hours_since_retrain=round(hours_since, digits=1),
                trades_since_cal=state.trades_since_calibration,
                total_retrains=state.total_retrains,
                total_cal_updates=state.total_calibration_updates)
    end
end
