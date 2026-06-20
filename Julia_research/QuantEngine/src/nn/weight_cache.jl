# ── Pre-trained Weight Cache ──────────────────────────────────
# Caches trained NN weights to disk via JLD2. On subsequent runs,
# skips expensive LBFGS training and uses cached weights directly.
# Reduces NN model time from minutes to milliseconds (cache hit).

"""Cached weights for a single trained model."""
struct CachedWeights
    model_id::Int
    ticker::String
    θ::Vector{Float64}             # flattened parameter vector
    shapes::Vector{Tuple{Int,Int}} # architecture specification
    n_features::Int
    trained_date::DateTime
    accuracy::Float64
    loss_val::Float64
    data_hash::UInt64              # hash of training data for staleness
end

"""Thread-safe weight cache with JLD2 persistence."""
mutable struct WeightCache
    entries::Dict{Tuple{Int,String,Int}, CachedWeights}  # (model_id, ticker, n_features)
    cache_dir::String
    max_age_days::Int
    lock::ReentrantLock
end

function WeightCache(cache_dir::String; max_age_days::Int=7)
    mkpath(cache_dir)
    WeightCache(Dict{Tuple{Int,String,Int}, CachedWeights}(), cache_dir, max_age_days, ReentrantLock())
end

"""Compute a hash of training data for cache invalidation."""
function compute_data_hash(train_data)::UInt64
    if train_data isa Vector
        h = UInt64(length(train_data))
        for (i, x) in enumerate(train_data)
            if i > 10; break; end  # sample first 10 elements for speed
            if x isa AbstractArray
                h = hash(size(x), h)
                h = hash(sum(abs, x), h)
            else
                h = hash(x, h)
            end
        end
        return h
    elseif train_data isa AbstractMatrix
        return hash((size(train_data), sum(abs, train_data[1:min(10,end), :])))
    else
        return hash(train_data)
    end
end

"""Check if a cache entry is still fresh."""
function is_cache_fresh(entry::CachedWeights; max_age_days::Int=7)::Bool
    return (now() - entry.trained_date) < Dates.Day(max_age_days)
end

"""Get cached weights if available and fresh (thread-safe)."""
function get_cached_weights(cache::WeightCache, model_id::Int,
                             ticker::String, n_features::Int)::Union{CachedWeights, Nothing}
    lock(cache.lock) do
        entry = get(cache.entries, (model_id, ticker, n_features), nothing)
        if entry !== nothing && is_cache_fresh(entry; max_age_days=cache.max_age_days)
            return entry
        end
        return nothing
    end
end

"""Store weights in cache (thread-safe)."""
function store_weights!(cache::WeightCache, model_id::Int, ticker::String,
                        n_features::Int, θ::Vector{Float64},
                        shapes::Vector{Tuple{Int,Int}},
                        accuracy::Float64, loss_val::Float64,
                        data_hash::UInt64)
    entry = CachedWeights(model_id, ticker, copy(θ), copy(shapes),
                          n_features, now(), accuracy, loss_val, data_hash)
    lock(cache.lock) do
        cache.entries[(model_id, ticker, n_features)] = entry
    end
end

"""
    get_cached_or_train(cache, model_id, ticker, n_features, train_data, train_fn)

Core integration point. If fresh cached weights exist for this model+ticker,
returns the unpacked weight matrices immediately (skipping training).
Otherwise calls train_fn() which must return (θ_star, shapes, accuracy, loss_val),
caches the result, and returns unpacked weights.
"""
function get_cached_or_train(cache::WeightCache, model_id::Int, ticker::String,
                              n_features::Int, train_data,
                              train_fn::Function)
    d_hash = compute_data_hash(train_data)

    # Check cache
    entry = get_cached_weights(cache, model_id, ticker, n_features)
    if entry !== nothing && entry.data_hash == d_hash
        return unpack_weights(entry.θ, entry.shapes)
    end

    # Cache miss — train
    θ_star, shapes, accuracy, loss_val = train_fn()

    # Store in cache
    store_weights!(cache, model_id, ticker, n_features, θ_star, shapes, accuracy, loss_val, d_hash)

    return unpack_weights(θ_star, shapes)
end

"""Save the entire cache to disk via JLD2."""
function save_cache!(cache::WeightCache)
    filepath = joinpath(cache.cache_dir, "weight_cache.jld2")
    lock(cache.lock) do
        data = Dict{String,Any}()
        for ((mid, tick, nf), entry) in cache.entries
            key = "$(mid)_$(tick)_$(nf)"
            data[key] = Dict(
                "model_id" => entry.model_id,
                "ticker" => entry.ticker,
                "theta" => entry.θ,
                "shapes" => entry.shapes,
                "n_features" => entry.n_features,
                "trained_date" => string(entry.trained_date),
                "accuracy" => entry.accuracy,
                "loss_val" => entry.loss_val,
                "data_hash" => entry.data_hash
            )
        end
        JLD2.@save filepath data
    end
    try; chmod(filepath, 0o600); catch; end
end

"""Load the cache from disk via JLD2."""
function load_cache!(cache::WeightCache)
    filepath = joinpath(cache.cache_dir, "weight_cache.jld2")
    if !isfile(filepath)
        return
    end
    lock(cache.lock) do
        try
            JLD2.@load filepath data
            for (key, d) in data
                entry = CachedWeights(
                    d["model_id"], d["ticker"],
                    d["theta"], d["shapes"], d["n_features"],
                    DateTime(d["trained_date"]),
                    d["accuracy"], d["loss_val"], d["data_hash"]
                )
                cache.entries[(entry.model_id, entry.ticker, entry.n_features)] = entry
            end
        catch e
            @warn "Failed to load weight cache: $(sprint(showerror, e)[1:min(60,end)])"
        end
    end
end

"""Clear stale entries from cache."""
function clear_stale!(cache::WeightCache)
    lock(cache.lock) do
        for (key, entry) in collect(cache.entries)
            if !is_cache_fresh(entry; max_age_days=cache.max_age_days)
                delete!(cache.entries, key)
            end
        end
    end
end

"""
    get_cached_for_incremental(cache, model_id, ticker, n_features)

Get cached weights as a warm-start initial point for incremental retraining.
Instead of random initialization, start from previously trained weights.
Returns θ vector or nothing (caller falls back to random init).
"""
function get_cached_for_incremental(cache::WeightCache, model_id::Int,
                                     ticker::String, n_features::Int)::Union{Vector{Float64}, Nothing}
    lock(cache.lock) do
        entry = get(cache.entries, (model_id, ticker, n_features), nothing)
        if entry !== nothing
            return copy(entry.θ)  # return θ as warm-start
        end
        return nothing
    end
end
