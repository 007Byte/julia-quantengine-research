# ── Stock Instruments ─────────────────────────────────────────

function build_stock_instruments()::Vector{Instrument}
    [
        Instrument(:equity_buy, "Equity Buy", :stock, :long, 1.0, 100.0,
            false, false, 1, 50.0,
            "Buy shares at market/limit price. No expiry. Loss = price decline."),

        Instrument(:equity_short, "Equity Short", :stock, :short, 1.0, 150.0,
            true, false, 2, 70.0,
            "Short sell shares. Unlimited upside risk. Requires margin account."),

        Instrument(:call_option, "Call Option (Long)", :stock, :long, 10.0, 100.0,
            false, true, 2, 60.0,
            "Right to buy at strike. Leveraged upside. Max loss = premium paid."),

        Instrument(:put_option, "Put Option (Long)", :stock, :short, 10.0, 100.0,
            false, true, 2, 60.0,
            "Right to sell at strike. Leveraged downside. Max loss = premium paid."),

        Instrument(:covered_call, "Covered Call", :stock, :neutral, 1.0, 100.0,
            false, true, 2, 55.0,
            "Hold stock + sell call above. Income strategy. Caps upside."),

        Instrument(:protective_put, "Protective Put", :stock, :neutral, 1.0, 100.0,
            false, true, 2, 50.0,
            "Hold stock + buy put below. Insurance against decline. Costs premium."),

        Instrument(:bull_call_spread, "Bull Call Spread", :stock, :long, 3.0, 100.0,
            false, true, 3, 60.0,
            "Buy lower strike call + sell higher strike call. Capped risk and reward."),

        Instrument(:bear_put_spread, "Bear Put Spread", :stock, :short, 3.0, 100.0,
            false, true, 3, 60.0,
            "Buy higher strike put + sell lower strike put. Capped risk and reward."),

        Instrument(:iron_condor, "Iron Condor", :stock, :neutral, 2.0, 100.0,
            false, true, 3, 55.0,
            "Sell OTM call spread + put spread. Profit if price stays in range. Low vol play."),

        Instrument(:straddle, "Straddle", :stock, :neutral, 5.0, 100.0,
            false, true, 3, 60.0,
            "Buy ATM call + put. Profit from large move in either direction. High vol play."),

        Instrument(:strangle, "Strangle", :stock, :neutral, 4.0, 100.0,
            false, true, 3, 60.0,
            "Buy OTM call + put. Cheaper than straddle. Needs bigger move to profit."),
    ]
end
