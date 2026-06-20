# ── Pipeline Types ────────────────────────────────────────────
# Secure-By-Design: All fields typed, no Any where avoidable

"""Execution mode — must be explicitly set to LIVE for real trading."""
@enum ExecutionMode PAPER LIVE

"""Event that triggers the pipeline — emitted by Step 1."""
struct PipelineEvent
    timestamp::DateTime
    asset::String
    asset_type::Symbol              # :stock, :crypto, :polymarket
    trigger_type::Symbol            # :volume_spike, :orderbook_imbalance, :price_jump, :manual
    trigger_data::Dict{String,Any}
    price_at_trigger::Float64
    volume_at_trigger::Float64
end

"""All configurable thresholds — loaded from ENV, never hardcoded."""
struct PipelineConfig
    # Step 1: Trigger thresholds
    volume_spike_multiplier::Float64
    orderbook_imbalance_threshold::Float64
    price_jump_threshold::Float64

    # Step 5: Calibration gate
    calibration_gap_max::Float64

    # Step 7: EV filter
    ev_gap_min::Float64

    # Step 8: Kelly bounds
    kelly_min_fraction::Float64
    kelly_max_fraction::Float64

    # Risk limits
    max_position_pct::Float64
    max_daily_loss_pct::Float64
    max_drawdown_pct::Float64
    max_concurrent_positions::Int

    # Operational
    poll_interval_ms::Int
    data_lookback_days::Int
    fee_rate::Float64
    initial_bankroll::Float64

    # Behavior
    force_conservative::Bool
    cooling_period_after_loss::Int   # iterations to force conservative after a loss

    # Execution mode — PAPER (default) or LIVE
    execution_mode::ExecutionMode
end

"""Mutable state tracked across the pipeline for one event."""
mutable struct PipelineState
    event::PipelineEvent
    ctx::AnalysisContext
    step_results::Dict{Int,Any}
    step_log::Vector{RalphLog}
    passed_steps::Vector{Int}
    aborted::Bool
    abort_reason::String
    lock::ReentrantLock
end

function PipelineState(event::PipelineEvent, ctx::AnalysisContext)
    PipelineState(event, ctx, Dict{Int,Any}(), RalphLog[], Int[], false, "", ReentrantLock())
end

# Steps 5 (Calibration) and 7 (EV Gap) are hard gates — pipeline aborts if they fail
const REQUIRED_STEPS = Set([5, 7])
