# ── Cumulative Volume Delta (CVD) ─────────────────────────────
# Advanced order flow indicator measuring net aggressive buying vs selling.
# CVD rising + price flat/falling = hidden accumulation (bullish divergence).
# CVD falling + price flat/rising = hidden distribution (bearish divergence).

"""
    compute_cvd(prices, volumes; method)

Compute Cumulative Volume Delta from OHLCV data.
Since tick-level buy/sell classification isn't available from daily data,
we approximate using price action:
- If close > open (up bar): volume delta = +volume × (close-low)/(high-low)
- If close < open (down bar): volume delta = -volume × (high-close)/(high-low)
- Neutral bar: delta ≈ 0

Returns: (cvd, delta, divergence_signal, trend)
"""
function compute_cvd(prices::Vector{Float64}, volumes::Vector{Float64};
                     high::Union{Vector{Float64},Nothing}=nothing,
                     low::Union{Vector{Float64},Nothing}=nothing)
    n = length(prices)
    if n < 2
        return (cvd=zeros(1), delta=zeros(1), divergence=:none,
                cvd_slope=0.0, price_slope=0.0, cvd_current=0.0)
    end

    delta = zeros(n)
    cvd = zeros(n)

    for i in 2:n
        h = high !== nothing ? high[i] : max(prices[i], prices[i-1])
        l = low !== nothing ? low[i] : min(prices[i], prices[i-1])
        range = h - l

        if range < 1e-10
            delta[i] = 0.0
        elseif prices[i] > prices[i-1]  # up bar
            # Approximate: more of the volume was aggressive buying
            buy_ratio = (prices[i] - l) / range
            delta[i] = volumes[min(i, length(volumes))] * (2.0 * buy_ratio - 1.0)
        else  # down bar
            # More of the volume was aggressive selling
            sell_ratio = (h - prices[i]) / range
            delta[i] = -volumes[min(i, length(volumes))] * (2.0 * sell_ratio - 1.0)
        end

        cvd[i] = cvd[max(1, i-1)] + delta[i]
    end

    # ── Divergence Detection ──────────────────────────────────
    lookback = min(20, n - 1)
    if lookback >= 5
        recent_cvd = cvd[end-lookback+1:end]
        recent_price = prices[end-lookback+1:end]

        # Slopes via linear regression
        x = collect(1.0:lookback)
        cvd_slope = _linear_slope(x, recent_cvd)
        price_slope = _linear_slope(x, recent_price)

        # Divergence: CVD and price moving in opposite directions
        divergence = if cvd_slope > 0 && price_slope < 0
            :bullish_divergence   # hidden accumulation
        elseif cvd_slope < 0 && price_slope > 0
            :bearish_divergence   # hidden distribution
        elseif cvd_slope > 0 && price_slope > 0
            :bullish_confirmation # both rising
        elseif cvd_slope < 0 && price_slope < 0
            :bearish_confirmation # both falling
        else
            :none
        end
    else
        cvd_slope = 0.0
        price_slope = 0.0
        divergence = :none
    end

    return (cvd=cvd, delta=delta, divergence=divergence,
            cvd_slope=cvd_slope, price_slope=price_slope,
            cvd_current=cvd[end])
end

"""Simple linear regression slope."""
function _linear_slope(x::Vector{Float64}, y::Vector{Float64})
    n = length(x)
    n < 2 && return 0.0
    mx = mean(x)
    my = mean(y)
    num = sum((x .- mx) .* (y .- my))
    den = sum((x .- mx) .^ 2)
    return den > 1e-10 ? num / den : 0.0
end

"""
    cvd_to_features(cvd_result, n)

Convert CVD output to feature columns for the feature matrix.
Returns: (cvd_normalized, cvd_slope_normalized, divergence_score)
"""
function cvd_to_features(cvd_result::NamedTuple, n::Int)
    cvd_vals = cvd_result.cvd
    if length(cvd_vals) < n
        cvd_vals = vcat(zeros(n - length(cvd_vals)), cvd_vals)
    end

    # Normalize CVD to z-score
    cvd_aligned = cvd_vals[end-n+1:end]
    μ = mean(cvd_aligned)
    σ = std(cvd_aligned)
    cvd_norm = σ > 1e-10 ? (cvd_aligned .- μ) ./ σ : zeros(n)

    # Slope as scalar feature
    slope_norm = clamp(cvd_result.cvd_slope / max(abs(cvd_result.price_slope) + 1e-10, 1e-10), -5.0, 5.0)

    # Divergence as numeric score
    div_score = if cvd_result.divergence == :bullish_divergence
        1.0
    elseif cvd_result.divergence == :bearish_divergence
        -1.0
    elseif cvd_result.divergence == :bullish_confirmation
        0.5
    elseif cvd_result.divergence == :bearish_confirmation
        -0.5
    else
        0.0
    end

    return (cvd_normalized=cvd_norm, slope=slope_norm, divergence_score=div_score)
end
