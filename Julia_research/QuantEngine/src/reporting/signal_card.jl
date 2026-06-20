# ── Visual Signal Card Generator ──────────────────────────────
# Produces clean SL/TP1/TP2 cards with direction, recommendations,
# and price levels — matching professional trading signal format.
# ANSI colors for terminal display.

# ANSI color codes
const ANSI_RED = "\e[91m"
const ANSI_GREEN = "\e[92m"
const ANSI_YELLOW = "\e[93m"
const ANSI_BLUE = "\e[94m"
const ANSI_CYAN = "\e[96m"
const ANSI_WHITE = "\e[97m"
const ANSI_BOLD = "\e[1m"
const ANSI_DIM = "\e[2m"
const ANSI_RESET = "\e[0m"
const ANSI_BG_RED = "\e[41m"
const ANSI_BG_GREEN = "\e[42m"

"""Signal card data extracted from analysis results."""
struct SignalCard
    ticker::String
    price::Float64
    direction::Symbol              # :long or :short
    stop_loss::Float64
    take_profit_1::Float64
    take_profit_2::Float64
    sl_pct::Float64
    tp1_pct::Float64
    tp2_pct::Float64
    confidence::Float64
    kelly_fraction::Float64
    size_dollars::Float64
    hold_hours::Float64
    risk_reward::Float64
    recommendations::Vector{String}
    model_consensus::String        # "BUY" / "SELL" / "HOLD"
    regime::String
    n_models_agree::Int
    n_models_total::Int
end

"""
    build_signal_card(ctx, composite, strategy; bankroll)

Build a signal card from analysis results. Extracts SL, TP1, TP2
from GARCH volatility forecasts and model confidence.
"""
function build_signal_card(ctx::AnalysisContext, composite::NamedTuple,
                            strategy::TradeStrategy; bankroll::Float64=10000.0)
    price = ctx.S0

    # Direction from composite
    direction = composite.score > 0 ? :long : :short

    # Extract GARCH volatility for SL/TP calculation
    garch_r = get(ctx.results, "14. EGARCH / GARCH Family", nothing)
    daily_vol = if garch_r isa NamedTuple && hasproperty(garch_r, :σ_annual_forecast)
        garch_r.σ_annual_forecast / sqrt(252)
    else
        std(ctx.returns[max(1,end-19):end])
    end

    # SL and TP from volatility
    hold_days = max(strategy.hold_time_hours / 24.0, 0.5)
    vol_move = daily_vol * sqrt(hold_days) * price

    if direction == :long
        stop_loss = price - vol_move * 1.0
        tp1 = price + vol_move * 1.5
        tp2 = price + vol_move * 2.5
    else
        stop_loss = price + vol_move * 1.0
        tp1 = price - vol_move * 1.5
        tp2 = price - vol_move * 2.5
    end

    sl_pct = (stop_loss - price) / price * 100
    tp1_pct = (tp1 - price) / price * 100
    tp2_pct = (tp2 - price) / price * 100
    rr = abs(tp1_pct / max(abs(sl_pct), 0.01))

    # Recommendations
    recs = String[]
    push!(recs, "$(uppercase(string(direction))) $(ctx.display_ticker) at \$$(round(price, digits=2))")
    push!(recs, "Position size: \$$(round(strategy.size_dollars, digits=0)) ($(round(strategy.size_fraction*100, digits=1))% of bankroll)")
    push!(recs, "Hold time: $(round(strategy.hold_time_hours, digits=0)) hours")
    push!(recs, "Risk/Reward: 1:$(round(rr, digits=1))")

    if composite.p_true > 0.60
        push!(recs, "Strong signal — high model consensus")
    elseif composite.p_true > 0.55
        push!(recs, "Moderate signal — proceed with caution")
    else
        push!(recs, "Weak signal — consider waiting for stronger setup")
    end

    # CVD check
    cvd_r = nothing
    for (k, v) in ctx.results
        if v isa NamedTuple && hasproperty(v, :divergence)
            cvd_r = v
            break
        end
    end
    if cvd_r !== nothing
        if cvd_r.divergence == :bullish_divergence && direction == :long
            push!(recs, "CVD confirms: hidden accumulation detected")
        elseif cvd_r.divergence == :bearish_divergence && direction == :short
            push!(recs, "CVD confirms: hidden distribution detected")
        elseif cvd_r.divergence == :bullish_divergence && direction == :short
            push!(recs, "⚠ CVD diverges: accumulation vs short signal")
        elseif cvd_r.divergence == :bearish_divergence && direction == :long
            push!(recs, "⚠ CVD diverges: distribution vs long signal")
        end
    end

    return SignalCard(
        ctx.display_ticker, price, direction,
        round(stop_loss, digits=2), round(tp1, digits=2), round(tp2, digits=2),
        round(sl_pct, digits=3), round(tp1_pct, digits=3), round(tp2_pct, digits=3),
        composite.confidence, strategy.size_fraction, strategy.size_dollars,
        strategy.hold_time_hours, round(rr, digits=2),
        recs, composite.direction, "—",
        composite.n_directional, composite.n_total
    )
end

"""
    print_signal_card(card; use_color)

Print a professional signal card to the terminal.
"""
function print_signal_card(card::SignalCard; use_color::Bool=true)
    c = use_color
    R = c ? ANSI_RESET : ""
    B = c ? ANSI_BOLD : ""
    DIM = c ? ANSI_DIM : ""

    dir_color = c ? (card.direction == :long ? ANSI_GREEN : ANSI_RED) : ""
    dir_bg = c ? (card.direction == :long ? ANSI_BG_GREEN : ANSI_BG_RED) : ""
    sl_color = c ? ANSI_RED : ""
    tp_color = c ? ANSI_GREEN : ""
    info_color = c ? ANSI_CYAN : ""

    dir_str = uppercase(string(card.direction))
    dir_label = card.direction == :long ? "LONG ▲" : "SHORT ▼"

    println()
    println("$(B)$(dir_color)╔══════════════════════════════════════════════════════════════════╗$(R)")
    println("$(B)$(dir_color)║$(R)  $(B)$(card.ticker)$(R) — $(dir_bg)$(B) $dir_label $(R)  Signal Price: $(B)\$$(card.price)$(R)")
    println("$(B)$(dir_color)╠══════════════════════════════════════════════════════════════════╣$(R)")

    # SL / TP1 / TP2 line
    sl_str = "$(sl_color)SL  \$$(lpad(string(card.stop_loss), 10)) ($(card.sl_pct > 0 ? "+" : "")$(card.sl_pct)%)$(R)"
    tp1_str = "$(tp_color)TP1 \$$(lpad(string(card.take_profit_1), 10)) ($(card.tp1_pct > 0 ? "+" : "")$(card.tp1_pct)%)$(R)"
    tp2_str = "$(tp_color)TP2 \$$(lpad(string(card.take_profit_2), 10)) ($(card.tp2_pct > 0 ? "+" : "")$(card.tp2_pct)%)$(R)"
    println("$(B)$(dir_color)║$(R)  $sl_str  $tp1_str  $tp2_str")

    println("$(B)$(dir_color)╠══════════════════════════════════════════════════════════════════╣$(R)")
    conf_str = "Confidence: $(round(Int, card.confidence))%   R:R: 1:$(card.risk_reward)   Kelly: $(round(card.kelly_fraction*100, digits=1))%   Hold: $(round(Int, card.hold_hours))h"
    println("$(B)$(dir_color)║$(R)  $conf_str")
    println("$(B)$(dir_color)║$(R)  Models: $(card.n_models_agree)/$(card.n_models_total) agree   Consensus: $(card.model_consensus)")

    println("$(B)$(dir_color)╠══════════════════════════════════════════════════════════════════╣$(R)")
    println("$(B)$(dir_color)║$(R)  $(B)Trade Recommendations:$(R)")
    for (i, rec) in enumerate(card.recommendations)
        println("$(B)$(dir_color)║$(R)  $(info_color)$i.$(R) $rec")
    end

    println("$(B)$(dir_color)╠══════════════════════════════════════════════════════════════════╣$(R)")
    println("$(B)$(dir_color)║$(R)  $(DIM)Direction: 34-model ensemble + L2 order-book + CVD divergence$(R)")
    println("$(B)$(dir_color)║$(R)  $(DIM)Sizing: cost-adjusted regime-aware Kelly × loss-averse throttle$(R)")
    println("$(B)$(dir_color)║$(R)  $(DIM)SL/TP: GARCH volatility forecast × sqrt(hold_days)$(R)")
    println("$(B)$(dir_color)╚══════════════════════════════════════════════════════════════════╝$(R)")
    println()
end
