# ── External Signal Ingestion ─────────────────────────────────
# Fetches external data sources that strengthen prediction market analysis:
# - FRED economic indicators (GDP, unemployment, Fed funds rate)
# - Polling data (election/event polls)
# - Generic RSS/API signal ingestion

"""External signal data point."""
struct ExternalSignal
    source::String             # "fred", "polls", "custom"
    name::String               # e.g., "UNRATE", "generic_poll"
    value::Float64
    timestamp::DateTime
    metadata::Dict{String,Any}
end

"""Buffer of external signals for model consumption."""
mutable struct SignalBuffer
    signals::Dict{String, Vector{ExternalSignal}}  # source_name → history
    max_per_source::Int
    lock::ReentrantLock
end

SignalBuffer(; max_per_source::Int=1000) =
    SignalBuffer(Dict{String,Vector{ExternalSignal}}(), max_per_source, ReentrantLock())

"""Add a signal to the buffer (thread-safe)."""
function add_signal!(buf::SignalBuffer, signal::ExternalSignal)
    lock(buf.lock) do
        key = "$(signal.source):$(signal.name)"
        if !haskey(buf.signals, key)
            buf.signals[key] = ExternalSignal[]
        end
        push!(buf.signals[key], signal)
        while length(buf.signals[key]) > buf.max_per_source
            popfirst!(buf.signals[key])
        end
    end
end

"""Get the latest signal value for a given source:name (thread-safe)."""
function get_latest_signal(buf::SignalBuffer, source::String, name::String)::Union{ExternalSignal, Nothing}
    lock(buf.lock) do
        key = "$source:$name"
        signals = get(buf.signals, key, ExternalSignal[])
        return isempty(signals) ? nothing : signals[end]
    end
end

"""Get all recent signals within a time window."""
function get_signals_since(buf::SignalBuffer, source::String, name::String;
                            since::DateTime=now() - Day(1))::Vector{ExternalSignal}
    lock(buf.lock) do
        key = "$source:$name"
        signals = get(buf.signals, key, ExternalSignal[])
        return filter(s -> s.timestamp >= since, signals)
    end
end

# ── FRED Economic Data ────────────────────────────────────────

"""
    fetch_fred_series(series_id; api_key_env, n_observations)

Fetch economic data from FRED (Federal Reserve Economic Data).
Common series: UNRATE (unemployment), FEDFUNDS (fed funds rate),
GDP, CPIAUCSL (CPI), T10Y2Y (yield curve).
"""
function fetch_fred_series(series_id::String;
                            api_key_env::String="QE_FRED_API_KEY",
                            n_observations::Int=30)::Vector{ExternalSignal}
    api_key = get(ENV, api_key_env, "")
    if isempty(api_key)
        # Return empty — FRED requires free API key from fred.stlouisfed.org
        return ExternalSignal[]
    end

    try
        url = "https://api.stlouisfed.org/fred/series/observations" *
              "?series_id=$(series_id)&api_key=$(api_key)&file_type=json" *
              "&sort_order=desc&limit=$(n_observations)"

        resp = HTTP.get(url; connect_timeout=10, readtimeout=15)
        data = JSON.parse(String(resp.body))
        observations = get(data, "observations", [])

        signals = ExternalSignal[]
        for obs in observations
            val_str = get(obs, "value", ".")
            if val_str != "."
                val = parse(Float64, val_str)
                date_str = get(obs, "date", "")
                ts = !isempty(date_str) ? DateTime(date_str, "yyyy-mm-dd") : now()
                push!(signals, ExternalSignal("fred", series_id, val, ts,
                    Dict{String,Any}("realtime_start" => get(obs, "realtime_start", ""))))
            end
        end
        return reverse(signals)  # chronological order
    catch e
        @warn "FRED fetch failed for $series_id: $(sprint(showerror, e)[1:min(60,end)])"
        return ExternalSignal[]
    end
end

# ── Polling Data ──────────────────────────────────────────────

"""
    create_poll_signal(name, value, source_url)

Create a polling data signal manually.
Polls are typically entered manually or from custom scraping.
"""
function create_poll_signal(name::String, value::Float64;
                             source_url::String="")
    return ExternalSignal("polls", name, value, now(),
        Dict{String,Any}("source_url" => source_url))
end

# ── Signal Aggregation for Bayesian Updates ───────────────────

"""
    signals_to_bayesian_evidence(buf, asset)

Convert recent external signals into evidence for Bayesian updating.
Returns a NamedTuple compatible with run_bayesian's tweet_sentiment parameter.
"""
function signals_to_bayesian_evidence(buf::SignalBuffer, asset::String)
    # Aggregate all signals for this asset from the last 24 hours
    all_signals = ExternalSignal[]
    lock(buf.lock) do
        for (key, signals) in buf.signals
            cutoff = now() - Day(1)
            recent = filter(s -> s.timestamp >= cutoff, signals)
            append!(all_signals, recent)
        end
    end

    if isempty(all_signals)
        return nothing
    end

    # Simple sentiment: positive values = bullish, negative = bearish
    avg_value = mean(s.value for s in all_signals)
    n = length(all_signals)

    # Normalize to sentiment scale
    signal = if avg_value > 0
        :bullish
    elseif avg_value < 0
        :bearish
    else
        :neutral
    end

    return (sentiment=avg_value, n_tweets=n,  # reuse tweet_sentiment interface
            bullish_pct=count(s -> s.value > 0, all_signals) / n * 100,
            bearish_pct=count(s -> s.value < 0, all_signals) / n * 100,
            avg_score=avg_value, signal=signal)
end
