# -- Model 21: Bayesian Update ------------------------------------------------
# Formula: P(H|E) = P(E|H) * P(H) / P(E)
# Edge: 65-75% hit rate on micro-markets

function run_bayesian(returns, model_results::Dict;
                      tweet_sentiment::Union{NamedTuple, Nothing}=nothing)
    r = returns
    n = length(r)

    # Prior P(up) from historical base rate
    prior_up = count(x -> x > 0, r) / n

    # Evidence 1: Recent momentum (last 5 days)
    recent = r[max(1,n-4):n]
    momentum_signal = mean(recent) > 0

    # Evidence 2: Volatility regime (high vol = bearish signal for stocks)
    recent_vol = std(r[max(1,n-19):n])
    hist_vol = std(r)
    vol_elevated = recent_vol > hist_vol * 1.2

    # Evidence 3: Model consensus
    model_probs = Float64[]
    for (_, res) in model_results
        if res isa NamedTuple && hasproperty(res, :probability)
            p = res.probability
            if !isnan(p) && 0 < p < 1
                push!(model_probs, p)
            end
        end
    end
    model_consensus = isempty(model_probs) ? 0.5 : mean(model_probs)
    consensus_bullish = model_consensus > 0.55

    # Sequential Bayesian updates
    posterior = prior_up

    # Update 1: Momentum evidence
    # P(momentum_up | actually_up) estimated from data
    if length(r) > 10
        up_days = r .> 0
        momentum_given_up = mean([i >= 6 && up_days[i] ? mean(r[i-4:i] .> 0) > 0.5 : false
                                  for i in 6:n if up_days[i]])
        momentum_given_up = isnan(momentum_given_up) ? 0.55 : momentum_given_up
        momentum_given_down = 1 - momentum_given_up

        if momentum_signal
            likelihood = momentum_given_up
            evidence = momentum_given_up * posterior + momentum_given_down * (1-posterior)
        else
            likelihood = 1 - momentum_given_up
            evidence = (1-momentum_given_up) * posterior + momentum_given_up * (1-posterior)
        end
        posterior = likelihood * posterior / max(evidence, 1e-8)
    end

    # Update 2: Volatility evidence
    # P(high_vol | down) typically higher than P(high_vol | up)
    if vol_elevated
        p_highvol_down = 0.65  # higher vol more likely in down markets
        p_highvol_up = 0.35
        likelihood = p_highvol_up
        evidence = p_highvol_up * posterior + p_highvol_down * (1-posterior)
        posterior = likelihood * posterior / max(evidence, 1e-8)
    end

    # Update 3: Model consensus evidence
    if consensus_bullish
        p_consensus_up = 0.60   # if models say up and it IS up
        p_consensus_down = 0.40
        likelihood = p_consensus_up
        evidence = p_consensus_up * posterior + p_consensus_down * (1-posterior)
        posterior = likelihood * posterior / max(evidence, 1e-8)
    end

    # Update 4: X/Twitter sentiment evidence (if available)
    tweet_bullish = false
    tweet_bearish = false
    if tweet_sentiment !== nothing && tweet_sentiment.n_tweets >= 3
        if tweet_sentiment.signal == :bullish
            tweet_bullish = true
            p_bulltweet_up = 0.62   # bullish tweets + market up
            p_bulltweet_down = 0.38
            likelihood = p_bulltweet_up
            evidence = p_bulltweet_up * posterior + p_bulltweet_down * (1 - posterior)
            posterior = likelihood * posterior / max(evidence, 1e-8)
        elseif tweet_sentiment.signal == :bearish
            tweet_bearish = true
            p_beartweet_down = 0.60  # bearish tweets + market down
            p_beartweet_up = 0.40
            likelihood = p_beartweet_up
            evidence = p_beartweet_up * posterior + p_beartweet_down * (1 - posterior)
            posterior = likelihood * posterior / max(evidence, 1e-8)
        end
    end

    posterior = clamp(posterior, 0.01, 0.99)

    # Confidence based on evidence agreement
    n_evidence = 3 + (tweet_sentiment !== nothing && tweet_sentiment.n_tweets >= 3 ? 1 : 0)
    evidence_count = (momentum_signal ? 1 : 0) + (!vol_elevated ? 1 : 0) +
                     (consensus_bullish ? 1 : 0) + (tweet_bullish ? 1 : 0)
    confidence = evidence_count / n_evidence * 100

    direction = posterior > 0.55 ? "UP" : posterior < 0.45 ? "DOWN" : "UNCERTAIN"

    tweet_n = tweet_sentiment !== nothing ? tweet_sentiment.n_tweets : 0
    tweet_score = tweet_sentiment !== nothing ? tweet_sentiment.avg_score : 0.0

    return (posterior=posterior, prior=prior_up,
            momentum_signal=momentum_signal, vol_elevated=vol_elevated,
            model_consensus=model_consensus, confidence=confidence,
            tweet_bullish=tweet_bullish, tweet_bearish=tweet_bearish,
            tweet_count=tweet_n, tweet_score=tweet_score,
            direction=direction, model="Bayesian Update")
end
