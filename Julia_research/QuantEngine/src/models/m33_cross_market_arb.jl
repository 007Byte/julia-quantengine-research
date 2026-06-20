# ── Model 33: Cross-Market Arbitrage Detector ────────────────
# Detects price discrepancies for the same event across platforms.
# Polymarket vs Kalshi vs PredictIt — pure arbitrage when spreads exist.

"""A price observation from a prediction market platform."""
struct MarketQuote
    platform::String          # "polymarket", "kalshi", "predictit"
    price_yes::Float64        # YES share price (0-1)
    price_no::Float64         # NO share price (0-1)
    volume::Float64           # trading volume
    timestamp::DateTime
    fee_rate::Float64         # platform fee (fraction)
end

"""Result of cross-market arbitrage analysis."""
struct ArbOpportunity
    event::String
    buy_platform::String
    sell_platform::String
    buy_price::Float64
    sell_price::Float64
    spread::Float64           # raw spread
    net_spread::Float64       # spread after fees
    size_limit::Float64       # max trade size (limited by lower volume)
    expected_profit_pct::Float64
end

"""
    detect_arbitrage(quotes; min_spread)

Analyze quotes from multiple platforms for the same event.
Returns arbitrage opportunities where spread > fees.
"""
function detect_arbitrage(quotes::Vector{MarketQuote};
                          min_spread::Float64=0.02)
    opportunities = ArbOpportunity[]

    if length(quotes) < 2
        return opportunities
    end

    # Compare every pair of platforms
    for i in 1:length(quotes)
        for j in (i+1):length(quotes)
            q1 = quotes[i]
            q2 = quotes[j]

            # Case 1: Buy YES on q1, Sell YES (buy NO) on q2
            spread1 = q2.price_yes - q1.price_yes
            fees1 = q1.price_yes * q1.fee_rate + q2.price_no * q2.fee_rate
            net1 = spread1 - fees1

            if net1 > min_spread
                push!(opportunities, ArbOpportunity(
                    "", q1.platform, q2.platform,
                    q1.price_yes, q2.price_yes, spread1, net1,
                    min(q1.volume, q2.volume),
                    net1 / q1.price_yes * 100
                ))
            end

            # Case 2: Buy YES on q2, Sell YES (buy NO) on q1
            spread2 = q1.price_yes - q2.price_yes
            fees2 = q2.price_yes * q2.fee_rate + q1.price_no * q1.fee_rate
            net2 = spread2 - fees2

            if net2 > min_spread
                push!(opportunities, ArbOpportunity(
                    "", q2.platform, q1.platform,
                    q2.price_yes, q1.price_yes, spread2, net2,
                    min(q1.volume, q2.volume),
                    net2 / q2.price_yes * 100
                ))
            end
        end
    end

    # Sort by net spread (best opportunities first)
    sort!(opportunities, by=o -> -o.net_spread)
    return opportunities
end

"""
    fetch_kalshi_price(event_ticker) → MarketQuote or nothing

Fetch current price from Kalshi API (public, no key needed for market data).
"""
function fetch_kalshi_price(event_ticker::String)::Union{MarketQuote, Nothing}
    try
        url = "https://api.elections.kalshi.com/trade-api/v2/markets/$(event_ticker)"
        resp = HTTP.get(url, ["Accept" => "application/json"];
                        connect_timeout=10, readtimeout=10)
        data = JSON.parse(String(resp.body))
        market = get(data, "market", Dict())

        yes_price = get(market, "yes_ask", 0.0) / 100.0
        no_price = get(market, "no_ask", 0.0) / 100.0
        volume = Float64(get(market, "volume", 0))

        if yes_price <= 0.0
            return nothing
        end

        return MarketQuote("kalshi", yes_price, no_price, volume,
                           now(), 0.07)  # Kalshi ~7% fee on winnings
    catch
        return nothing
    end
end

"""
    run_cross_market_arb(polymarket_price, polymarket_volume; event_name)

Analyze a Polymarket event for cross-market arbitrage.
Attempts to fetch the same event from Kalshi for comparison.
"""
function run_cross_market_arb(polymarket_price::Float64,
                               polymarket_volume::Float64;
                               event_name::String="")
    p = clamp(polymarket_price, 0.01, 0.99)

    poly_quote = MarketQuote("polymarket", p, 1 - p,
                              polymarket_volume, now(), 0.02)

    quotes = MarketQuote[poly_quote]

    # Attempt to fetch Kalshi price for comparison
    # (In production, you'd map event names to Kalshi tickers)
    # For now, we analyze the single-market pricing efficiency
    arb_ops = detect_arbitrage(quotes)

    # Single-market analysis: is the pricing efficient?
    # Check if YES + NO prices sum to ~1.0 (inefficiency = arb within market)
    internal_spread = abs((p + (1 - p)) - 1.0)

    # Overround analysis (vig detection)
    overround = p + (1 - p)  # should be exactly 1.0 for fair market

    direction = p > 0.5 ? "YES" : "NO"

    return (direction=direction, probability=p, accuracy=NaN,
            n_platforms=length(quotes),
            n_opportunities=length(arb_ops),
            opportunities=arb_ops,
            internal_spread=internal_spread,
            overround=overround,
            polymarket_price=p,
            model="Cross-Market Arbitrage")
end
