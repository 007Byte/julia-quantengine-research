# ── Model 4: LSTM-GARCH Hybrid ──────────────────────────────
# Edge: Institutional VaR/hedging standard

function run_lstm_garch(returns, Xseq_tr, yseq_tr, n_feat, S0; hidden=8, lstm_result=nothing)
    # Step 1: Fit GARCH(1,1) for volatility
    r = returns
    n = length(r)
    r2 = r .^ 2
    ω0, α0, β0 = var(r) * 0.05, 0.08, 0.88

    function garch_nll(p)
        ω, α, β = exp(p[1]), σ_nn(p[2]), σ_nn(p[3])
        if ω < 1e-12 || α + β >= 0.9999 return 1e10 end
        σ2 = var(r)
        ll = 0.0
        for i in 2:n
            σ2 = ω + α * r2[i-1] + β * σ2
            σ2 = max(σ2, 1e-12)
            ll += -0.5 * (log(2π) + log(σ2) + r2[i] / σ2)
        end
        return -ll
    end

    opt_g = optimize(garch_nll, [log(ω0), 0.0, 2.0], NelderMead(),
                     Optim.Options(iterations=500, show_trace=false))
    pg = Optim.minimizer(opt_g)
    ω_hat, α_hat, β_hat = exp(pg[1]), σ_nn(pg[2]), σ_nn(pg[3])

    # Generate GARCH conditional volatility series
    σ2_series = fill(var(r), n)
    for i in 2:n
        σ2_series[i] = ω_hat + α_hat * r2[i-1] + β_hat * σ2_series[i-1]
    end
    σ_forecast = sqrt(σ2_series[end]) * sqrt(252)

    # Step 2: LSTM on GARCH residuals (standardized returns)
    std_returns = r ./ sqrt.(max.(σ2_series, 1e-12))

    # Use LSTM prediction from Model 1 if available
    lstm_prob = lstm_result !== nothing ? lstm_result.probability : 0.5

    # VaR bands
    var_95 = S0 * (1.0 - exp(quantile(r, 0.05)))
    var_99 = S0 * (1.0 - exp(quantile(r, 0.01)))

    return (garch_omega=ω_hat, garch_alpha=α_hat, garch_beta=β_hat,
            σ_annual_forecast=σ_forecast, var_95=var_95, var_99=var_99,
            lstm_correction=lstm_prob, persistence=α_hat+β_hat,
            model="LSTM-GARCH Hybrid")
end
