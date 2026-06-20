# ── Model 24: Black-Scholes Options Pricing + Greeks (Hull Ch. 13-19) ──
# Edge: Detects cheap/rich implied vol vs realized — classic vol arb signal
# All Greeks computed analytically for ATM European options.

function run_black_scholes(returns, S0, high, low;
                           rf=RF_ANNUAL, T=30/252, asset_type=:stock)
    n = length(returns)
    if n < 20 || asset_type == :polymarket
        return (call_price=NaN, put_price=NaN,
                delta_call=NaN, delta_put=NaN, gamma=NaN,
                theta_call=NaN, vega=NaN, rho_call=NaN,
                sigma_hist=NaN, sigma_parkinson=NaN, sigma_ewma=NaN,
                sigma_best=NaN, vol_ratio=NaN, vol_signal="N/A",
                direction="HOLD", probability=0.5, accuracy=NaN,
                model="Black-Scholes Options Pricing")
    end

    # Annualization factor: 252 for stocks, 365 for crypto
    ann_factor = asset_type == :crypto ? 365.0 : 252.0

    # ── Volatility Estimators ──────────────────────────────────
    # 1. Historical (close-to-close)
    sigma_hist = std(returns) * sqrt(ann_factor)

    # 2. Parkinson (high-low range estimator — more efficient)
    n_hl = min(length(high), length(low), n)
    h = high[end-n_hl+1:end]
    l = low[end-n_hl+1:end]
    hl_ratio = log.(max.(h, 1e-8) ./ max.(l, 1e-8))
    sigma_park = sqrt(1.0 / (4 * n_hl * log(2)) * sum(hl_ratio .^ 2)) * sqrt(ann_factor)

    # 3. EWMA (RiskMetrics, lambda=0.94)
    lambda = 0.94
    r2 = returns .^ 2
    ewma_var = r2[1]
    for i in 2:n
        ewma_var = lambda * ewma_var + (1 - lambda) * r2[i]
    end
    sigma_ewma = sqrt(max(ewma_var, 1e-12)) * sqrt(ann_factor)

    # Best estimate: median of three (robust to outliers)
    sigma = median([sigma_hist, sigma_park, sigma_ewma])
    sigma = clamp(sigma, 0.01, 5.0)  # guard extreme vol

    # ── Black-Scholes Pricing (ATM) ────────────────────────────
    K = S0  # at-the-money
    sqrtT = sqrt(max(T, 1e-8))

    # Normal CDF via erfc: Φ(x) = 0.5 * erfc(-x / √2)
    Phi(x) = 0.5 * erfc(-x / sqrt(2))
    # Normal PDF: φ(x) = exp(-x²/2) / √(2π)
    phi(x) = exp(-x^2 / 2) / sqrt(2π)

    d1 = (log(S0 / K) + (rf + sigma^2 / 2) * T) / (sigma * sqrtT)
    d2 = d1 - sigma * sqrtT

    disc = exp(-rf * T)
    call_price = S0 * Phi(d1) - K * disc * Phi(d2)
    put_price  = K * disc * Phi(-d2) - S0 * Phi(-d1)

    # ── Greeks ─────────────────────────────────────────────────
    delta_call = Phi(d1)
    delta_put  = Phi(d1) - 1.0
    gamma      = phi(d1) / (S0 * sigma * sqrtT)
    theta_call = (-(S0 * phi(d1) * sigma) / (2 * sqrtT)
                  - rf * K * disc * Phi(d2)) / ann_factor  # daily theta
    vega       = S0 * phi(d1) * sqrtT / 100.0   # per 1% vol move
    rho_call   = K * T * disc * Phi(d2) / 100.0  # per 1% rate move

    # ── Volatility Signal ──────────────────────────────────────
    vol_ratio = sigma_hist / max(sigma_ewma, 1e-8)

    vol_signal = if vol_ratio > 1.2
        "RICH VOL -- realized > expected (sell vol / bullish lean)"
    elseif vol_ratio < 0.8
        "CHEAP VOL -- realized < expected (buy vol / bearish lean)"
    else
        "FAIR VOL"
    end

    # Probability: when EWMA > hist, market expects more vol than realized → bullish lean
    p_up = sigma_nn((sigma_ewma - sigma_hist) / max(sigma_hist, 1e-8) * 5.0)

    direction = p_up > 0.55 ? "UP" : p_up < 0.45 ? "DOWN" : "HOLD"

    return (call_price=call_price, put_price=put_price,
            delta_call=delta_call, delta_put=delta_put, gamma=gamma,
            theta_call=theta_call, vega=vega, rho_call=rho_call,
            sigma_hist=sigma_hist, sigma_parkinson=sigma_park,
            sigma_ewma=sigma_ewma, sigma_best=sigma,
            vol_ratio=vol_ratio, vol_signal=vol_signal,
            direction=direction, probability=p_up, accuracy=NaN,
            model="Black-Scholes Options Pricing")
end
