# ── Shadow Mode — Real Data, No Orders, Signal Comparison ──────────────
# Connects to real Binance data. Runs full Julia signal pipeline.
# Records what the system WOULD have done. Measures actual market outcome.
#
# Shadow mode produces:
# - Signal log with direction, strength, timestamp, price
# - Market outcome at 1m/5m/15m/1h after signal
# - Per-model contribution to ensemble score (dead-weight detection)
# - Hit rate, mean favorable move, directional accuracy
#
# No fills. No orders. No capital at risk.

using Dates
using UUIDs
using Statistics

mutable struct ShadowSignal
    signal_id::String
    instrument_id::String
    venue_symbol::String
    direction::Symbol          # :buy, :sell
    strength::Float64
    price_at_signal::Float64
    signal_time::DateTime
    # Per-model contributions (the whole point of shadow for ensemble pruning)
    model_contributions::Dict{String, Float64}   # model_id → contribution to final score
    model_directions::Dict{String, Symbol}       # model_id → direction voted
    # Outcomes — filled after observation window
    price_after_1m::Union{Float64, Nothing}
    price_after_5m::Union{Float64, Nothing}
    price_after_15m::Union{Float64, Nothing}
    price_after_1h::Union{Float64, Nothing}
    outcome_recorded::Bool
end

function ShadowSignal(id::String, inst::String, sym::String, dir::Symbol,
                      strength::Float64, price::Float64, time::DateTime,
                      model_contribs::Dict{String,Float64}, model_dirs::Dict{String,Symbol})
    ShadowSignal(id, inst, sym, dir, strength, price, time,
                 model_contribs, model_dirs,
                 nothing, nothing, nothing, nothing, false)
end

"""Calculate the favorable move in bps at a given horizon."""
function favorable_move_bps(sig::ShadowSignal, price_after::Union{Float64, Nothing})::Union{Float64, Nothing}
    price_after === nothing && return nothing
    sig.price_at_signal == 0.0 && return nothing
    raw_move = (price_after - sig.price_at_signal) / sig.price_at_signal * 10000.0
    return sig.direction == :buy ? raw_move : -raw_move
end

move_1m_bps(sig::ShadowSignal) = favorable_move_bps(sig, sig.price_after_1m)
move_5m_bps(sig::ShadowSignal) = favorable_move_bps(sig, sig.price_after_5m)
move_15m_bps(sig::ShadowSignal) = favorable_move_bps(sig, sig.price_after_15m)
move_1h_bps(sig::ShadowSignal) = favorable_move_bps(sig, sig.price_after_1h)

was_correct_5m(sig::ShadowSignal) = let m = move_5m_bps(sig); m === nothing ? nothing : m > 0.0; end

# ── Shadow Session ────────────────────────────────────────────

mutable struct ShadowSession
    session_id::String
    team_id::String
    venue::String
    instruments::Vector{String}
    signals::Vector{ShadowSignal}
    pending_outcomes::Vector{ShadowSignal}
    prices::Dict{String, Float64}
    price_history::Dict{String, Vector{Tuple{Float64, Float64}}}  # symbol → [(timestamp, price)]
    started_at::DateTime
end

function ShadowSession(; team_id="crypto", venue="binance",
                        instruments=["BTCUSDT", "ETHUSDT"])
    ShadowSession(
        string(uuid4())[1:8], team_id, venue, instruments,
        ShadowSignal[], ShadowSignal[],
        Dict{String,Float64}(),
        Dict{String,Vector{Tuple{Float64,Float64}}}(),
        Dates.now(Dates.UTC),
    )
end

"""Record a price tick from the venue."""
function record_price!(session::ShadowSession, symbol::String, price::Float64)
    session.prices[symbol] = price
    hist = get!(session.price_history, symbol, Tuple{Float64,Float64}[])
    push!(hist, (time(), price))
    # Keep 2 hours
    cutoff = time() - 7200.0
    filter!(t -> t[1] >= cutoff, hist)
end

"""Get the closest price to a target timestamp."""
function get_price_at(session::ShadowSession, symbol::String, target_ts::Float64)::Union{Float64, Nothing}
    hist = get(session.price_history, symbol, Tuple{Float64,Float64}[])
    isempty(hist) && return nothing

    best_price = nothing
    best_delta = Inf
    for (ts, price) in hist
        delta = abs(ts - target_ts)
        if delta < best_delta
            best_delta = delta
            best_price = price
        end
    end
    return best_delta < 30.0 ? best_price : nothing  # within 30s tolerance
end

"""Update outcomes for pending signals."""
function update_outcomes!(session::ShadowSession)::Int
    updated = 0
    now_ts = time()
    still_pending = ShadowSignal[]

    for sig in session.pending_outcomes
        sig_ts = Dates.datetime2unix(sig.signal_time)

        if sig.price_after_1m === nothing && now_ts - sig_ts >= 60
            sig.price_after_1m = get_price_at(session, sig.venue_symbol, sig_ts + 60)
        end
        if sig.price_after_5m === nothing && now_ts - sig_ts >= 300
            sig.price_after_5m = get_price_at(session, sig.venue_symbol, sig_ts + 300)
        end
        if sig.price_after_15m === nothing && now_ts - sig_ts >= 900
            sig.price_after_15m = get_price_at(session, sig.venue_symbol, sig_ts + 900)
        end
        if sig.price_after_1h === nothing && now_ts - sig_ts >= 3600
            sig.price_after_1h = get_price_at(session, sig.venue_symbol, sig_ts + 3600)
        end

        if sig.price_after_1h !== nothing
            sig.outcome_recorded = true
            updated += 1
        elseif now_ts - sig_ts < 7200  # not yet 2 hours old
            push!(still_pending, sig)
        else
            sig.outcome_recorded = true  # too old, mark with whatever we have
            updated += 1
        end
    end

    session.pending_outcomes = still_pending
    return updated
end

# ── Statistics ────────────────────────────────────────────────

"""Get aggregate statistics for the shadow session."""
function shadow_stats(session::ShadowSession)::Dict{String, Any}
    completed = filter(s -> s.outcome_recorded, session.signals)
    n = length(completed)

    if n == 0
        return Dict{String,Any}(
            "session_id" => session.session_id,
            "total_signals" => length(session.signals),
            "completed" => 0,
            "pending" => length(session.pending_outcomes),
        )
    end

    moves_5m = filter(!isnothing, [move_5m_bps(s) for s in completed])
    moves_1h = filter(!isnothing, [move_1h_bps(s) for s in completed])
    correct_5m = count(s -> was_correct_5m(s) === true, completed)
    evaluated_5m = count(s -> was_correct_5m(s) !== nothing, completed)

    return Dict{String,Any}(
        "session_id" => session.session_id,
        "total_signals" => length(session.signals),
        "completed" => n,
        "pending" => length(session.pending_outcomes),
        "hit_rate_5m" => evaluated_5m > 0 ? correct_5m / evaluated_5m : 0.0,
        "move_5m_bps" => isempty(moves_5m) ? Dict() : Dict(
            "mean" => mean(moves_5m),
            "median" => median(moves_5m),
            "min" => minimum(moves_5m),
            "max" => maximum(moves_5m),
        ),
        "move_1h_bps" => isempty(moves_1h) ? Dict() : Dict(
            "mean" => mean(moves_1h),
            "median" => median(moves_1h),
            "min" => minimum(moves_1h),
            "max" => maximum(moves_1h),
        ),
        "buys" => count(s -> s.direction == :buy, completed),
        "sells" => count(s -> s.direction == :sell, completed),
    )
end

"""Get per-model contribution statistics — identifies dead-weight models."""
function model_contribution_stats(session::ShadowSession)::Dict{String, Dict{String, Any}}
    completed = filter(s -> s.outcome_recorded && was_correct_5m(s) !== nothing, session.signals)
    isempty(completed) && return Dict{String, Dict{String, Any}}()

    # Collect per-model stats
    model_stats = Dict{String, Dict{String, Any}}()

    for sig in completed
        correct = was_correct_5m(sig) === true
        for (model_id, contribution) in sig.model_contributions
            ms = get!(model_stats, model_id, Dict{String, Any}(
                "total" => 0,
                "correct_when_contributed" => 0,
                "wrong_when_contributed" => 0,
                "avg_contribution" => 0.0,
                "contributions" => Float64[],
            ))
            ms["total"] += 1
            push!(ms["contributions"], contribution)
            if correct
                ms["correct_when_contributed"] += 1
            else
                ms["wrong_when_contributed"] += 1
            end
        end
    end

    # Compute averages and identify dead weight
    for (model_id, ms) in model_stats
        contribs = ms["contributions"]
        ms["avg_contribution"] = isempty(contribs) ? 0.0 : mean(contribs)
        ms["hit_rate"] = ms["total"] > 0 ? ms["correct_when_contributed"] / ms["total"] : 0.0
        ms["is_dead_weight"] = ms["avg_contribution"] < 0.01 || ms["hit_rate"] < 0.45
        delete!(ms, "contributions")  # don't clutter output
    end

    return model_stats
end

"""Print a human-readable shadow session report."""
function print_shadow_report(session::ShadowSession)
    stats = shadow_stats(session)
    model_stats = model_contribution_stats(session)

    println("\n", "="^65)
    println("SHADOW SESSION REPORT — $(session.session_id)")
    println("="^65)
    println("Instruments: $(join(session.instruments, ", "))")
    println("Total signals:  $(stats["total_signals"])")
    println("With outcomes:  $(stats["completed"])")
    println("Pending:        $(stats["pending"])")

    if stats["completed"] > 0
        println("\nHit rate (5m):  $(round(stats["hit_rate_5m"] * 100, digits=1))%")
        if haskey(stats, "move_5m_bps") && !isempty(stats["move_5m_bps"])
            m5 = stats["move_5m_bps"]
            println("5min move (bps): mean=$(round(m5["mean"], digits=1))  " *
                    "median=$(round(m5["median"], digits=1))  " *
                    "range=[$(round(m5["min"], digits=1)), $(round(m5["max"], digits=1))]")
        end
        println("Buy signals:    $(stats["buys"])")
        println("Sell signals:   $(stats["sells"])")

        if !isempty(model_stats)
            println("\n--- PER-MODEL CONTRIBUTION ---")
            # Sort by hit rate descending
            sorted = sort(collect(model_stats), by=kv -> -kv[2]["hit_rate"])
            for (model_id, ms) in sorted
                flag = ms["is_dead_weight"] ? " ← DEAD WEIGHT" : ""
                println("  $(rpad(model_id, 20)) hit=$(round(ms["hit_rate"]*100, digits=0))%  " *
                        "contrib=$(round(ms["avg_contribution"], digits=3))  " *
                        "n=$(ms["total"])$flag")
            end
            dead = count(kv -> kv[2]["is_dead_weight"], model_stats)
            println("\n  Dead weight models: $dead / $(length(model_stats))")
        end
    else
        println("\nNo completed signals — need more observation time")
    end

    println("="^65)
end
