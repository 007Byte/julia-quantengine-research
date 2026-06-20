# ── Trade Instrument Types ────────────────────────────────────

"""Defines a single tradeable instrument and its properties."""
struct Instrument
    name::Symbol                    # :spot_buy, :call_option, :parlay, etc.
    display_name::String            # "Spot Buy", "Call Option", etc.
    platform::Symbol                # :polymarket, :crypto, :stock
    direction::Symbol               # :long, :short, :neutral
    leverage::Float64               # 1.0 for spot, 2-100x for derivatives
    max_loss_pct::Float64           # max loss as % of position (100 = total loss)
    requires_margin::Bool
    time_bounded::Bool              # true for options/polymarket (has expiry)
    complexity::Int                 # 1=simple, 2=intermediate, 3=advanced
    min_confidence::Float64         # minimum confidence to use this instrument (0-100)
    description::String
end

"""Scored instrument recommendation."""
struct ScoredInstrument
    instrument::Instrument
    score::Float64                  # 0.0 to 1.0 suitability
    rationale::String
end

"""Complete catalog of all instruments across all platforms."""
struct InstrumentCatalog
    polymarket::Vector{Instrument}
    crypto::Vector{Instrument}
    stocks::Vector{Instrument}
end

"""Get instruments for a specific platform."""
function get_instruments(catalog::InstrumentCatalog, platform::Symbol)::Vector{Instrument}
    if platform == :polymarket
        return catalog.polymarket
    elseif platform == :crypto
        return catalog.crypto
    elseif platform == :stock
        return catalog.stocks
    else
        error("Unknown platform: $platform")
    end
end
