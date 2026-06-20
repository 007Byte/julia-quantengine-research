# ── Structured JSON Logging ──────────────────────────────────
# Machine-parseable JSON logs alongside existing console output.

"""Structured logger with JSON output and level filtering."""
mutable struct QELogger
    io::IO
    level::Symbol            # :debug, :info, :warn, :error
    lock::ReentrantLock
end

QELogger(; io::IO=stderr, level::Symbol=:info) = QELogger(io, level, ReentrantLock())

const _LEVEL_RANK = Dict(:debug => 0, :info => 1, :warn => 2, :error => 3)

"""Log a structured JSON message."""
function qe_log(logger::QELogger, level::Symbol, component::String,
                message::String; kwargs...)
    get(_LEVEL_RANK, level, 1) < get(_LEVEL_RANK, logger.level, 1) && return

    entry = Dict{String,Any}(
        "ts" => Dates.format(now(), "yyyy-mm-ddTHH:MM:SS.sss"),
        "level" => uppercase(string(level)),
        "component" => component,
        "msg" => message
    )
    for (k, v) in kwargs
        entry[string(k)] = v isa Number && (isnan(v) || isinf(v)) ? string(v) : v
    end

    lock(logger.lock) do
        try
            println(logger.io, JSON.json(entry))
        catch; end  # silently ignore write failures (e.g., closed stream in tests)
    end
end

# Global logger instance
const GLOBAL_LOGGER = Ref{QELogger}(QELogger())

"""Log using the global logger."""
function qe_log(level::Symbol, component::String, message::String; kwargs...)
    qe_log(GLOBAL_LOGGER[], level, component, message; kwargs...)
end

"""Set the global log level."""
function set_log_level!(level::Symbol)
    GLOBAL_LOGGER[].level = level
end
