# ── Cross-Asset Correlation & Portfolio Heat ──────────────────
# Computes rolling correlations between assets for:
# 1. Portfolio-level risk (correlated positions = concentrated risk)
# 2. Kelly scaling (reduce size when correlated with existing positions)
# 3. Feature engineering (cross-asset momentum signals)

"""Rolling correlation matrix for a set of assets."""
mutable struct CorrelationTracker
    returns::Dict{String, Vector{Float64}}  # asset → return history
    window::Int                              # lookback window
    lock::ReentrantLock
end

CorrelationTracker(; window::Int=60) =
    CorrelationTracker(Dict{String,Vector{Float64}}(), window, ReentrantLock())

"""Add a return observation for an asset (thread-safe)."""
function add_return!(tracker::CorrelationTracker, asset::String, ret::Float64)
    lock(tracker.lock) do
        if !haskey(tracker.returns, asset)
            tracker.returns[asset] = Float64[]
        end
        push!(tracker.returns[asset], ret)
        while length(tracker.returns[asset]) > tracker.window
            popfirst!(tracker.returns[asset])
        end
    end
end

"""Compute pairwise correlation between two assets."""
function asset_correlation(tracker::CorrelationTracker, a::String, b::String)::Float64
    lock(tracker.lock) do
        ra = get(tracker.returns, a, Float64[])
        rb = get(tracker.returns, b, Float64[])
        n = min(length(ra), length(rb))
        if n < 10
            return 0.0  # insufficient data
        end
        return cor(ra[end-n+1:end], rb[end-n+1:end])
    end
end

"""Compute full correlation matrix for all tracked assets."""
function correlation_matrix(tracker::CorrelationTracker)
    lock(tracker.lock) do
        assets = collect(keys(tracker.returns))
        n = length(assets)
        if n < 2
            return (assets=assets, matrix=ones(max(n,1), max(n,1)))
        end

        C = ones(n, n)
        for i in 1:n, j in (i+1):n
            ra = tracker.returns[assets[i]]
            rb = tracker.returns[assets[j]]
            k = min(length(ra), length(rb))
            if k >= 10
                c = cor(ra[end-k+1:end], rb[end-k+1:end])
                C[i, j] = c
                C[j, i] = c
            end
        end
        return (assets=assets, matrix=C)
    end
end

"""
    correlation_adjusted_kelly(base_kelly, new_asset, existing_positions, tracker)

Reduce Kelly fraction when the new trade is highly correlated
with existing positions (concentrated risk).
"""
function correlation_adjusted_kelly(base_kelly::Float64, new_asset::String,
                                     existing_assets::Vector{String},
                                     tracker::CorrelationTracker)::Float64
    if isempty(existing_assets)
        return base_kelly
    end

    # Average absolute correlation with existing positions
    correlations = Float64[]
    for asset in existing_assets
        c = abs(asset_correlation(tracker, new_asset, asset))
        if c > 0.0
            push!(correlations, c)
        end
    end

    if isempty(correlations)
        return base_kelly
    end

    avg_corr = mean(correlations)

    # High correlation → reduce Kelly (max 50% reduction at correlation = 1.0)
    reduction = 0.5 * avg_corr
    return base_kelly * (1.0 - reduction)
end

"""
    portfolio_correlation_risk(tracker, positions)

Compute portfolio-level correlation risk.
Returns a risk score from 0 (fully diversified) to 1 (fully concentrated).
"""
function portfolio_correlation_risk(tracker::CorrelationTracker,
                                     positions::Vector{String})::Float64
    if length(positions) <= 1
        return 0.0
    end

    total_corr = 0.0
    n_pairs = 0
    for i in 1:length(positions), j in (i+1):length(positions)
        c = abs(asset_correlation(tracker, positions[i], positions[j]))
        total_corr += c
        n_pairs += 1
    end

    return n_pairs > 0 ? total_corr / n_pairs : 0.0
end
