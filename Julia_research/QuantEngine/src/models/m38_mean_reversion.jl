# ── Layer 3: Mean Reversion Strategies ────────────────────────
# RSI(2), Bollinger Bands, Z-Score reversion.
# Proven: 11.5% CAGR in equities, 32% market exposure.
# Complements trend following (negatively correlated).

"""Mean reversion signal from multiple indicators."""
struct MeanRevSignal
    strategy::String
    direction::Symbol       # :buy (oversold bounce) or :sell (overbought fade)
    strength::Float64       # 0-100 signal strength
    indicator_value::Float64 # the raw indicator reading
end

"""
    rsi(prices, period) → Vector{Float64}

Compute RSI (Relative Strength Index) for a price series.
"""
function compute_rsi(prices::Vector{Float64}, period::Int=14)::Vector{Float64}
    n = length(prices)
    rsi_vals = fill(50.0, n)
    if n < period + 1; return rsi_vals; end

    changes = diff(prices)
    gains = max.(changes, 0.0)
    losses = max.(-changes, 0.0)

    avg_gain = mean(gains[1:period])
    avg_loss = mean(losses[1:period])

    for i in (period+1):length(changes)
        avg_gain = (avg_gain * (period - 1) + gains[i]) / period
        avg_loss = (avg_loss * (period - 1) + losses[i]) / period
        rs = avg_loss > 0 ? avg_gain / avg_loss : 100.0
        rsi_vals[i+1] = 100.0 - 100.0 / (1.0 + rs)
    end
    return rsi_vals
end

"""
    bollinger_bands(prices, period, num_std) → (upper, middle, lower, pct_b)

Compute Bollinger Bands and %B indicator.
"""
function bollinger_bands(prices::Vector{Float64}; period::Int=20, num_std::Float64=2.0)
    n = length(prices)
    upper = fill(NaN, n)
    middle = fill(NaN, n)
    lower = fill(NaN, n)
    pct_b = fill(NaN, n)

    for i in period:n
        window = prices[i-period+1:i]
        mu = mean(window)
        sigma = std(window)
        middle[i] = mu
        upper[i] = mu + num_std * sigma
        lower[i] = mu - num_std * sigma
        band_width = upper[i] - lower[i]
        pct_b[i] = band_width > 0 ? (prices[i] - lower[i]) / band_width : 0.5
    end
    return (upper=upper, middle=middle, lower=lower, pct_b=pct_b)
end

"""
    zscore_reversion(prices, lookback) → Vector{Float64}

Compute rolling z-score of price relative to its moving average.
"""
function zscore_reversion(prices::Vector{Float64}; lookback::Int=20)::Vector{Float64}
    n = length(prices)
    zscores = fill(0.0, n)
    for i in lookback:n
        window = prices[i-lookback+1:i]
        mu = mean(window)
        sigma = std(window)
        zscores[i] = sigma > 1e-10 ? (prices[i] - mu) / sigma : 0.0
    end
    return zscores
end

"""
    evaluate_mean_reversion(prices, volumes) → Vector{MeanRevSignal}

Evaluate all mean reversion indicators and return ranked signals.
"""
function evaluate_mean_reversion(prices::Vector{Float64}, volumes::Vector{Float64})
    signals = MeanRevSignal[]
    n = length(prices)
    if n < 30; return signals; end

    # Strategy 1: RSI(2) — ultra-short-term mean reversion
    rsi2 = compute_rsi(prices, 2)
    rsi_val = rsi2[end]
    if rsi_val < 10  # deeply oversold
        push!(signals, MeanRevSignal("RSI2-Oversold", :buy, 90.0, rsi_val))
    elseif rsi_val < 20
        push!(signals, MeanRevSignal("RSI2-Oversold", :buy, 70.0, rsi_val))
    elseif rsi_val > 90  # deeply overbought
        push!(signals, MeanRevSignal("RSI2-Overbought", :sell, 90.0, rsi_val))
    elseif rsi_val > 80
        push!(signals, MeanRevSignal("RSI2-Overbought", :sell, 70.0, rsi_val))
    end

    # Strategy 2: RSI(14) extremes
    rsi14 = compute_rsi(prices, 14)
    rsi14_val = rsi14[end]
    if rsi14_val < 25
        push!(signals, MeanRevSignal("RSI14-Oversold", :buy, 65.0, rsi14_val))
    elseif rsi14_val > 75
        push!(signals, MeanRevSignal("RSI14-Overbought", :sell, 65.0, rsi14_val))
    end

    # Strategy 3: Bollinger Band bounce
    bb = bollinger_bands(prices; period=20, num_std=2.0)
    if !isnan(bb.pct_b[end])
        pct_b = bb.pct_b[end]
        if pct_b < 0.0  # below lower band
            push!(signals, MeanRevSignal("BB-BelowLower", :buy, 80.0, pct_b))
        elseif pct_b < 0.1
            push!(signals, MeanRevSignal("BB-NearLower", :buy, 60.0, pct_b))
        elseif pct_b > 1.0  # above upper band
            push!(signals, MeanRevSignal("BB-AboveUpper", :sell, 80.0, pct_b))
        elseif pct_b > 0.9
            push!(signals, MeanRevSignal("BB-NearUpper", :sell, 60.0, pct_b))
        end
    end

    # Strategy 4: Z-score reversion
    z20 = zscore_reversion(prices; lookback=20)
    z_val = z20[end]
    if z_val < -2.0
        push!(signals, MeanRevSignal("ZScore-Extreme", :buy, 85.0, z_val))
    elseif z_val < -1.5
        push!(signals, MeanRevSignal("ZScore-Extended", :buy, 60.0, z_val))
    elseif z_val > 2.0
        push!(signals, MeanRevSignal("ZScore-Extreme", :sell, 85.0, z_val))
    elseif z_val > 1.5
        push!(signals, MeanRevSignal("ZScore-Extended", :sell, 60.0, z_val))
    end

    # Strategy 5: Price vs 20-day MA — Internal Bar Strength
    if n >= 20
        ma20 = mean(prices[end-19:end])
        ibs = (prices[end] - minimum(prices[end-19:end])) /
              max(maximum(prices[end-19:end]) - minimum(prices[end-19:end]), 0.01)
        if ibs < 0.1 && prices[end] < ma20
            push!(signals, MeanRevSignal("IBS-Oversold", :buy, 75.0, ibs))
        elseif ibs > 0.9 && prices[end] > ma20
            push!(signals, MeanRevSignal("IBS-Overbought", :sell, 75.0, ibs))
        end
    end

    # Strategy 6: Volume-confirmed reversion (big volume on extreme move = likely to snap back)
    if n >= 10 && length(volumes) >= n
        vol_ratio = volumes[end] / max(mean(volumes[end-9:end]), 1.0)
        daily_ret = (prices[end] - prices[end-1]) / prices[end-1] * 100
        if vol_ratio > 2.0 && daily_ret < -3.0  # big volume selloff
            push!(signals, MeanRevSignal("VolSpike-Oversold", :buy, 85.0, daily_ret))
        elseif vol_ratio > 2.0 && daily_ret > 3.0  # big volume meltup
            push!(signals, MeanRevSignal("VolSpike-Overbought", :sell, 85.0, daily_ret))
        end
    end

    sort!(signals, by=s -> s.strength, rev=true)
    return signals
end

"""
    mean_rev_consensus(signals) → (direction, strength, n_agreeing, strategies)

Find consensus across mean reversion indicators.
"""
function mean_rev_consensus(signals::Vector{MeanRevSignal})
    if isempty(signals)
        return (direction=:hold, strength=0.0, n_agreeing=0, strategies="none")
    end

    buy_signals = filter(s -> s.direction == :buy, signals)
    sell_signals = filter(s -> s.direction == :sell, signals)

    if length(buy_signals) > length(sell_signals) && length(buy_signals) >= 2
        avg_strength = mean(s.strength for s in buy_signals)
        strat_names = join([s.strategy for s in buy_signals], "+")
        return (direction=:buy, strength=avg_strength, n_agreeing=length(buy_signals), strategies=strat_names)
    elseif length(sell_signals) > length(buy_signals) && length(sell_signals) >= 2
        avg_strength = mean(s.strength for s in sell_signals)
        strat_names = join([s.strategy for s in sell_signals], "+")
        return (direction=:sell, strength=avg_strength, n_agreeing=length(sell_signals), strategies=strat_names)
    else
        return (direction=:hold, strength=0.0, n_agreeing=0, strategies="no_consensus")
    end
end
