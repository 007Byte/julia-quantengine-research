# ── Crypto Instruments ────────────────────────────────────────

function build_crypto_instruments()::Vector{Instrument}
    [
        Instrument(:spot_buy, "Spot Buy", :crypto, :long, 1.0, 100.0,
            false, false, 1, 50.0,
            "Buy crypto at current price. No leverage, no expiry. Loss = price decline."),

        Instrument(:spot_sell, "Spot Sell", :crypto, :short, 1.0, 100.0,
            false, false, 1, 50.0,
            "Sell existing crypto position. Realize PnL."),

        Instrument(:limit_buy, "Limit Buy", :crypto, :long, 1.0, 100.0,
            false, false, 1, 50.0,
            "Place buy order at target price. May not fill. Better entry if patient."),

        Instrument(:stop_loss, "Stop-Loss", :crypto, :neutral, 1.0, 100.0,
            false, false, 1, 0.0,
            "Automatic sell if price drops to level. Protects existing position."),

        Instrument(:futures_long, "Futures Long", :crypto, :long, 10.0, 100.0,
            true, true, 2, 70.0,
            "Leveraged long position (2-20x). Liquidation risk. Requires margin."),

        Instrument(:futures_short, "Futures Short", :crypto, :short, 10.0, 100.0,
            true, true, 2, 70.0,
            "Leveraged short position (2-20x). Liquidation risk if price rises."),

        Instrument(:perpetual_swap, "Perpetual Swap", :crypto, :long, 20.0, 100.0,
            true, false, 2, 70.0,
            "Like futures but no expiry. Funding rate cost. Up to 100x leverage."),

        Instrument(:crypto_call, "Call Option", :crypto, :long, 5.0, 100.0,
            false, true, 3, 65.0,
            "Right to buy at strike price. Max loss = premium. Defined risk."),

        Instrument(:crypto_put, "Put Option", :crypto, :short, 5.0, 100.0,
            false, true, 3, 65.0,
            "Right to sell at strike price. Max loss = premium. Hedge or bearish bet."),

        Instrument(:crypto_straddle, "Straddle", :crypto, :neutral, 3.0, 100.0,
            false, true, 3, 60.0,
            "Buy call + put at same strike. Profit from large move in either direction."),
    ]
end
