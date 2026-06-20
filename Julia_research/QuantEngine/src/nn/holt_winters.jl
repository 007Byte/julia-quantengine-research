# ── Holt-Winters Exponential Smoothing ────────────────────────

function holt_winters(y::Vector{Float64}; α=0.3, β=0.1, horizon=21)
    n = length(y)
    level = y[1]; trend = n > 1 ? y[2] - y[1] : 0.0
    for i in 2:n
        new_level = α * y[i] + (1 - α) * (level + trend)
        trend = β * (new_level - level) + (1 - β) * trend
        level = new_level
    end
    forecasts = [level + k * trend for k in 1:horizon]
    return (level=level, trend=trend, forecasts=forecasts)
end
