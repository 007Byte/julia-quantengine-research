# ── Model 16: LMSR Pricing Model ────────────────────────────
# Formula: Price_i = e^(q_i/b) / Σ_j e^(q_j/b)
# Edge: Spot mispricings in thin pools

function run_lmsr(market_price; b=100.0, trade_size=10.0)
    # For binary market: outcomes = [Yes, No]
    # Convert market price to implied quantities
    p = clamp(market_price, 0.01, 0.99)

    # Derive q from price: p = e^(q1/b) / (e^(q1/b) + e^(q2/b))
    # Set q2 = 0, then q1 = b * log(p / (1-p))
    q1 = b * log(p / (1 - p))
    q2 = 0.0

    # Current prices via LMSR
    denom = exp(q1/b) + exp(q2/b)
    price_yes = exp(q1/b) / denom
    price_no  = exp(q2/b) / denom

    # Trade impact: cost of buying `trade_size` shares of Yes
    q1_after = q1 + trade_size
    cost_before = b * log(exp(q1/b) + exp(q2/b))
    cost_after  = b * log(exp(q1_after/b) + exp(q2/b))
    trade_cost  = cost_after - cost_before

    price_after = exp(q1_after/b) / (exp(q1_after/b) + exp(q2/b))
    slippage = price_after - price_yes

    return (price_yes=price_yes, price_no=price_no,
            trade_cost=trade_cost, slippage=slippage,
            price_impact=slippage / price_yes * 100,
            liquidity_param=b, model="LMSR Pricing")
end
