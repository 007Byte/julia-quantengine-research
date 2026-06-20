# -- Model 23: AR(1) Autoregression (Momentum vs Mean-Reversion) -------------
# Formula: r_{t+1} = alpha + beta * r_t + epsilon_t
# Edge: Quick statistical filter before XGBoost

function run_ar1(returns)
    r = returns
    n = length(r)
    if n < 10
        return (alpha=0.0, beta=0.0, regime="UNKNOWN", probability=0.5,
                r_squared=0.0, forecast_return=0.0, se_beta=NaN,
                model="AR(1) Autoregression")
    end

    # OLS: r_{t+1} = alpha + beta * r_t
    y = r[2:end]        # r_{t+1}
    x = r[1:end-1]      # r_t
    n_obs = length(y)

    x_mean = mean(x); y_mean = mean(y)
    Sxy = sum((x .- x_mean) .* (y .- y_mean))
    Sxx = sum((x .- x_mean) .^ 2)

    beta = Sxx > 1e-12 ? Sxy / Sxx : 0.0
    alpha = y_mean - beta * x_mean

    # Residuals & R-squared
    y_hat = alpha .+ beta .* x
    residuals = y .- y_hat
    SSres = sum(residuals .^ 2)
    SStot = sum((y .- y_mean) .^ 2)
    r_squared = SStot > 1e-12 ? 1 - SSres / SStot : 0.0

    # Standard error of beta
    sigma_resid = sqrt(SSres / max(1, n_obs - 2))
    se_beta = Sxx > 1e-12 ? sigma_resid / sqrt(Sxx) : NaN
    t_stat = !isnan(se_beta) && se_beta > 1e-12 ? beta / se_beta : 0.0

    # Regime classification
    regime = if beta > 0 && abs(t_stat) > 1.96
        "MOMENTUM -- ride the trend (beta > 0, significant)"
    elseif beta < 0 && abs(t_stat) > 1.96
        "MEAN-REVERSION -- fade the move (beta < 0, significant)"
    elseif beta > 0
        "WEAK MOMENTUM (beta > 0, not significant)"
    elseif beta < 0
        "WEAK MEAN-REVERSION (beta < 0, not significant)"
    else
        "RANDOM WALK"
    end

    # One-step forecast
    forecast_return = alpha + beta * r[end]

    # Convert to directional probability
    p_up = sigma_nn(forecast_return / max(std(residuals), 1e-8))

    # Event study: measure how returns change after large moves
    # Look at returns following moves > 1 std dev
    sigma_r = std(r)
    big_moves = findall(abs.(r) .> sigma_r)
    post_move_returns = Float64[]
    for idx in big_moves
        if idx < n
            push!(post_move_returns, r[idx+1] * sign(r[idx]))  # same-direction = positive
        end
    end

    continuation_rate = isempty(post_move_returns) ? 0.5 :
        count(x -> x > 0, post_move_returns) / length(post_move_returns)

    # Calibration check: E[Y | p_hat = p] - p
    # Bin predictions into quintiles and check calibration
    preds_all = [sigma_nn((alpha + beta * r[i]) / max(sigma_resid, 1e-8)) for i in 1:n-1]
    actuals   = [r[i+1] > 0 ? 1.0 : 0.0 for i in 1:n-1]
    calibration_error = NaN
    if length(preds_all) >= 20
        sorted_idx = sortperm(preds_all)
        n_bins = 5
        bin_size = div(length(sorted_idx), n_bins)
        cal_errors = Float64[]
        for b in 1:n_bins
            start = (b-1)*bin_size + 1
            stop  = b == n_bins ? length(sorted_idx) : b*bin_size
            bin_idx = sorted_idx[start:stop]
            avg_pred = mean(preds_all[bin_idx])
            avg_actual = mean(actuals[bin_idx])
            push!(cal_errors, abs(avg_actual - avg_pred))
        end
        calibration_error = mean(cal_errors)
    end

    return (alpha=alpha, beta=beta, regime=regime, probability=p_up,
            r_squared=r_squared, forecast_return=forecast_return,
            se_beta=se_beta, t_stat=t_stat, continuation_rate=continuation_rate,
            calibration_error=calibration_error,
            event_study_n=length(post_move_returns),
            model="AR(1) Autoregression")
end
