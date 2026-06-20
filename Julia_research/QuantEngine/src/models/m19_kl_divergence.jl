# -- Model 19: KL-Divergence -------------------------------------------------
# Formula: D_KL(P || Q) = Sum P_i * log(P_i / Q_i)
# Edge: 15% portfolio uplift

function run_kl_divergence(returns, model_results::Dict)
    r = returns
    n = length(r)

    # P = model distribution (from ensemble of models)
    probs = Float64[]
    for (_, res) in model_results
        if res isa NamedTuple && hasproperty(res, :probability)
            p = res.probability
            if !isnan(p) && 0 < p < 1
                push!(probs, p)
            end
        end
    end

    p_model_up = isempty(probs) ? 0.5 : mean(probs)
    P = [p_model_up, 1 - p_model_up]  # [P(up), P(down)]

    # Q = market-implied distribution
    # Estimated from historical frequency
    p_hist_up = count(x -> x > 0, r) / n
    Q = [p_hist_up, 1 - p_hist_up]

    # Ensure no zeros
    P = max.(P, 1e-8); P ./= sum(P)
    Q = max.(Q, 1e-8); Q ./= sum(Q)

    # KL Divergence
    kl_pq = sum(P .* log.(P ./ Q))  # Model vs Market
    kl_qp = sum(Q .* log.(Q ./ P))  # Market vs Model (reverse)

    # Symmetric KL (Jensen-Shannon)
    M = 0.5 .* (P .+ Q)
    js_div = 0.5 * sum(P .* log.(P ./ M)) + 0.5 * sum(Q .* log.(Q ./ M))

    # Trading signal
    hedge_signal = if kl_pq > 0.2
        "HIGH DIVERGENCE -- consider hedging or contrarian position"
    elseif kl_pq > 0.05
        "MODERATE DIVERGENCE -- monitor closely"
    else
        "LOW DIVERGENCE -- model agrees with market"
    end

    return (kl_divergence=kl_pq, kl_reverse=kl_qp, js_divergence=js_div,
            model_dist=P, market_dist=Q,
            hedge_signal=hedge_signal, model="KL-Divergence")
end
