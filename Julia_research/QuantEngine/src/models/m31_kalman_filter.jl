# ── Model 31: Kalman Filter for Prediction Market Probabilities ──
# Smooths noisy market prices to extract the true underlying probability.
# Detects information shocks and regime transitions.
# Especially valuable for Polymarket where prices are noisy.

"""
    run_kalman_filter(prices; process_noise, observation_noise)

State-space model for prediction market probabilities.
- State equation: x_t = x_{t-1} + w_t  (random walk prior)
- Observation:    y_t = x_t + v_t        (noisy market price)

Returns smoothed probability, innovation variance, and shock detection.
"""
function run_kalman_filter(prices::Vector{Float64};
                           process_noise::Float64=0.001,
                           observation_noise::Float64=0.01)
    n = length(prices)
    if n < 5
        p = isempty(prices) ? 0.5 : prices[end]
        return (smoothed_prob=p, direction=p > 0.5 ? "UP" : "DOWN",
                probability=p, accuracy=NaN,
                innovations=Float64[], shock_detected=false,
                info_ratio=0.0, trend=0.0,
                model="Kalman Filter (Prediction Market)")
    end

    # Initialize state
    x = prices[1]                    # initial state estimate
    P = observation_noise            # initial state uncertainty

    # Storage
    smoothed = zeros(n)
    innovations = zeros(n)
    kalman_gains = zeros(n)
    state_estimates = zeros(n)
    state_variances = zeros(n)

    for t in 1:n
        # Predict step
        x_pred = x                   # state prediction (random walk)
        P_pred = P + process_noise   # uncertainty grows

        # Update step
        innovation = prices[t] - x_pred   # prediction error
        S = P_pred + observation_noise     # innovation variance
        K = P_pred / S                     # Kalman gain

        x = x_pred + K * innovation       # updated state
        P = (1 - K) * P_pred              # updated uncertainty

        # Clamp to valid probability range
        x = clamp(x, 0.001, 0.999)

        smoothed[t] = x
        innovations[t] = innovation
        kalman_gains[t] = K
        state_estimates[t] = x
        state_variances[t] = P
    end

    # ── Derived signals ──
    current_prob = smoothed[end]

    # Trend: slope of smoothed probability over last 10 observations
    lookback = min(10, n)
    recent = smoothed[end-lookback+1:end]
    trend = (recent[end] - recent[1]) / lookback

    # Shock detection: innovation > 3 standard deviations
    innov_std = std(innovations[max(1,n-20):n])
    shock_detected = abs(innovations[end]) > 3 * max(innov_std, 0.01)

    # Information ratio: signal-to-noise of innovations
    innov_mean = mean(abs.(innovations[max(1,n-20):n]))
    info_ratio = innov_std > 1e-8 ? innov_mean / innov_std : 0.0

    # Direction signal
    direction = if current_prob > 0.55 && trend > 0.001
        "UP"
    elseif current_prob < 0.45 && trend < -0.001
        "DOWN"
    else
        "HOLD"
    end

    # Accuracy: backtest the smoothed filter as a predictor
    if n > 20
        correct = 0
        for t in 11:n-1
            pred_up = smoothed[t] > 0.5
            actual_up = prices[t+1] > prices[t]
            if pred_up == actual_up
                correct += 1
            end
        end
        accuracy = correct / (n - 11)
    else
        accuracy = NaN
    end

    return (smoothed_prob=current_prob, direction=direction,
            probability=current_prob, accuracy=accuracy,
            innovations=innovations, shock_detected=shock_detected,
            info_ratio=info_ratio, trend=trend,
            kalman_gain=kalman_gains[end],
            state_variance=state_variances[end],
            smoothed_series=smoothed,
            model="Kalman Filter (Prediction Market)")
end
