# ── Model 34: Momentum-Sentiment Fusion (Plugin Example) ─────
# Demonstrates the @register_model plugin system.
# Combines short-term price momentum with tweet sentiment
# for a fast directional signal. No training required.

"""
    run_momentum_sentiment(returns, tweet_buffer, asset)

Fuses 5-day price momentum with real-time tweet sentiment.
Designed for fast signal generation on high-frequency events.
"""
function run_momentum_sentiment(returns::Vector{Float64};
                                 tweet_sentiment::Union{NamedTuple, Nothing}=nothing)
    n = length(returns)
    if n < 5
        return (direction="HOLD", probability=0.5, accuracy=NaN,
                momentum_score=0.0, sentiment_score=0.0,
                fusion_score=0.0, model="Momentum-Sentiment Fusion")
    end

    # Momentum component: weighted recent returns (more recent = higher weight)
    weights = [0.35, 0.25, 0.20, 0.12, 0.08]  # last 5 days
    recent = returns[max(1, n-4):n]
    if length(recent) < 5
        recent = vcat(zeros(5 - length(recent)), recent)
    end
    momentum_raw = dot(weights, recent)

    # Normalize to [-1, 1]
    vol = std(returns[max(1, n-19):n])
    momentum_score = clamp(momentum_raw / max(vol, 0.001), -3.0, 3.0) / 3.0

    # Sentiment component
    sentiment_score = 0.0
    if tweet_sentiment !== nothing && tweet_sentiment.n_tweets >= 3
        sentiment_score = clamp(tweet_sentiment.avg_score, -1.0, 1.0)
    end

    # Fusion: 60% momentum + 40% sentiment (momentum is more reliable)
    fusion_score = 0.6 * momentum_score + 0.4 * sentiment_score

    # Convert to probability
    probability = clamp(0.5 + fusion_score * 0.3, 0.05, 0.95)

    direction = if probability > 0.58
        "UP"
    elseif probability < 0.42
        "DOWN"
    else
        "HOLD"
    end

    # Backtest accuracy estimate
    if n > 20
        correct = 0
        for t in 6:n-1
            r_recent = returns[max(1,t-4):t]
            mom = dot(weights, length(r_recent) == 5 ? r_recent : vcat(zeros(5-length(r_recent)), r_recent))
            pred_up = mom > 0
            actual_up = returns[t+1] > 0
            if pred_up == actual_up
                correct += 1
            end
        end
        accuracy = correct / (n - 6)
    else
        accuracy = NaN
    end

    return (direction=direction, probability=probability, accuracy=accuracy,
            momentum_score=momentum_score, sentiment_score=sentiment_score,
            fusion_score=fusion_score, model="Momentum-Sentiment Fusion")
end

# ── Auto-register via plugin system on module load ────────────
function _register_m34!()
    register_model!(34, "Momentum-Sentiment Fusion", :fast,
        (ctx) -> run_momentum_sentiment(ctx.returns))
end
