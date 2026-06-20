# ── Model 27: Martingale Detection — VR + Runs + ADF (Shreve) ──
# Edge: If series is NOT a martingale → predictability exists → boost confidence
#        If series IS a martingale → limited predictability → dampen signals
# Phase 2: reads model_results to adjust ensemble confidence.

function run_martingale_test(returns, model_results::Dict)
    r = returns
    n = length(r)
    if n < 30
        return (vr2=NaN, vr5=NaN, vr10=NaN, vr20=NaN,
                z_vr2=NaN, z_vr5=NaN, z_vr10=NaN, z_vr20=NaN,
                vr_reject=false, runs_z=NaN, runs_reject=false,
                adf_t=NaN, adf_reject=false, predictability=0.0,
                is_martingale=true, regime="UNKNOWN",
                confidence_adj="NEUTRAL",
                direction="HOLD", probability=0.5, accuracy=NaN,
                model="Martingale Detection (VR+Runs+ADF)")
    end

    # ── Part A: Variance Ratio Test (Lo-MacKinlay) ─────────────
    # Under H0 (random walk): VR(q) = Var(q-period return) / (q * Var(1-period return)) = 1
    sigma2_1 = var(r)
    vr_results = Dict{Int, Float64}()
    z_results = Dict{Int, Float64}()
    vr_reject_any = false

    for q in [2, 5, 10, 20]
        if n < 2 * q
            vr_results[q] = NaN; z_results[q] = NaN
            continue
        end

        # q-period overlapping returns
        r_q = [sum(r[t:t+q-1]) for t in 1:(n-q+1)]
        sigma2_q = var(r_q)
        vr = sigma2_q / (q * sigma2_1)
        vr_results[q] = vr

        # Heteroscedasticity-robust test statistic (Lo-MacKinlay 1988)
        phi_q = 0.0
        for j in 1:(q-1)
            delta_j = 0.0
            denom = 0.0
            for t in (j+1):n
                delta_j += r[t]^2 * r[t-j]^2
                denom += r[t]^2
            end
            denom = max(denom^2 / n, 1e-12)
            delta_j = n * delta_j / denom
            phi_q += (2 * (q - j) / q)^2 * delta_j
        end
        phi_q = max(phi_q, 1e-12)
        z = (vr - 1.0) / sqrt(phi_q)
        z_results[q] = z

        if abs(z) > 1.96
            vr_reject_any = true
        end
    end

    # ── Part B: Runs Test ──────────────────────────────────────
    signs = sign.(r)
    n_pos = count(x -> x > 0, signs)
    n_neg = count(x -> x < 0, signs)

    # Count runs (consecutive sequences of same sign)
    n_runs = 1
    for i in 2:n
        if signs[i] != signs[i-1] && signs[i] != 0 && signs[i-1] != 0
            n_runs += 1
        end
    end

    n_nz = n_pos + n_neg  # non-zero observations
    if n_nz > 1
        E_R = 1.0 + 2.0 * n_pos * n_neg / n_nz
        var_R = 2.0 * n_pos * n_neg * (2.0 * n_pos * n_neg - n_nz) /
                (n_nz^2 * (n_nz - 1))
        var_R = max(var_R, 1e-12)
        runs_z = (n_runs - E_R) / sqrt(var_R)
    else
        runs_z = 0.0
    end
    runs_reject = abs(runs_z) > 1.96

    # ── Part C: ADF Test (reuse from fracdiff.jl) ──────────────
    adf_result = adf_test(r)
    adf_t = adf_result.adf_stat
    adf_reject = adf_result.is_stationary

    # ── Part D: Composite Predictability Score ─────────────────
    predictability = (Float64(vr_reject_any) + Float64(runs_reject) + Float64(adf_reject)) / 3.0

    is_martingale = predictability < 0.5
    regime = if predictability >= 0.67
        "PREDICTABLE"
    elseif predictability <= 0.33
        "MARTINGALE"
    else
        "BORDERLINE"
    end

    # ── Part E: Confidence Adjustment (Phase 2) ────────────────
    # Read ensemble probabilities from prior models
    probs = Float64[]
    for (_, res) in model_results
        if res isa NamedTuple && hasproperty(res, :probability)
            p = res.probability
            if !isnan(p) && 0 < p < 1
                push!(probs, p)
            end
        end
    end
    p_ensemble = isempty(probs) ? 0.5 : mean(probs)

    if predictability <= 0.33  # martingale → dampen
        probability = 0.5 + 0.5 * (p_ensemble - 0.5)
        confidence_adj = "DAMPENED"
    elseif predictability >= 0.67  # predictable → boost
        probability = 0.5 + 1.3 * (p_ensemble - 0.5)
        probability = clamp(probability, 0.01, 0.99)
        confidence_adj = "BOOSTED"
    else
        probability = p_ensemble
        confidence_adj = "NEUTRAL"
    end

    direction = probability > 0.55 ? "UP" : probability < 0.45 ? "DOWN" : "HOLD"

    return (vr2=get(vr_results, 2, NaN), vr5=get(vr_results, 5, NaN),
            vr10=get(vr_results, 10, NaN), vr20=get(vr_results, 20, NaN),
            z_vr2=get(z_results, 2, NaN), z_vr5=get(z_results, 5, NaN),
            z_vr10=get(z_results, 10, NaN), z_vr20=get(z_results, 20, NaN),
            vr_reject=vr_reject_any, runs_z=runs_z, runs_reject=runs_reject,
            adf_t=adf_t, adf_reject=adf_reject,
            predictability=predictability, is_martingale=is_martingale,
            regime=regime, confidence_adj=confidence_adj,
            direction=direction, probability=probability, accuracy=NaN,
            model="Martingale Detection (VR+Runs+ADF)")
end
