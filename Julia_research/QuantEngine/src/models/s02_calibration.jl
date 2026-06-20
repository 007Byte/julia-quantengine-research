# -- Supporting Technique S2: Calibration Check -------------------------------
# Validates model probability predictions against actual outcomes
# Edge: Feeds directly into EV Gap + Kelly pipeline

function run_calibration_check(returns, model_results::Dict)
    r = returns
    n = length(r)

    # Gather all model probabilities and check against actuals
    all_probs = Float64[]
    for (_, res) in model_results
        if res isa NamedTuple && hasproperty(res, :probability)
            p = res.probability
            if !isnan(p) && 0 < p < 1
                push!(all_probs, p)
            end
        end
    end

    if isempty(all_probs) || n < 2
        return (avg_model_prob=NaN, actual_up_rate=NaN,
                calibration_gap=NaN, is_calibrated=false,
                model="Calibration Check")
    end

    avg_p = mean(all_probs)

    # Actual up-rate from recent data (last 60 days)
    recent = r[max(1, n-59):n]
    actual_up_rate = count(x -> x > 0, recent) / length(recent)

    # Calibration gap: E[Y | p_hat=p] - p
    cal_gap = actual_up_rate - avg_p

    is_calibrated = abs(cal_gap) < 0.05

    return (avg_model_prob=avg_p, actual_up_rate=actual_up_rate,
            calibration_gap=cal_gap, is_calibrated=is_calibrated,
            model="Calibration Check")
end
