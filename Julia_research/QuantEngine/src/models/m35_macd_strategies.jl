# ── MACD Strategy Suite (Model 35) ────────────────────────────
# Multiple MACD configurations that can be tested independently.
# Each produces a directional signal with confidence.
# The strategy lab tests all configs and learns which work.

"""MACD configuration with named parameters."""
struct MACDConfig
    name::String
    fast::Int          # fast EMA period
    slow::Int          # slow EMA period
    signal::Int        # signal line EMA period
    threshold::Float64 # histogram threshold for entry (0 = any crossover)
end

"""Result from a MACD strategy evaluation."""
struct MACDSignal
    config::MACDConfig
    direction::Symbol      # :buy, :sell, :hold
    macd_line::Float64
    signal_line::Float64
    histogram::Float64
    histogram_slope::Float64  # momentum of histogram
    confidence::Float64       # 0-100
    p_true::Float64          # probability of profitable trade
end

# ── Pre-defined MACD configurations to test ──────────────────
const MACD_CONFIGS = [
    MACDConfig("MACD-Classic",   12, 26, 9, 0.0),
    MACDConfig("MACD-9/15/3",     9, 15, 3, 0.0),
    MACDConfig("MACD-4/16/3",     4, 16, 3, 0.0),
    MACDConfig("MACD-6/20/15",    6, 20, 15, 50.0),
    MACDConfig("MACD-Fast",       5, 13, 6, 0.0),
    MACDConfig("MACD-Slow",      19, 39, 9, 0.0),
    MACDConfig("MACD-Tight",      3,  10, 3, 0.0),
    MACDConfig("MACD-Scalp",      2,   8, 3, 0.0),
    MACDConfig("MACD-Swing",     12, 26, 9, 0.5),  # only enter when histogram > 0.5
    MACDConfig("MACD-Momentum",   8, 21, 5, 0.0),
]

"""Compute EMA (Exponential Moving Average) of a price series."""
function _ema(prices::Vector{Float64}, period::Int)::Vector{Float64}
    n = length(prices)
    result = similar(prices)
    if n == 0 return result end
    alpha = 2.0 / (period + 1)
    result[1] = prices[1]
    for i in 2:n
        result[i] = alpha * prices[i] + (1 - alpha) * result[i-1]
    end
    return result
end

"""
    compute_macd(prices, config) → (macd_line, signal_line, histogram)

Compute MACD indicator for given prices and configuration.
"""
function compute_macd(prices::Vector{Float64}, config::MACDConfig)
    fast_ema = _ema(prices, config.fast)
    slow_ema = _ema(prices, config.slow)
    macd_line = fast_ema .- slow_ema
    signal_line = _ema(macd_line, config.signal)
    histogram = macd_line .- signal_line
    return (macd_line=macd_line, signal_line=signal_line, histogram=histogram)
end

"""
    evaluate_macd(prices, config) → MACDSignal

Evaluate a single MACD configuration on price data and produce a trading signal.
"""
function evaluate_macd(prices::Vector{Float64}, config::MACDConfig)::MACDSignal
    n = length(prices)
    if n < config.slow + config.signal + 5
        return MACDSignal(config, :hold, 0.0, 0.0, 0.0, 0.0, 0.0, 0.5)
    end

    m = compute_macd(prices, config)

    # Current values
    macd_now = m.macd_line[end]
    signal_now = m.signal_line[end]
    hist_now = m.histogram[end]
    hist_prev = n > 1 ? m.histogram[end-1] : hist_now
    hist_slope = hist_now - hist_prev

    # Determine direction based on multiple signals
    signals_bullish = 0
    signals_bearish = 0
    total_signals = 0

    # Signal 1: MACD line above/below signal line
    total_signals += 1
    if macd_now > signal_now
        signals_bullish += 1
    elseif macd_now < signal_now
        signals_bearish += 1
    end

    # Signal 2: Histogram positive/negative (with threshold)
    total_signals += 1
    if hist_now > config.threshold
        signals_bullish += 1
    elseif hist_now < -config.threshold
        signals_bearish += 1
    end

    # Signal 3: Histogram slope (momentum)
    total_signals += 1
    if hist_slope > 0
        signals_bullish += 1
    elseif hist_slope < 0
        signals_bearish += 1
    end

    # Signal 4: MACD line crossover (just crossed)
    total_signals += 1
    macd_prev = n > 1 ? m.macd_line[end-1] : macd_now
    signal_prev = n > 1 ? m.signal_line[end-1] : signal_now
    if macd_prev <= signal_prev && macd_now > signal_now  # bullish crossover
        signals_bullish += 2  # extra weight for fresh crossover
        total_signals += 1
    elseif macd_prev >= signal_prev && macd_now < signal_now  # bearish crossover
        signals_bearish += 2
        total_signals += 1
    end

    # Signal 5: Price trend confirmation (20-bar)
    total_signals += 1
    if n >= 20
        price_trend = (prices[end] - prices[end-19]) / prices[end-19]
        if price_trend > 0.01
            signals_bullish += 1
        elseif price_trend < -0.01
            signals_bearish += 1
        end
    end

    # Calculate confidence and direction
    bull_pct = signals_bullish / max(total_signals, 1)
    bear_pct = signals_bearish / max(total_signals, 1)

    direction = if bull_pct >= 0.6
        :buy
    elseif bear_pct >= 0.6
        :sell
    else
        :hold
    end

    confidence = max(bull_pct, bear_pct) * 100.0
    p_true = direction == :buy ? 0.5 + bull_pct * 0.3 :
             direction == :sell ? 0.5 + bear_pct * 0.3 : 0.5

    return MACDSignal(config, direction, macd_now, signal_now, hist_now,
                      hist_slope, confidence, p_true)
end

"""
    evaluate_all_macd(prices; configs) → Vector{MACDSignal}

Evaluate all MACD configurations and return ranked signals.
"""
function evaluate_all_macd(prices::Vector{Float64};
                            configs::Vector{MACDConfig}=MACD_CONFIGS)
    signals = MACDSignal[]
    for config in configs
        sig = evaluate_macd(prices, config)
        push!(signals, sig)
    end
    # Sort by confidence (highest first)
    sort!(signals, by=s -> s.confidence, rev=true)
    return signals
end

"""
    macd_consensus(signals) → (direction, confidence, agreement_pct)

Find consensus across multiple MACD configurations.
"""
function macd_consensus(signals::Vector{MACDSignal})
    n = length(signals)
    if n == 0
        return (direction=:hold, confidence=0.0, agreement_pct=0.0, best_config="none")
    end

    buy_count = count(s -> s.direction == :buy, signals)
    sell_count = count(s -> s.direction == :sell, signals)
    hold_count = count(s -> s.direction == :hold, signals)

    if buy_count > sell_count && buy_count > hold_count
        direction = :buy
        agreement = buy_count / n
    elseif sell_count > buy_count && sell_count > hold_count
        direction = :sell
        agreement = sell_count / n
    else
        direction = :hold
        agreement = hold_count / n
    end

    # Average confidence of agreeing signals
    agreeing = filter(s -> s.direction == direction, signals)
    avg_conf = isempty(agreeing) ? 0.0 : mean(s.confidence for s in agreeing)
    best = isempty(agreeing) ? signals[1] : agreeing[1]

    return (direction=direction, confidence=avg_conf, agreement_pct=agreement * 100,
            best_config=best.config.name)
end
