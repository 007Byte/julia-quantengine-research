# ── Instrument Selector ───────────────────────────────────────
# Given pipeline outputs, ranks available instruments by suitability.

"""Build the complete instrument catalog."""
function build_catalog()::InstrumentCatalog
    InstrumentCatalog(
        build_polymarket_instruments(),
        build_crypto_instruments(),
        build_stock_instruments()
    )
end

# Module-level catalog (built once)
const INSTRUMENT_CATALOG = Ref{Union{InstrumentCatalog, Nothing}}(nothing)

function get_catalog()::InstrumentCatalog
    if INSTRUMENT_CATALOG[] === nothing
        INSTRUMENT_CATALOG[] = build_catalog()
    end
    return INSTRUMENT_CATALOG[]
end

"""
    select_instruments(asset_type, direction, confidence, ev_gap,
                       kelly_fraction, regime, kl_divergence) → Vector{ScoredInstrument}

Rank instruments by suitability for the given signal. Never recommends
instruments beyond the confidence threshold or risk profile.
"""
function select_instruments(asset_type::Symbol, direction::Symbol,
                            confidence::Float64, ev_gap::Float64,
                            kelly_fraction::Float64, regime::String,
                            kl_divergence::Float64)::Vector{ScoredInstrument}
    catalog = get_catalog()
    available = get_instruments(catalog, asset_type)
    scored = ScoredInstrument[]

    for inst in available
        score = 0.0
        reasons = String[]

        # Rule 1: Skip if confidence below instrument's minimum
        if confidence < inst.min_confidence
            continue
        end

        # Rule 2: Direction alignment
        if inst.direction == :long && direction == :buy
            score += 0.3
            push!(reasons, "direction aligned (bullish)")
        elseif inst.direction == :short && direction == :sell
            score += 0.3
            push!(reasons, "direction aligned (bearish)")
        elseif inst.direction == :neutral
            score += 0.15
            push!(reasons, "neutral instrument")
        else
            score -= 0.2  # direction mismatch
        end

        # Rule 3: Leverage appropriateness
        if confidence > 80.0 && ev_gap > 0.10
            # High confidence + high EV → leverage OK
            score += inst.leverage > 1.0 ? 0.15 : 0.05
            push!(reasons, "high conf+EV: leverage appropriate")
        elseif confidence < 60.0
            # Low confidence → penalize leverage
            if inst.leverage > 1.0
                score -= 0.3
                push!(reasons, "low confidence: leverage penalized")
            else
                score += 0.2
                push!(reasons, "low confidence: simple instrument preferred")
            end
        end

        # Rule 4: Kelly fraction sizing
        if kelly_fraction < 0.10
            # Small position → simple instruments only
            if inst.complexity <= 1
                score += 0.15
            else
                score -= 0.1
            end
        elseif kelly_fraction > 0.30
            # Large position → defined risk preferred
            if inst.max_loss_pct <= 100.0 && !inst.requires_margin
                score += 0.1
                push!(reasons, "defined risk for large position")
            end
        end

        # Rule 5: KL divergence → hedge instruments
        if kl_divergence > 0.2 && inst.direction == :neutral
            score += 0.2
            push!(reasons, "high KL divergence: hedge recommended")
        end

        # Rule 6: Regime alignment
        if occursin("volatile", lowercase(regime))
            if inst.name in (:straddle, :strangle, :crypto_straddle)
                score += 0.25
                push!(reasons, "volatile regime: vol play")
            end
        elseif occursin("trending", lowercase(regime))
            if inst.direction != :neutral
                score += 0.1
                push!(reasons, "trending regime: directional play")
            end
        elseif occursin("mean-revert", lowercase(regime))
            if inst.direction == :neutral || inst.name in (:iron_condor, :covered_call)
                score += 0.15
                push!(reasons, "mean-reverting: range-bound play")
            end
        end

        # Rule 7: Simplicity bonus (prefer simpler instruments)
        score += (4 - inst.complexity) * 0.05

        # Rule 8: NEVER recommend uncapped loss instruments for automated trading
        if inst.max_loss_pct > 100.0
            score -= 0.4
            push!(reasons, "WARNING: uncapped loss potential")
        end

        # Rule 9: Margin requirement penalty for conservative profiles
        if inst.requires_margin
            score -= 0.05
        end

        # Clamp score
        score = clamp(score, 0.0, 1.0)

        if score > 0.1  # minimum viability threshold
            rationale = isempty(reasons) ? "baseline score" : join(reasons, "; ")
            push!(scored, ScoredInstrument(inst, score, rationale))
        end
    end

    # Sort descending by score
    sort!(scored, by=s -> s.score, rev=true)
    return scored
end
