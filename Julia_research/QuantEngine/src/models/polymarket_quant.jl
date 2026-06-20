# ── Polymarket Professional Quant Layer ───────────────────────
# Implements the full professional prediction market trading stack:
#   1. Logit-based edge calculation (symmetric near 0 and 1)
#   2. Fee-aware net EV (bid/ask, not midpoint)
#   3. Favorite-longshot bias calibration
#   4. Bayesian blend (model vs market, liquidity-weighted)
#   5. Binary Kelly for $1/$0 contracts
#   6. Fee-zone filtering (50¢ zone is worst)
#   7. Historical calibration table
#   8. Trade signal generation with all frictions

const EPS_PROB = 1e-9

# ── Core Math ─────────────────────────────────────────────────

"""Clamp probability to (0, 1) exclusive."""
clip01(x::Float64) = clamp(x, EPS_PROB, 1.0 - EPS_PROB)

"""Log-odds transform. Symmetric, handles tails properly."""
logit(x::Float64) = log(clip01(x) / (1.0 - clip01(x)))

"""Inverse logit (sigmoid)."""
inv_logit(z::Float64) = 1.0 / (1.0 + exp(-clamp(z, -500.0, 500.0)))

# ── Market Quote ──────────────────────────────────────────────

"""Full order-book quote from a prediction market."""
struct PolyQuote
    slug::String
    yes_bid::Float64           # best bid for YES
    yes_ask::Float64           # best ask for YES
    midpoint::Float64          # (bid + ask) / 2
    spread::Float64            # ask - bid
    volume::Float64            # 24h volume
    fee_buy::Float64           # taker fee for buying YES
    fee_sell::Float64          # taker fee for selling YES
end

function PolyQuote(slug::String, yes_bid::Float64, yes_ask::Float64;
                    volume::Float64=0.0)
    mid = (yes_bid + yes_ask) / 2.0
    spread = yes_ask - yes_bid
    # Polymarket fee schedule: peaks at 50¢, falls toward extremes
    fee_buy = _polymarket_fee(yes_ask)
    fee_sell = _polymarket_fee(yes_bid)
    PolyQuote(slug, yes_bid, yes_ask, mid, spread, volume, fee_buy, fee_sell)
end

"""Polymarket fee schedule: higher near 50¢, lower near extremes."""
function _polymarket_fee(price::Float64)::Float64
    p = clip01(price)
    # Approximate fee curve: max ~1.5% at 50¢, ~0% at extremes
    # Based on documented Polymarket fee schedule
    base_rate = 0.02  # 2% base
    # Scale by how close to 50¢ (fee is proportional to p*(1-p))
    return base_rate * 4.0 * p * (1.0 - p)
end

# ── Model Inputs ──────────────────────────────────────────────

"""Inputs for the fair probability estimator."""
struct PolyModelInputs
    base_prob::Float64         # external/statistical model probability
    market_mid::Float64        # current market midpoint
    liquidity_score::Float64   # 0-1: higher = trust market more
    recency_score::Float64     # 0-1: higher = trust model more
    category_bias::Float64     # learned bias correction (longshot penalty)
end

# ── Bayesian Blend ────────────────────────────────────────────

"""
    bayesian_blend(base_prob, market_prob; k_model, k_market)

Shrink model probability toward market probability in logit space.
k_model > k_market → trust model more.
k_model < k_market → trust market more.
"""
function bayesian_blend(base_prob::Float64, market_prob::Float64;
                         k_model::Float64=2.0, k_market::Float64=1.0)
    z = (k_model * logit(base_prob) + k_market * logit(market_prob)) /
        (k_model + k_market)
    return clip01(inv_logit(z))
end

# ── Calibration Layer ─────────────────────────────────────────

"""
    calibrate_probability(raw_p, category_bias)

Apply learned calibration adjustment in logit space.
Positive bias pushes probabilities up, negative pushes down.
Used for favorite-longshot bias correction by category.
"""
function calibrate_probability(raw_p::Float64, category_bias::Float64)
    z = logit(raw_p) + category_bias
    return clip01(inv_logit(z))
end

# ── Fair Probability Estimator ────────────────────────────────

"""
    estimate_fair_probability(inputs)

Professional-style fair probability estimation:
1. Blend external model with market prior (liquidity-weighted)
2. Trust market more when liquidity is high
3. Trust model more when market is thin/stale
4. Apply category calibration correction
"""
function estimate_fair_probability(inputs::PolyModelInputs)
    # Liquidity-adaptive weights
    k_market = 1.0 + 4.0 * inputs.liquidity_score
    k_model = 2.0 + 3.0 * inputs.recency_score

    blended = bayesian_blend(inputs.base_prob, inputs.market_mid;
                              k_model=k_model, k_market=k_market)

    calibrated = calibrate_probability(blended, inputs.category_bias)
    return clip01(calibrated)
end

# ── Fee-Aware Edge Calculation ────────────────────────────────

"""Break-even probability for buying YES at ask price."""
break_even_buy(ask::Float64, fee::Float64) = clip01(ask + fee)

"""Break-even probability for selling YES at bid price."""
break_even_sell(bid::Float64, fee::Float64) = clip01(bid - fee)

"""Net EV per share for buying YES."""
buy_ev(fair_prob::Float64, ask::Float64, fee::Float64) =
    fair_prob - ask - fee

"""Net EV per share for selling YES (or buying NO)."""
sell_ev(fair_prob::Float64, bid::Float64, fee::Float64) =
    bid - fair_prob - fee

"""Logit-space edge (symmetric, proper scaling near 0 and 1)."""
function logit_edge(fair_prob::Float64, market_prob::Float64)
    logit(fair_prob) - logit(market_prob)
end

# ── Binary Kelly for Prediction Markets ───────────────────────

"""
    binary_kelly(fair_prob, all_in_cost)

Kelly fraction for a binary contract paying \$1 on win, \$0 on loss.
Profit if win = 1 - cost. Loss if lose = cost.
f* = (p - cost) / (1 - cost)
"""
function binary_kelly(fair_prob::Float64, all_in_cost::Float64)
    p = clip01(fair_prob)
    c = clamp(all_in_cost, EPS_PROB, 1.0 - EPS_PROB)
    edge = p - c
    if edge <= 0.0
        return 0.0
    end
    return clamp(edge / (1.0 - c), 0.0, 1.0)
end

# ── Fee Zone Filter ───────────────────────────────────────────

"""
    fee_zone_quality(price) → Float64

Score from 0 (worst fee zone) to 1 (best fee zone).
The 45-55¢ zone has the highest fees and worst risk/reward.
Tails (< 20¢ or > 80¢) have lowest fees.
"""
function fee_zone_quality(price::Float64)
    p = clip01(price)
    # Fee is proportional to p*(1-p), which peaks at 0.5
    # Quality is inverse: best near 0 or 1
    return 1.0 - 4.0 * p * (1.0 - p)
end

# ── Historical Calibration Table ──────────────────────────────

"""Calibration bucket for tracking prediction accuracy."""
mutable struct CalibrationBucket
    bucket_low::Float64        # e.g., 0.0
    bucket_high::Float64       # e.g., 0.1
    n_predictions::Int
    n_resolved_yes::Int
    predicted_sum::Float64     # sum of predicted probabilities
    lock::ReentrantLock
end

"""Collection of calibration buckets."""
mutable struct CalibrationTable
    buckets::Vector{CalibrationBucket}
    lock::ReentrantLock
end

"""Create a calibration table with 10 buckets (0-10%, 10-20%, ..., 90-100%)."""
function CalibrationTable(; n_buckets::Int=10)
    width = 1.0 / n_buckets
    buckets = [CalibrationBucket(i * width, (i + 1) * width, 0, 0, 0.0, ReentrantLock())
               for i in 0:(n_buckets-1)]
    CalibrationTable(buckets, ReentrantLock())
end

"""Record a prediction and its outcome (thread-safe)."""
function record_prediction!(table::CalibrationTable, predicted_prob::Float64,
                              resolved_yes::Bool)
    p = clip01(predicted_prob)
    lock(table.lock) do
        for bucket in table.buckets
            if p >= bucket.bucket_low && p < bucket.bucket_high
                lock(bucket.lock) do
                    bucket.n_predictions += 1
                    bucket.predicted_sum += p
                    if resolved_yes
                        bucket.n_resolved_yes += 1
                    end
                end
                break
            end
        end
    end
end

"""Get calibration report: predicted vs actual frequency per bucket."""
function calibration_report(table::CalibrationTable)
    report = NamedTuple[]
    lock(table.lock) do
        for b in table.buckets
            lock(b.lock) do
                n = b.n_predictions
                if n > 0
                    avg_predicted = b.predicted_sum / n
                    actual_freq = b.n_resolved_yes / n
                    bias = actual_freq - avg_predicted
                    push!(report, (range="$(round(b.bucket_low*100))%-$(round(b.bucket_high*100))%",
                                   n=n,
                                   avg_predicted=round(avg_predicted, digits=3),
                                   actual_freq=round(actual_freq, digits=3),
                                   bias=round(bias, digits=3)))
                end
            end
        end
    end
    return report
end

"""Derive category bias from calibration table (for a specific probability range)."""
function derive_bias(table::CalibrationTable, probability::Float64)::Float64
    p = clip01(probability)
    bias_val = Ref(0.0)
    lock(table.lock) do
        for b in table.buckets
            if p >= b.bucket_low && p < b.bucket_high
                n = b.n_predictions
                if n >= 10
                    avg_predicted = b.predicted_sum / n
                    actual_freq = b.n_resolved_yes / n
                    bias_val[] = logit(clip01(actual_freq)) - logit(clip01(avg_predicted))
                end
                break
            end
        end
    end
    return bias_val[]
end

# ── Trade Signal Generator ────────────────────────────────────

"""Complete trade signal with all frictions accounted for."""
struct PolyTradeSignal
    slug::String
    fair_prob::Float64
    market_prob::Float64
    buy_ev_val::Float64
    sell_ev_val::Float64
    logit_edge_val::Float64
    fee_buy::Float64
    fee_sell::Float64
    fee_zone::Float64          # 0=worst, 1=best
    action::Symbol             # :buy_yes, :sell_yes, :no_trade
    size_fraction::Float64     # Kelly-based position size
    break_even::Float64        # break-even probability
end

"""
    generate_poly_signal(quote, inputs; kelly_fraction, min_edge, cal_table)

Full professional signal generation:
1. Estimate fair probability (Bayesian blend + calibration)
2. Compute fee-aware net EV for buy and sell
3. Apply fee-zone filter
4. Size with binary Kelly
5. Return actionable signal
"""
function generate_poly_signal(mkt_quote::PolyQuote, inputs::PolyModelInputs;
                               kelly_fraction::Float64=0.25,
                               min_edge::Float64=0.01,
                               cal_table::Union{CalibrationTable, Nothing}=nothing)
    # Apply historical calibration bias if available
    adjusted_inputs = if cal_table !== nothing
        bias = derive_bias(cal_table, inputs.base_prob)
        PolyModelInputs(inputs.base_prob, inputs.market_mid,
                         inputs.liquidity_score, inputs.recency_score,
                         inputs.category_bias + bias)
    else
        inputs
    end

    fair_prob = estimate_fair_probability(adjusted_inputs)

    # Fee-aware EV
    bev = buy_ev(fair_prob, mkt_quote.yes_ask, mkt_quote.fee_buy)
    sev = sell_ev(fair_prob, mkt_quote.yes_bid, mkt_quote.fee_sell)

    # Logit-space edge
    le = logit_edge(fair_prob, mkt_quote.midpoint)

    # Fee zone quality
    fz = fee_zone_quality(mkt_quote.midpoint)

    # Determine action
    if bev > min_edge && bev >= sev
        all_in_cost = mkt_quote.yes_ask + mkt_quote.fee_buy
        kelly = binary_kelly(fair_prob, all_in_cost)
        size_frac = kelly_fraction * kelly
        be = break_even_buy(mkt_quote.yes_ask, mkt_quote.fee_buy)
        action = :buy_yes
    elseif sev > min_edge
        no_cost = (1.0 - mkt_quote.yes_bid) + mkt_quote.fee_sell
        fair_no = 1.0 - fair_prob
        kelly = binary_kelly(fair_no, no_cost)
        size_frac = kelly_fraction * kelly
        be = break_even_sell(mkt_quote.yes_bid, mkt_quote.fee_sell)
        action = :sell_yes
    else
        size_frac = 0.0
        be = break_even_buy(mkt_quote.yes_ask, mkt_quote.fee_buy)
        action = :no_trade
    end

    return PolyTradeSignal(mkt_quote.slug, fair_prob, mkt_quote.midpoint,
                            bev, sev, le, mkt_quote.fee_buy, mkt_quote.fee_sell, fz,
                            action, size_frac, be)
end

"""Check if a YES contract is overpriced for buyer (instant screener)."""
is_overpriced_for_buyer(model_prob::Float64, ask::Float64, fee::Float64;
                         threshold::Float64=0.0) =
    model_prob < ask + fee + threshold

"""Check if a YES contract is underpriced for buyer (instant screener)."""
is_underpriced_for_buyer(model_prob::Float64, ask::Float64, fee::Float64;
                          threshold::Float64=0.0) =
    model_prob > ask + fee + threshold

"""Print a formatted trade signal."""
function print_poly_signal(signal::PolyTradeSignal)
    action_str = signal.action == :buy_yes ? "BUY YES" :
                 signal.action == :sell_yes ? "SELL YES (BUY NO)" : "NO TRADE"
    @printf("  %-30s | Fair: %.3f | Mkt: %.3f | Edge: %+.4f | EV: %+.4f | %s | Size: %.1f%%\n",
            signal.slug, signal.fair_prob, signal.market_prob,
            signal.logit_edge_val, max(signal.buy_ev_val, signal.sell_ev_val),
            action_str, signal.size_fraction * 100)
end
