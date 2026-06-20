# ── Shared Types ──────────────────────────────────────────────

mutable struct RalphLog
    model_name::String
    success::Bool
    time_ms::Float64
    message::String
end

"""Thread-safe analysis context — one per ticker/analysis run."""
mutable struct AnalysisContext
    # Identity
    ticker::String
    asset_type::Symbol          # :stock, :crypto, :polymarket
    display_ticker::String
    output_dir::String

    # Raw data
    dates::Vector{DateTime}
    prices::Vector{Float64}
    returns::Vector{Float64}
    volumes::Vector{Float64}
    high::Vector{Float64}
    low::Vector{Float64}
    S0::Float64

    # Prepared features
    X_train::Matrix{Float64}
    y_train::Vector{Float64}
    X_test::Matrix{Float64}
    y_test::Vector{Float64}
    Xseq_train::Vector{Matrix{Float64}}
    yseq_train::Vector{Float64}
    Xseq_test::Vector{Matrix{Float64}}
    yseq_test::Vector{Float64}
    n_features::Int
    seq_len::Int

    # Polymarket-specific (optional)
    poly_data::Union{NamedTuple, Nothing}

    # Benchmark
    r_spy::Vector{Float64}

    # Shared results (thread-safe)
    results::Dict{String, Any}
    log::Vector{RalphLog}
    lock::ReentrantLock

    # Weight cache (optional — initialized by prepare_context)
    weight_cache::Union{Any, Nothing}
end
