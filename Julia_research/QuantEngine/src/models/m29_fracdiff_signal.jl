# ── Model 29: Fractional Differentiation Signal (Lopez de Prado Ch. 5) ──
# Edge: Achieves stationarity while preserving memory (d < 1).
# Uses the fracdiff series' trend as a directional signal.
# Lower d = more memory preserved = better for prediction.

function run_fracdiff_signal(prices, returns)
    n = length(returns)
    if n < 50
        return (d_optimal=NaN, adf_stat=NaN, is_stationary=false,
                memory_preserved=NaN, fracdiff_last=NaN,
                fracdiff_trend=NaN, direction="HOLD", probability=0.5,
                accuracy=NaN, model="Fractional Differentiation Signal")
    end

    # Find minimum d for stationarity
    log_prices = log.(max.(prices, 1e-8))
    d_optimal = find_min_d(log_prices)

    # Apply fracdiff at optimal d
    fd = fracdiff(log_prices, d_optimal)
    valid = filter(!isnan, fd)

    if length(valid) < 10
        return (d_optimal=d_optimal, adf_stat=NaN, is_stationary=false,
                memory_preserved=1.0 - d_optimal, fracdiff_last=NaN,
                fracdiff_trend=NaN, direction="HOLD", probability=0.5,
                accuracy=NaN, model="Fractional Differentiation Signal")
    end

    # ADF on the fracdiff series
    adf_result = adf_test(valid)

    # Memory preservation: d=0 → 100% memory, d=1 → 0% memory
    memory_preserved = 1.0 - d_optimal

    # Directional signal from recent fracdiff trend
    # Last 5 values trend: positive → bullish momentum with memory
    lookback = min(5, length(valid))
    recent = valid[end-lookback+1:end]
    fracdiff_last = recent[end]
    fracdiff_trend = length(recent) > 1 ? mean(diff(recent)) : 0.0

    # Convert trend to probability
    # Normalize by the std of the fracdiff series
    fd_std = std(valid)
    z_trend = fd_std > 1e-8 ? fracdiff_trend / fd_std : 0.0
    p_up = sigma_nn(z_trend * 3.0)

    direction = p_up > 0.55 ? "UP" : p_up < 0.45 ? "DOWN" : "HOLD"

    return (d_optimal=d_optimal, adf_stat=adf_result.adf_stat,
            is_stationary=adf_result.is_stationary,
            memory_preserved=memory_preserved,
            fracdiff_last=fracdiff_last, fracdiff_trend=fracdiff_trend,
            direction=direction, probability=p_up, accuracy=NaN,
            model="Fractional Differentiation Signal")
end
