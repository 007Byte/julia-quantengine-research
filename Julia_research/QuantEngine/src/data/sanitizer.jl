# ── Data Sanitization — Defense-in-Depth Layer 1 ─────────────
# All external data validated before entering the pipeline.

"""Validate and sanitize a price value."""
function sanitize_price(p; label="price")::Float64
    v = Float64(p)
    if isnan(v) || isinf(v)
        error("Invalid $label: NaN/Inf")
    end
    if v < 0.0
        error("Invalid $label: negative ($v)")
    end
    if v > 1e9
        error("Suspiciously large $label: $v (> 1 billion)")
    end
    return v
end

"""Validate and sanitize a volume value."""
function sanitize_volume(v; label="volume")::Float64
    val = Float64(v)
    if isnan(val) || isinf(val)
        @warn "Invalid $label: NaN/Inf — replacing with 0.0"
        return 0.0
    end
    if val < 0.0
        @warn "Negative $label: $val — replacing with 0.0"
        return 0.0
    end
    return val
end

"""Validate and sanitize a returns vector. Clamps extreme values."""
function sanitize_returns(r::Vector{Float64}; max_abs_return=0.50)::Vector{Float64}
    out = copy(r)
    for i in eachindex(out)
        if isnan(out[i]) || isinf(out[i])
            @warn "NaN/Inf in returns at index $i — replacing with 0.0"
            out[i] = 0.0
        end
        if abs(out[i]) > max_abs_return
            @warn "Extreme return at index $i: $(out[i]) — clamping to ±$max_abs_return"
            out[i] = clamp(out[i], -max_abs_return, max_abs_return)
        end
    end
    return out
end

"""Validate Polymarket market data."""
function sanitize_polymarket(prices::Vector{Float64}, outcomes::Vector)
    # Prices must be in [0, 1]
    for (i, p) in enumerate(prices)
        if p < 0.0 || p > 1.0
            error("Polymarket price[$i] out of range [0,1]: $p")
        end
    end
    # Prices should sum to approximately 1.0
    total = sum(prices)
    if abs(total - 1.0) > 0.10
        @warn "Polymarket prices sum to $total (expected ~1.0) — possible data issue"
    end
    # Must have at least 2 outcomes
    if length(outcomes) < 2
        error("Polymarket must have at least 2 outcomes, got $(length(outcomes))")
    end
    if length(prices) != length(outcomes)
        error("Polymarket prices/outcomes length mismatch: $(length(prices)) vs $(length(outcomes))")
    end
end

"""Validate OHLCV data from Yahoo Finance."""
function sanitize_ohlcv(dates, high, low, close, volume, adj)
    n = length(dates)
    @assert n > 0 "Empty OHLCV data"
    @assert length(high) == n "High length mismatch"
    @assert length(low) == n "Low length mismatch"
    @assert length(close) == n "Close length mismatch"
    @assert length(volume) == n "Volume length mismatch"
    @assert length(adj) == n "Adj close length mismatch"

    # Check for all-NaN
    valid_prices = count(!isnan, adj)
    if valid_prices < 10
        error("Too few valid prices: $valid_prices (need at least 10)")
    end

    # Check date ordering (should be ascending)
    if n >= 2 && dates[end] < dates[1]
        @warn "OHLCV dates appear to be in descending order — may need reversal"
    end
end
