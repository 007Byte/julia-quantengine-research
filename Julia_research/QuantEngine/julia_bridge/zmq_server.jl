#!/usr/bin/env julia
#
# ZMQ Bridge Server — exposes Julia QuantEngine over ZeroMQ.
# Protocol: Lazy Pirate compatible (REQ/REP with heartbeat).
#
# Python sends JSON requests, Julia processes and returns JSON responses.
# Supports: feature computation, model scoring, ensemble, heartbeat.

using ZMQ
using JSON
using Dates
using Logging

# Add parent QuantEngine to load path
push!(LOAD_PATH, joinpath(@__DIR__, ".."))
using QuantEngine

include("bridge_types.jl")
using .BridgeTypes

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

const DEFAULT_ENDPOINT = get(ENV, "QE_JULIA_ENDPOINT", "tcp://127.0.0.1:5555")
const SERVER_START_TIME = now(UTC)

# ---------------------------------------------------------------------------
# Request handlers
# ---------------------------------------------------------------------------

function handle_heartbeat()::String
    uptime = Dates.value(now(UTC) - SERVER_START_TIME) / 1000.0
    resp = BridgeTypes.HeartbeatResponse("ok", uptime, 34)
    return JSON.json(Dict(
        "type" => "heartbeat_response",
        "status" => resp.status,
        "uptime_seconds" => resp.uptime_seconds,
        "models_loaded" => resp.models_loaded,
    ))
end

function handle_features(data::Dict)::String
    try
        prices = Float64.(data["prices"])
        volumes = Float64.(get(data, "volumes", zeros(length(prices))))
        highs = Float64.(get(data, "highs", prices))
        lows = Float64.(get(data, "lows", prices))

        # Use QuantEngine feature computation
        ctx = QuantEngine.AnalysisContext(
            ticker=get(data, "instrument_id", "UNKNOWN"),
            prices=prices,
            volumes=volumes,
            highs=highs,
            lows=lows,
        )
        features = QuantEngine.compute_features(ctx)

        return JSON.json(Dict(
            "type" => "feature_response",
            "instrument_id" => get(data, "instrument_id", ""),
            "features" => features,
            "feature_count" => length(features),
            "computed_at" => string(now(UTC)),
        ))
    catch e
        return JSON.json(Dict(
            "type" => "error",
            "error" => string(e),
            "code" => "FEATURE_COMPUTE_ERROR",
        ))
    end
end

function handle_model_score(data::Dict)::String
    try
        features = hcat(data["features"]...)  # reconstruct matrix
        model_ids = get(data, "model_ids", String[])
        regime = get(data, "regime", "unknown")

        # Use QuantEngine model runner
        scores = []
        for mid in model_ids
            try
                result = QuantEngine.run_registered_model(mid, features)
                push!(scores, Dict(
                    "model_id" => mid,
                    "direction" => get(result, :direction, "hold"),
                    "confidence" => get(result, :confidence, 0.0),
                    "p_value" => get(result, :p_value, 0.5),
                ))
            catch model_err
                push!(scores, Dict(
                    "model_id" => mid,
                    "direction" => "hold",
                    "confidence" => 0.0,
                    "error" => string(model_err),
                ))
            end
        end

        return JSON.json(Dict(
            "type" => "model_score_response",
            "instrument_id" => get(data, "instrument_id", ""),
            "scores" => scores,
            "regime" => regime,
            "computed_at" => string(now(UTC)),
        ))
    catch e
        return JSON.json(Dict(
            "type" => "error",
            "error" => string(e),
            "code" => "MODEL_SCORE_ERROR",
        ))
    end
end

function handle_ensemble(data::Dict)::String
    try
        features = hcat(data["features"]...)
        strategy_id = get(data, "strategy_id", "default")

        # Use QuantEngine orchestrator for full ensemble
        result = QuantEngine.run_ensemble(features, strategy_id)

        return JSON.json(Dict(
            "type" => "ensemble_response",
            "instrument_id" => get(data, "instrument_id", ""),
            "signal_direction" => get(result, :direction, "hold"),
            "signal_strength" => get(result, :strength, 0.0),
            "ensemble_confidence" => get(result, :confidence, 0.0),
            "computed_at" => string(now(UTC)),
        ))
    catch e
        return JSON.json(Dict(
            "type" => "error",
            "error" => string(e),
            "code" => "ENSEMBLE_ERROR",
        ))
    end
end

function dispatch_request(msg::String)::String
    try
        data = JSON.parse(msg)
        request_type = get(data, "type", "unknown")

        if request_type == "heartbeat"
            return handle_heartbeat()
        elseif request_type == "features"
            return handle_features(data)
        elseif request_type == "model_score"
            return handle_model_score(data)
        elseif request_type == "ensemble"
            return handle_ensemble(data)
        else
            return JSON.json(Dict(
                "type" => "error",
                "error" => "Unknown request type: $request_type",
                "code" => "UNKNOWN_REQUEST",
            ))
        end
    catch e
        return JSON.json(Dict(
            "type" => "error",
            "error" => string(e),
            "code" => "DISPATCH_ERROR",
        ))
    end
end

# ---------------------------------------------------------------------------
# Server main loop
# ---------------------------------------------------------------------------

function run_server(endpoint::String = DEFAULT_ENDPOINT)
    ctx = ZMQ.Context()
    socket = ZMQ.Socket(ctx, REP)
    ZMQ.bind(socket, endpoint)

    @info "Julia ZMQ bridge listening on $endpoint"
    @info "Models loaded: 34 | Start time: $SERVER_START_TIME"

    try
        while true
            msg = String(ZMQ.recv(socket))
            response = dispatch_request(msg)
            ZMQ.send(socket, response)
        end
    catch e
        if e isa InterruptException
            @info "Server shutting down"
        else
            @error "Server error" exception=e
            rethrow()
        end
    finally
        ZMQ.close(socket)
        ZMQ.close(ctx)
    end
end

# Entry point
if abspath(PROGRAM_FILE) == @__FILE__
    endpoint = length(ARGS) > 0 ? ARGS[1] : DEFAULT_ENDPOINT
    run_server(endpoint)
end
