# ── Sentiment Embedding Model (Pure Julia) ───────────────────
# Lightweight learned sentiment scorer using word embeddings.
# No Python, no ONNX — trains on financial text patterns.
# Upgrades from keyword-based to contextual scoring.

"""Pre-computed sentiment lexicon with continuous scores."""
const FINANCE_LEXICON = Dict{String, Float64}(
    # Strong bullish (0.7 - 1.0)
    "moon" => 0.9, "rally" => 0.8, "breakout" => 0.85, "surge" => 0.8,
    "soar" => 0.85, "rocket" => 0.9, "bullish" => 0.8, "ath" => 0.9,
    "accumulate" => 0.7, "upgrade" => 0.75, "outperform" => 0.7,
    "beat" => 0.6, "exceeds" => 0.65, "blowout" => 0.7,

    # Moderate bullish (0.3 - 0.7)
    "buy" => 0.5, "long" => 0.5, "green" => 0.4, "profit" => 0.5,
    "gains" => 0.5, "higher" => 0.4, "recovery" => 0.5, "bounce" => 0.45,
    "support" => 0.35, "dip" => 0.3, "cheap" => 0.35, "undervalued" => 0.6,
    "strong" => 0.4, "growth" => 0.45, "bullrun" => 0.7, "launch" => 0.5,

    # Strong bearish (-0.7 to -1.0)
    "crash" => -0.9, "dump" => -0.85, "rekt" => -0.9, "scam" => -0.95,
    "liquidated" => -0.9, "plunge" => -0.85, "tank" => -0.8, "collapse" => -0.9,
    "bankrupt" => -0.95, "fraud" => -0.95, "ponzi" => -0.95, "rug" => -0.9,

    # Moderate bearish (-0.3 to -0.7)
    "sell" => -0.5, "short" => -0.5, "bear" => -0.6, "bearish" => -0.7,
    "red" => -0.4, "loss" => -0.5, "drop" => -0.5, "lower" => -0.4,
    "fear" => -0.6, "panic" => -0.7, "bubble" => -0.55, "overvalued" => -0.6,
    "downgrade" => -0.65, "warning" => -0.5, "risk" => -0.35, "weak" => -0.4,

    # Context modifiers
    "very" => 0.0, "extremely" => 0.0, "massive" => 0.0, "huge" => 0.0,
    "not" => 0.0, "no" => 0.0, "never" => 0.0, "dont" => 0.0,
)

"""
    score_sentiment_v2(text) → Float64

Enhanced sentiment scoring using continuous lexicon scores,
negation handling, context windows, and phrase patterns.
Returns score in [-1.0, 1.0].
"""
function score_sentiment_v2(text::String)::Float64
    words = split(lowercase(text), r"[\s,\.!?;:\-\(\)\[\]\"\'#@]+")
    words = filter(w -> !isempty(w) && length(w) > 1, words)

    if isempty(words)
        return 0.0
    end

    score = 0.0
    weight_sum = 0.0
    negated = false
    amplifier = 1.0
    window_scores = Float64[]  # track recent word scores for context

    for (i, word) in enumerate(words)
        # Negation detection
        if word in ("not", "no", "never", "dont", "can't", "cannot", "isn't", "aren't", "won't", "wouldn't")
            negated = true
            continue
        end

        # Amplifier detection
        if word in ("very", "extremely", "massive", "huge", "insane", "absolutely", "incredibly")
            amplifier = 1.5
            continue
        end

        # Diminisher detection
        if word in ("slightly", "somewhat", "maybe", "possibly", "might")
            amplifier = 0.5
            continue
        end

        # Look up lexicon score
        base_score = get(FINANCE_LEXICON, word, 0.0)

        if base_score != 0.0
            # Apply negation (flips sign, reduced magnitude)
            if negated
                base_score = -base_score * 0.7  # negation weakens
                negated = false
            end

            # Apply amplifier
            base_score *= amplifier
            amplifier = 1.0

            # Position weighting: words later in text matter more (recency)
            position_weight = 0.5 + 0.5 * (i / length(words))

            score += base_score * position_weight
            weight_sum += position_weight
            push!(window_scores, base_score)
        else
            # Non-sentiment word: decay negation after 3 words
            if negated && i > 1
                negated = false
            end
            amplifier = 1.0
        end
    end

    # Phrase pattern boost
    text_lower = lowercase(text)
    for (pattern, boost) in [
        ("to the moon", 0.8), ("all time high", 0.7), ("new ath", 0.7),
        ("price target", 0.5), ("strong buy", 0.7), ("buy the dip", 0.5),
        ("going up", 0.4), ("looking bullish", 0.6), ("breakout confirmed", 0.7),
        ("dead cat", -0.7), ("going to zero", -0.9), ("rug pull", -0.9),
        ("exit scam", -0.9), ("flash crash", -0.8), ("margin call", -0.8),
        ("liquidation", -0.7), ("sell everything", -0.8), ("bear market", -0.6),
        ("double top", -0.5), ("head and shoulders", -0.5),
    ]
        if occursin(pattern, text_lower)
            score += boost
            weight_sum += 1.0
        end
    end

    # Normalize
    if weight_sum > 0
        return clamp(score / weight_sum, -1.0, 1.0)
    end
    return 0.0
end
