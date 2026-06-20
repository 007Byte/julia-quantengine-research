# ── Model 30: Triple-Barrier Regime Signal (Lopez de Prado Ch. 4) ──
# Edge: Classifies market regime by barrier hit rates.
# Trending → high upper/lower hits; Mean-reverting → high vertical expiry.

function run_triple_barrier_signal(returns, volumes)
    n = length(returns)
    if n < 30
        return (upper_hit_rate=NaN, lower_hit_rate=NaN, expiry_rate=NaN,
                regime="UNKNOWN", avg_barrier_width=NaN,
                direction="HOLD", probability=0.5, accuracy=NaN,
                model="Triple-Barrier Regime")
    end

    # Compute rolling volatility
    vol = daily_volatility(returns; window=20)

    # Apply triple-barrier to recent history
    tb = triple_barrier_label(returns, vol; pt_mult=2.0, sl_mult=1.0, max_holding=10)

    # Use only the recent portion where vol is valid (skip first 19 NaN entries)
    start_idx = findfirst(!isnan, vol)
    start_idx = start_idx === nothing ? 1 : start_idx
    # Also skip last max_holding entries (incomplete forward window)
    end_idx = max(start_idx, n - 10)
    tb_valid = tb[start_idx:end_idx]
    vol_valid = vol[start_idx:end_idx]

    n_valid = length(tb_valid)
    if n_valid < 10
        return (upper_hit_rate=NaN, lower_hit_rate=NaN, expiry_rate=NaN,
                regime="UNKNOWN", avg_barrier_width=NaN,
                direction="HOLD", probability=0.5, accuracy=NaN,
                model="Triple-Barrier Regime")
    end

    # Hit rate statistics
    upper_hits = count(x -> x > 0, tb_valid)
    lower_hits = count(x -> x < 0, tb_valid)
    expiry_hits = count(x -> x == 0, tb_valid)

    upper_rate = upper_hits / n_valid
    lower_rate = lower_hits / n_valid
    expiry_rate = expiry_hits / n_valid

    avg_barrier = mean(filter(!isnan, vol_valid)) * 2.0  # pt_mult * sigma

    # Regime classification
    trending_rate = upper_rate + lower_rate  # total barrier touches
    regime = if trending_rate > 0.6
        if upper_rate > lower_rate * 1.5
            "BULLISH TRENDING"
        elseif lower_rate > upper_rate * 1.5
            "BEARISH TRENDING"
        else
            "CHOPPY TRENDING"
        end
    elseif expiry_rate > 0.6
        "MEAN-REVERTING"
    else
        "MIXED"
    end

    # Probability signal
    # More upper hits → bullish; more lower hits → bearish
    if upper_rate + lower_rate > 1e-8
        directional_ratio = upper_rate / (upper_rate + lower_rate)
    else
        directional_ratio = 0.5
    end

    # Weight by how "trending" the market is (higher trending_rate → more confident signal)
    confidence = clamp(trending_rate, 0.0, 1.0)
    probability = 0.5 + confidence * (directional_ratio - 0.5)
    probability = clamp(probability, 0.01, 0.99)

    direction = probability > 0.55 ? "UP" : probability < 0.45 ? "DOWN" : "HOLD"

    return (upper_hit_rate=upper_rate, lower_hit_rate=lower_rate,
            expiry_rate=expiry_rate, regime=regime,
            avg_barrier_width=avg_barrier,
            direction=direction, probability=probability, accuracy=NaN,
            model="Triple-Barrier Regime")
end
