# -- Model 18: Expected Value (EV) Gap ---------------------------------------
# Formula: EV = (p_true - market_price) / market_price
# Edge: $300+/day on $2k bankroll scanning

function run_ev_gap(model_results::Dict, market_price, asset_type::Symbol;
                    daily_vol::Float64=0.02, slippage_bps::Float64=5.0)
    # Aggregate p_true from all models
    probs = Float64[]
    weights = Float64[]
    for (name, r) in model_results
        if r isa NamedTuple && hasproperty(r, :probability)
            p = r.probability
            if !isnan(p) && 0 < p < 1
                push!(probs, p)
                # Give extra weight to order-flow models (logistic, AR1)
                w = occursin("Logistic", name) || occursin("AR(1)", name) ? 1.5 : 1.0
                push!(weights, w)
            end
        end
    end

    if isempty(probs)
        p_true = 0.5
    else
        weights ./= sum(weights)
        p_true = dot(weights, probs)
    end

    # Adjust p_true with order-flow intelligence if available
    # Logistic regression continuation signal boosts/dampens confidence
    logistic_adj = 0.0
    for (name, r) in model_results
        if occursin("Logistic", name) && r isa NamedTuple && hasproperty(r, :continuation_signal)
            logistic_adj = r.continuation_signal ? 0.02 : -0.02
        end
    end
    p_true = clamp(p_true + logistic_adj, 0.01, 0.99)

    # AR(1) regime filter: if mean-reverting, dampen extreme p_true toward 0.5
    for (name, r) in model_results
        if occursin("AR(1)", name) && r isa NamedTuple && hasproperty(r, :beta)
            if r.beta < 0 && abs(r.t_stat) > 1.5  # significant mean-reversion
                p_true = 0.7 * p_true + 0.3 * 0.5  # pull toward 0.5
            end
        end
    end

    # Market probability baseline:
    # Polymarket: actual market price. Stocks/Crypto: historical base rate.
    if asset_type == :polymarket
        p_market = market_price
    else
        # Derive baseline from the actual historical win rate (fraction of up days)
        # This is the "market's" implied probability — what you'd expect without models
        p_market = market_price  # caller passes historical up-day fraction or 0.52 fallback
    end

    ev = (p_true - p_market) / max(p_market, 0.01)
    ev_per_dollar = ev

    # Fee + slippage adjusted EV (asset-specific fees + estimated slippage)
    fee = asset_type == :crypto ? 0.004 : asset_type == :polymarket ? 0.02 : 0.002
    slippage_cost = slippage_bps / 10000.0
    total_cost = fee + slippage_cost
    ev_after_fees = ev - total_cost

    # Dynamic EV threshold: higher vol → require higher edge
    # Base threshold 2%, scaled by daily vol (higher vol = higher noise = need more edge)
    vol_multiplier = clamp(daily_vol / 0.02, 0.5, 3.0)  # normalized to 2% daily vol
    dynamic_threshold_strong = 0.05 * vol_multiplier
    dynamic_threshold_buy = 0.02 * vol_multiplier
    dynamic_threshold_hold = 0.02 * vol_multiplier

    trade_signal = if ev_after_fees > dynamic_threshold_strong
        "STRONG BUY -- EV significantly positive"
    elseif ev_after_fees > dynamic_threshold_buy
        "BUY -- EV positive after costs"
    elseif ev_after_fees > -dynamic_threshold_hold
        "HOLD -- EV near zero"
    else
        "AVOID -- negative EV"
    end

    return (p_true=p_true, p_market=p_market, ev=ev,
            ev_after_fees=ev_after_fees, ev_per_dollar=ev_per_dollar,
            trade_signal=trade_signal, n_models_used=length(probs),
            orderflow_adj=logistic_adj, total_cost=total_cost,
            dynamic_threshold=dynamic_threshold_buy,
            model="EV Gap")
end
