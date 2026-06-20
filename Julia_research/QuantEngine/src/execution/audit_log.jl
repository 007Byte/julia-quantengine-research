# ── Audit Logger — Append-Only JSON Lines ────────────────────
# Defense-in-Depth Layer 5: Every decision recorded.

mutable struct AuditLogger
    filepath::String
    dir::String
    max_file_bytes::Int
    write_count::Int          # check rotation every N writes (avoid stat() every call)
    lock::ReentrantLock
end

function AuditLogger(dir::String; max_file_bytes::Int=50_000_000)
    mkpath(dir)
    # Restrict audit directory permissions: owner-only
    try; chmod(dir, 0o700); catch; end
    filepath = joinpath(dir, "pipeline_audit_$(Dates.format(Dates.today(), "yyyy-mm-dd")).jsonl")
    # Set file permissions on creation
    if !isfile(filepath)
        open(filepath, "w") do io; end
        try; chmod(filepath, 0o600); catch; end
    end
    AuditLogger(filepath, dir, max_file_bytes, 0, ReentrantLock())
end

"""Rotate the audit log if it exceeds max_file_bytes."""
function _maybe_rotate!(logger::AuditLogger)
    logger.write_count += 1
    # Only check file size every 100 writes to avoid excessive stat() calls
    logger.write_count % 100 != 0 && return

    # Check for date change (new day → new file)
    today_str = Dates.format(Dates.today(), "yyyy-mm-dd")
    if !occursin(today_str, logger.filepath)
        logger.filepath = joinpath(logger.dir, "pipeline_audit_$(today_str).jsonl")
        logger.write_count = 0
        if !isfile(logger.filepath)
            open(logger.filepath, "w") do io; end
            try; chmod(logger.filepath, 0o600); catch; end
        end
        return
    end

    # Check file size
    if isfile(logger.filepath) && filesize(logger.filepath) >= logger.max_file_bytes
        # Rotate: find next available suffix
        n = 1
        while isfile("$(logger.filepath).$(n)")
            n += 1
        end
        mv(logger.filepath, "$(logger.filepath).$(n)")
        # Start fresh
        open(logger.filepath, "w") do io; end
        try; chmod(logger.filepath, 0o600); catch; end
    end
end

"""Log an audit entry (thread-safe, append-only)."""
function audit_log!(logger::AuditLogger, asset::String, action::Symbol,
                    step::Int, details; event_id::UInt64=UInt64(0))
    entry = Dict{String,Any}(
        "timestamp" => Dates.format(now(), "yyyy-mm-ddTHH:MM:SS.sss"),
        "event_id"  => string(event_id),
        "asset"     => asset,
        "action"    => string(action),
        "step"      => step,
    )

    # Safely serialize details
    if details isa Dict
        entry["details"] = details
    elseif details isa String
        entry["details"] = Dict("message" => details)
    elseif details isa NamedTuple
        entry["details"] = Dict(string(k) => _safe_value(v) for (k, v) in pairs(details))
    else
        entry["details"] = Dict("raw" => string(details))
    end

    lock(logger.lock) do
        _maybe_rotate!(logger)
        open(logger.filepath, "a") do io
            println(io, JSON.json(entry))
        end
    end
end

"""Log a trade decision with full context."""
function audit_trade!(logger::AuditLogger, plan::TradePlan)
    details = Dict{String,Any}(
        "strategy"     => plan.strategy.model_name,
        "direction"    => string(plan.strategy.direction),
        "instrument"   => string(plan.strategy.instrument_name),
        "buy_type"     => string(plan.strategy.buy_type),
        "size_dollars"  => plan.strategy.size_dollars,
        "size_fraction" => plan.strategy.size_fraction,
        "hold_hours"    => plan.strategy.hold_time_hours,
        "take_profit"   => plan.strategy.take_profit_pct,
        "stop_loss"     => plan.strategy.stop_loss_pct,
        "confidence"    => plan.strategy.confidence,
        "expected_return" => plan.strategy.expected_return_pct,
        "risk_reward"   => plan.strategy.risk_reward_ratio,
        "rationale"     => plan.strategy.rationale,
        "blend_weight"  => plan.comparison.blend_weight,
        "recommended"   => string(plan.comparison.recommended),
        "regime"        => plan.comparison.market_regime,
    )

    audit_log!(logger, plan.asset, :trade, 12, details;
               event_id=UInt64(hash(plan.timestamp)))
end

"""Convert values to JSON-safe types."""
function _safe_value(v)
    if v isa Number && (isnan(v) || isinf(v))
        return string(v)
    elseif v isa Vector
        return length(v) > 20 ? "[$(length(v)) elements]" : v
    elseif v isa Dict
        return v
    else
        return string(v)
    end
end
