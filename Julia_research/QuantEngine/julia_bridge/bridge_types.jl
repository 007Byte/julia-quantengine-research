# Bridge types for Python <-> Julia ZMQ communication
# All messages are JSON-encoded with these schemas.

module BridgeTypes

using JSON

# --- Request types ---

struct FeatureRequest
    instrument_id::String
    prices::Vector{Float64}
    volumes::Vector{Float64}
    highs::Vector{Float64}
    lows::Vector{Float64}
    timeframe::String
    extra::Dict{String,Any}
end

struct ModelScoreRequest
    instrument_id::String
    features::Matrix{Float64}     # N x 18 feature matrix
    model_ids::Vector{String}     # which models to run
    regime::String                 # "trending", "mean_reverting", "volatile", "calm"
    config::Dict{String,Any}
end

struct EnsembleRequest
    instrument_id::String
    features::Matrix{Float64}
    strategy_id::String
    config::Dict{String,Any}
end

struct HeartbeatRequest end

# --- Response types ---

struct FeatureResponse
    instrument_id::String
    features::Vector{Float64}     # 18-element feature vector
    feature_names::Vector{String}
    computed_at::String            # ISO 8601
end

struct ModelScore
    model_id::String
    direction::String   # "buy", "sell", "hold"
    confidence::Float64
    p_value::Float64
    metadata::Dict{String,Any}
end

struct ModelScoreResponse
    instrument_id::String
    scores::Vector{ModelScore}
    regime::String
    computed_at::String
end

struct EnsembleResponse
    instrument_id::String
    signal_direction::String   # "buy", "sell", "hold"
    signal_strength::Float64   # 0.0 to 1.0
    model_votes::Dict{String,String}
    ensemble_confidence::Float64
    computed_at::String
end

struct HeartbeatResponse
    status::String
    uptime_seconds::Float64
    models_loaded::Int
end

struct ErrorResponse
    error::String
    code::String
    details::String
end

# --- Serialization ---

function to_json(obj)::String
    return JSON.json(obj)
end

function parse_request(msg::String)
    data = JSON.parse(msg)
    request_type = get(data, "type", "unknown")
    return request_type, data
end

end # module
