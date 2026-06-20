# ── Model 26: Term Structure — Nelson-Siegel + Vasicek (Hull Ch. 31-33, Joshi Ch. 17-20) ──
# Edge: Rate regime (inverted/steep/flat) historically predicts equity returns
# Nelson-Siegel fits the yield curve; Vasicek models the short rate process.

function run_term_structure(returns; rf=RF_ANNUAL, asset_type=:stock)
    n = length(returns)
    if n < 20 || asset_type == :polymarket
        return (ns_beta0=NaN, ns_beta1=NaN, ns_beta2=NaN, ns_lambda=NaN,
                vasicek_kappa=NaN, vasicek_theta=NaN, vasicek_sigma=NaN,
                bond_10y_price=NaN, ns_vs_vasicek_err=NaN,
                rate_regime="N/A", direction="HOLD", probability=0.5,
                accuracy=NaN, model="Term Structure (NS + Vasicek)")
    end

    # ── Part A: Nelson-Siegel Yield Curve ──────────────────────
    # Synthetic curve anchored at RF_ANNUAL (no live Treasury feed)
    maturities = [0.25, 1.0, 2.0, 5.0, 10.0, 20.0, 30.0]
    # Stylized shape: short end slightly below, long end slightly above
    equity_vol = std(returns) * sqrt(252)
    # Slope reflects equity vol regime: high vol → flatter/inverted
    vol_factor = clamp(1.0 - equity_vol / 0.30, -0.5, 1.0)
    observed_yields = [
        rf * (0.80 + 0.05 * vol_factor),   # 3M
        rf * (0.85 + 0.05 * vol_factor),   # 1Y
        rf * (0.90 + 0.05 * vol_factor),   # 2Y
        rf * (0.97 + 0.02 * vol_factor),   # 5Y
        rf * 1.00,                          # 10Y (anchor)
        rf * (1.03 - 0.02 * vol_factor),   # 20Y
        rf * (1.05 - 0.03 * vol_factor),   # 30Y
    ]

    # Nelson-Siegel: y(τ) = β₀ + β₁*(1-e^(-τ/λ))/(τ/λ) + β₂*((1-e^(-τ/λ))/(τ/λ) - e^(-τ/λ))
    function ns_yield(tau, beta0, beta1, beta2, lam)
        lam = max(lam, 0.01)
        x = tau / lam
        ex = exp(-x)
        term1 = (1 - ex) / x
        term2 = term1 - ex
        return beta0 + beta1 * term1 + beta2 * term2
    end

    function ns_loss(p)
        b0, b1, b2, lam = p[1], p[2], p[3], exp(p[4])
        sse = 0.0
        for (i, tau) in enumerate(maturities)
            model_y = ns_yield(tau, b0, b1, b2, lam)
            sse += (model_y - observed_yields[i])^2
        end
        return sse
    end

    # Initial guess: β₀ ≈ long rate, β₁ ≈ -(long-short), β₂ ≈ curvature
    p0 = [rf, -(rf * 0.2), rf * 0.1, log(2.0)]
    opt = optimize(ns_loss, p0, NelderMead(),
                   Optim.Options(iterations=1000, show_trace=false))
    pn = Optim.minimizer(opt)
    ns_beta0 = pn[1]
    ns_beta1 = pn[2]
    ns_beta2 = pn[3]
    ns_lambda = exp(pn[4])

    # ── Part B: Vasicek Short-Rate Model ───────────────────────
    # SDE: dr = κ(θ - r)dt + σ_r dW
    # Estimate κ from AR(1) on returns as proxy
    r_lag = returns[1:end-1]
    r_lead = returns[2:end]
    cov_rl = mean(r_lag .* r_lead) - mean(r_lag) * mean(r_lead)
    var_lag = var(r_lag)
    ar1_coeff = var_lag > 1e-12 ? cov_rl / var_lag : 0.0

    vasicek_kappa = clamp(-log(clamp(abs(ar1_coeff), 0.01, 0.99)) * 252, 0.01, 5.0)
    vasicek_theta = rf
    vasicek_sigma = std(returns) * rf * 0.3  # rate vol << equity vol

    # Vasicek bond price: P(0,T) = A(T) * exp(-B(T) * r₀)
    function vasicek_bond(T_bond, r0)
        kap = vasicek_kappa; th = vasicek_theta; sig = vasicek_sigma
        B = (1 - exp(-kap * T_bond)) / kap
        A = exp((B - T_bond) * (kap^2 * th - sig^2 / 2) / kap^2
                - sig^2 * B^2 / (4 * kap))
        return A * exp(-B * r0)
    end

    bond_10y = vasicek_bond(10.0, rf)

    # Vasicek-implied yields for comparison
    vasicek_yields = [-log(max(vasicek_bond(tau, rf), 1e-12)) / tau for tau in maturities]
    ns_yields = [ns_yield(tau, ns_beta0, ns_beta1, ns_beta2, ns_lambda) for tau in maturities]
    ns_vs_vasicek = sqrt(mean((vasicek_yields .- ns_yields) .^ 2))

    # ── Part C: Rate Regime Signal ─────────────────────────────
    rate_regime = if ns_beta1 < -0.005
        "INVERTED CURVE"
    elseif ns_beta1 > 0.005 && ns_beta2 > 0
        "STEEPENING"
    elseif ns_beta1 > 0.005 && ns_beta2 <= 0
        "FLATTENING"
    else
        "NORMAL"
    end

    base_prob = if rate_regime == "INVERTED CURVE"
        0.40  # historically bearish
    elseif rate_regime == "STEEPENING"
        0.58  # bullish
    elseif rate_regime == "FLATTENING"
        0.48  # cautious
    else
        0.52  # slight upward drift
    end

    # Dampen for crypto (less rate-sensitive)
    probability = asset_type == :crypto ? 0.5 + 0.3 * (base_prob - 0.5) : base_prob

    direction = probability > 0.55 ? "UP" : probability < 0.45 ? "DOWN" : "HOLD"

    return (ns_beta0=ns_beta0, ns_beta1=ns_beta1, ns_beta2=ns_beta2,
            ns_lambda=ns_lambda, vasicek_kappa=vasicek_kappa,
            vasicek_theta=vasicek_theta, vasicek_sigma=vasicek_sigma,
            bond_10y_price=bond_10y, ns_vs_vasicek_err=ns_vs_vasicek,
            rate_regime=rate_regime, direction=direction,
            probability=probability, accuracy=NaN,
            model="Term Structure (NS + Vasicek)")
end
