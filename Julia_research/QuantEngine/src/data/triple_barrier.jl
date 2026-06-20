# ── Triple-Barrier Labeling (Lopez de Prado Ch. 3-4) ──────────
# Labels based on which barrier is hit first:
#   Upper (+pt_mult * σ)  → +1 (profitable long)
#   Lower (-sl_mult * σ)  → -1 (stop-loss hit)
#   Vertical (time expiry) → 0 (no clear signal)

"""
    daily_volatility(returns; window=20) → Vector{Float64}

Rolling standard deviation of returns. First (window-1) entries are NaN.
"""
function daily_volatility(returns::Vector{Float64}; window::Int=20)
    n = length(returns)
    vol = fill(NaN, n)
    for i in window:n
        vol[i] = std(@view returns[max(1, i-window+1):i])
    end
    return vol
end

"""
    triple_barrier_label(returns, volatility; pt_mult=2.0, sl_mult=1.0, max_holding=10)
        → Vector{Float64}

Apply triple-barrier method. For each time t, simulate forward:
  - Upper barrier: cumret >= +pt_mult * σ_t  → label = +1
  - Lower barrier: cumret <= -sl_mult * σ_t  → label = -1
  - Vertical barrier: max_holding days expire → label = 0
"""
function triple_barrier_label(returns::Vector{Float64}, volatility::Vector{Float64};
                              pt_mult::Float64=2.0, sl_mult::Float64=1.0,
                              max_holding::Int=10)
    n = length(returns)
    labels = zeros(n)
    fallback_vol = std(returns)

    for t in 1:n
        sigma = isnan(volatility[t]) ? fallback_vol : volatility[t]
        sigma = max(sigma, 1e-8)
        upper = pt_mult * sigma
        lower = sl_mult * sigma
        cumret = 0.0
        label = 0.0

        for h in 1:min(max_holding, n - t)
            cumret += returns[t + h]
            if cumret >= upper
                label = 1.0; break
            elseif cumret <= -lower
                label = -1.0; break
            end
        end
        labels[t] = label
    end
    return labels
end

"""
    triple_barrier_binary(labels) → Vector{Float64}

Convert triple-barrier labels {-1, 0, +1} to binary {0, 1}.
Maps: +1 → 1.0, {0, -1} → 0.0.
"""
function triple_barrier_binary(labels::Vector{Float64})
    return Float64.(labels .> 0)
end
