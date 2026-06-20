# ── Hyperparameter Search Spaces ──────────────────────────────
# Defines tunable parameters for each model with ranges and types.

"""A single hyperparameter with its search range."""
struct HyperParam
    name::String
    low::Float64
    high::Float64
    param_type::Symbol    # :int, :float, :log_float
end

"""Search space for a model — a collection of hyperparameters."""
struct SearchSpace
    model_name::String
    model_id::Int
    params::Vector{HyperParam}
end

"""Sample a random point from the search space."""
function sample_point(space::SearchSpace)::Dict{String, Float64}
    point = Dict{String, Float64}()
    for hp in space.params
        if hp.param_type == :log_float
            # Log-uniform sampling
            log_val = hp.low + rand() * (hp.high - hp.low)
            point[hp.name] = exp(log_val)
        elseif hp.param_type == :int
            point[hp.name] = round(hp.low + rand() * (hp.high - hp.low))
        else  # :float
            point[hp.name] = hp.low + rand() * (hp.high - hp.low)
        end
    end
    return point
end

"""Convert a point to a normalized [0,1]^d vector for the surrogate."""
function normalize_point(space::SearchSpace, point::Dict{String, Float64})::Vector{Float64}
    return [clamp((point[hp.name] - hp.low) / max(hp.high - hp.low, 1e-10), 0.0, 1.0)
            for hp in space.params]
end

"""Convert a normalized [0,1]^d vector back to parameter values."""
function denormalize_point(space::SearchSpace, x::Vector{Float64})::Dict{String, Float64}
    point = Dict{String, Float64}()
    for (i, hp) in enumerate(space.params)
        raw = hp.low + x[i] * (hp.high - hp.low)
        if hp.param_type == :log_float
            point[hp.name] = exp(raw)
        elseif hp.param_type == :int
            point[hp.name] = round(raw)
        else
            point[hp.name] = raw
        end
    end
    return point
end

# ── Predefined Search Spaces ─────────────────────────────────

function get_search_space(model_id::Int)::SearchSpace
    spaces = Dict(
        5 => SearchSpace("Random Forest", 5, [
            HyperParam("n_trees", 30.0, 300.0, :int),
            HyperParam("max_depth", 2.0, 8.0, :int),
        ]),
        6 => SearchSpace("LightGBM", 6, [
            HyperParam("n_trees", 20.0, 200.0, :int),
            HyperParam("lr", log(0.01), log(0.3), :log_float),
            HyperParam("max_depth", 2.0, 6.0, :int),
        ]),
        7 => SearchSpace("XGBoost", 7, [
            HyperParam("n_trees", 20.0, 200.0, :int),
            HyperParam("lr", log(0.01), log(0.3), :log_float),
            HyperParam("max_depth", 2.0, 6.0, :int),
            HyperParam("lambda", 0.1, 5.0, :float),
        ]),
        14 => SearchSpace("GARCH", 14, [
            HyperParam("n_iterations", 200.0, 1000.0, :int),
        ]),
        1 => SearchSpace("LSTM", 1, [
            HyperParam("hidden_size", 8.0, 64.0, :int),
            HyperParam("lr", log(1e-4), log(1e-2), :log_float),
        ]),
        2 => SearchSpace("GRU", 2, [
            HyperParam("hidden_size", 8.0, 48.0, :int),
            HyperParam("lr", log(1e-4), log(1e-2), :log_float),
        ]),
        13 => SearchSpace("MLP", 13, [
            HyperParam("hidden_size", 8.0, 64.0, :int),
            HyperParam("lr", log(1e-4), log(1e-2), :log_float),
        ]),
    )
    if !haskey(spaces, model_id)
        error("No search space defined for model $model_id")
    end
    return spaces[model_id]
end

"""List all model IDs that have tunable search spaces."""
function tunable_models()::Vector{Int}
    return [1, 2, 5, 6, 7, 13, 14]
end
