# ── Layer 1: Funding Rate Arbitrage (Cash & Carry) ───────────
# Buy spot + short perpetual futures = delta neutral.
# Collect funding payments every 8 hours when funding > 0.
# No directional opinion needed — pure structural edge.
# Historical: 71.4% of funding periods positive, 19.26% APR in 2025.

"""Funding rate snapshot for a crypto asset."""
struct FundingSnapshot
    asset::String
    rate::Float64           # funding rate per 8hr period (e.g., 0.0001 = 0.01%)
    annualized::Float64     # rate × 3 × 365
    timestamp::DateTime
    is_positive::Bool       # true = longs pay shorts (we collect)
end

"""Position state for a funding arb trade."""
mutable struct FundingArbPosition
    asset::String
    spot_entry::Float64
    perp_entry::Float64
    size_dollars::Float64
    total_funding_collected::Float64
    n_funding_periods::Int
    entry_time::DateTime
    is_active::Bool
end

"""
    simulate_funding_arb(prices, funding_rates, timestamps; capital, leverage)

Simulate funding rate arbitrage on historical data.
Assumes: buy spot at price, short perp at same price (delta neutral).
Collect funding every 8 hours when positive. Pay when negative.
Exit when cumulative funding collected reaches target or funding flips negative for extended period.
"""
function simulate_funding_arb(prices::Vector{Float64},
                               funding_rates::Vector{Float64},
                               timestamps::Vector{DateTime};
                               capital::Float64=10000.0,
                               position_pct::Float64=0.30,
                               exit_after_negative_days::Int=3)
    n = length(prices)
    @assert length(funding_rates) == n "prices and funding_rates must have same length"

    equity = capital
    peak_equity = capital
    equity_curve = Float64[equity]
    trades = NamedTuple[]
    position = nothing
    consecutive_negative = 0

    for i in 1:n
        rate = funding_rates[i]

        if position !== nothing && position.is_active
            # Collect or pay funding
            funding_pnl = position.size_dollars * rate
            position.total_funding_collected += funding_pnl
            position.n_funding_periods += 1
            equity += funding_pnl

            # Track consecutive negative periods
            if rate < 0
                consecutive_negative += 1
            else
                consecutive_negative = 0
            end

            # Exit conditions
            should_exit = false
            exit_reason = :none

            # Exit if funding has been negative for too long
            if consecutive_negative >= exit_after_negative_days * 3  # 3 periods per day
                should_exit = true
                exit_reason = :negative_funding
            end

            # Exit if we've collected 5%+ (take profits)
            if position.total_funding_collected / position.size_dollars > 0.05
                should_exit = true
                exit_reason = :target_reached
            end

            # Exit if basis moved against us significantly (spot dropped, perp didn't)
            basis_pnl = (prices[i] - position.spot_entry) / position.spot_entry
            # Note: as delta neutral, basis P&L should be ~0, but in practice there's basis risk
            if abs(basis_pnl) > 0.10  # 10% basis divergence — something broke
                should_exit = true
                exit_reason = :basis_risk
            end

            if should_exit
                net_pnl = position.total_funding_collected
                # Subtract exit costs (close both legs)
                exit_cost = position.size_dollars * 2 * 0.0011  # 11 bps per leg
                net_pnl -= exit_cost

                push!(trades, (
                    asset=position.asset,
                    entry_time=position.entry_time,
                    exit_time=timestamps[i],
                    size=position.size_dollars,
                    funding_collected=position.total_funding_collected,
                    n_periods=position.n_funding_periods,
                    net_pnl=net_pnl,
                    net_pnl_pct=net_pnl / position.size_dollars * 100,
                    exit_reason=exit_reason,
                    hold_days=position.n_funding_periods / 3.0
                ))

                position = nothing
                consecutive_negative = 0
            end
        end

        # Enter new position when flat and funding is attractive
        if position === nothing && rate > 0.0001  # > 0.01% per period (~3.65% APR minimum)
            size = equity * position_pct
            entry_cost = size * 2 * 0.0011  # 11 bps per leg to enter
            equity -= entry_cost

            position = FundingArbPosition(
                "funding_arb", prices[i], prices[i], size,
                0.0, 0, timestamps[i], true
            )
            consecutive_negative = 0
        end

        peak_equity = max(peak_equity, equity)
        push!(equity_curve, equity)
    end

    # Close any open position at end
    if position !== nothing && position.is_active
        net_pnl = position.total_funding_collected
        exit_cost = position.size_dollars * 2 * 0.0011
        net_pnl -= exit_cost
        equity += net_pnl  # already tracking funding in equity, just deduct exit cost
        push!(trades, (
            asset=position.asset, entry_time=position.entry_time,
            exit_time=timestamps[end], size=position.size_dollars,
            funding_collected=position.total_funding_collected,
            n_periods=position.n_funding_periods, net_pnl=net_pnl,
            net_pnl_pct=net_pnl / position.size_dollars * 100,
            exit_reason=:end_of_data, hold_days=position.n_funding_periods / 3.0
        ))
    end

    return (trades=trades, equity_curve=equity_curve, final_equity=equity,
            peak_equity=peak_equity)
end

"""Generate synthetic but realistic funding rates from price data."""
function generate_funding_rates(prices::Vector{Float64}, returns::Vector{Float64})
    n = length(prices)
    rates = zeros(n)
    for i in 1:n
        # Funding rate correlates with recent momentum (longs pile in during uptrends)
        lookback = min(i, 24)  # ~8 hours of 5-min bars or 24 daily bars
        if lookback > 1
            recent_return = (prices[i] - prices[max(1, i-lookback)]) / prices[max(1, i-lookback)]
            # Base rate + momentum component + noise
            base_rate = 0.0001  # 0.01% base (slightly positive bias — structural)
            momentum = recent_return * 0.005  # momentum drives funding higher
            noise = randn() * 0.00005
            rates[i] = base_rate + momentum + noise
        end
    end
    return rates
end
