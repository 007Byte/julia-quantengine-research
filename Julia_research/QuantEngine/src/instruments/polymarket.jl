# ── Polymarket Instruments ────────────────────────────────────

function build_polymarket_instruments()::Vector{Instrument}
    [
        Instrument(:binary_yes, "Binary YES", :polymarket, :long, 1.0, 100.0,
            false, true, 1, 50.0,
            "Buy YES shares — profit if event resolves YES. Max loss = stake."),

        Instrument(:binary_no, "Binary NO", :polymarket, :short, 1.0, 100.0,
            false, true, 1, 50.0,
            "Buy NO shares — profit if event resolves NO. Max loss = stake."),

        Instrument(:multi_outcome, "Multi-Outcome", :polymarket, :long, 1.0, 100.0,
            false, true, 2, 55.0,
            "Buy shares in one outcome of a multi-outcome market. Max loss = stake."),

        Instrument(:parlay, "Parlay", :polymarket, :long, 1.0, 100.0,
            false, true, 3, 65.0,
            "Combine 2+ correlated bets. Multiplied odds but all must win. Higher EV required."),

        Instrument(:hedge_pair, "Hedge Pair", :polymarket, :neutral, 1.0, 50.0,
            false, true, 3, 60.0,
            "Buy YES on market A + NO on market B. Reduces risk when markets are correlated."),
    ]
end
