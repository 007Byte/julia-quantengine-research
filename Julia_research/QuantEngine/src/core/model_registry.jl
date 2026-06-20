# ── Model Registry — Plugin System ────────────────────────────
# Self-registering models: add m34+ without editing runner/constants.
# Usage:
#   register_model!(34, "My New Model", :fast, (ctx) -> run_my_model(ctx))

"""Registry of all available models (replaces hardcoded MODEL_DISPATCH)."""
mutable struct ModelRegistry
    dispatch::Dict{Int, Function}
    names::Dict{Int, String}
    phases::Dict{Int, Symbol}      # :fast, :heavy, :phase2
    lock::ReentrantLock
end

const GLOBAL_REGISTRY = Ref{Union{ModelRegistry, Nothing}}(nothing)

"""Get or create the global model registry."""
function get_registry()::ModelRegistry
    if GLOBAL_REGISTRY[] === nothing
        GLOBAL_REGISTRY[] = ModelRegistry(
            Dict{Int,Function}(), Dict{Int,String}(), Dict{Int,Symbol}(),
            ReentrantLock()
        )
    end
    return GLOBAL_REGISTRY[]
end

"""
    register_model!(id, name, phase, run_fn)

Register a model in the global registry.
- id: unique model number (34+)
- name: display name for reporting
- phase: :fast (in-process), :heavy (worker process), :phase2 (depends on phase 1)
- run_fn: function(ctx::AnalysisContext) → NamedTuple with at minimum :probability field
"""
function register_model!(id::Int, name::String, phase::Symbol, run_fn::Function)
    registry = get_registry()
    lock(registry.lock) do
        registry.dispatch[id] = run_fn
        registry.names[id] = name
        registry.phases[id] = phase
    end
end

"""Get all registered model IDs."""
function registered_model_ids(registry::ModelRegistry=get_registry())::Vector{Int}
    lock(registry.lock) do
        return sort(collect(keys(registry.dispatch)))
    end
end

"""Get registered model name by ID."""
function registered_model_name(id::Int, registry::ModelRegistry=get_registry())::String
    lock(registry.lock) do
        return get(registry.names, id, "Unknown Model $id")
    end
end

"""Get all registered fast models."""
function registered_fast_models(registry::ModelRegistry=get_registry())::Vector{Int}
    lock(registry.lock) do
        return sort([id for (id, phase) in registry.phases if phase == :fast])
    end
end

"""Get all registered heavy models."""
function registered_heavy_models(registry::ModelRegistry=get_registry())::Vector{Int}
    lock(registry.lock) do
        return sort([id for (id, phase) in registry.phases if phase == :heavy])
    end
end

"""Get all registered phase2 models."""
function registered_phase2_models(registry::ModelRegistry=get_registry())::Vector{Int}
    lock(registry.lock) do
        return sort([id for (id, phase) in registry.phases if phase == :phase2])
    end
end

"""Run a registered model by ID."""
function run_registered_model(id::Int, ctx; registry::ModelRegistry=get_registry())
    fn = lock(registry.lock) do
        get(registry.dispatch, id, nothing)
    end
    if fn === nothing
        @warn "Model $id not registered"
        return nothing
    end
    return fn(ctx)
end

"""Check if a model ID is registered."""
function is_registered(id::Int, registry::ModelRegistry=get_registry())::Bool
    lock(registry.lock) do
        return haskey(registry.dispatch, id)
    end
end
