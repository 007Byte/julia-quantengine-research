# ── Layer 2: Pairs Trading / Statistical Arbitrage ───────────
# Find cointegrated crypto pairs (BTC-ETH primary).
# When spread diverges beyond threshold, trade the reversion.
# Market-neutral: long underperformer + short outperformer.
# Research: 14.89% APR, Sharpe 2.23 on BTC-ETH after costs.

"""Result of a cointegration test between two price series."""
struct CointegrationResult
    is_cointegrated::Bool
    p_value::Float64
    hedge_ratio::Float64    # β: how much of asset B to hold per unit of asset A
    half_life::Float64      # mean reversion half-life in bars
    hurst::Float64          # Hurst exponent (<0.5 = mean reverting)
end

"""State of a pairs trade."""
mutable struct PairsTrade
    asset_a::String
    asset_b::String
    direction::Symbol       # :long_a_short_b or :short_a_long_b
    entry_zscore::Float64
    entry_spread::Float64
    size_dollars::Float64
    entry_time::DateTime
    is_active::Bool
end

"""
    test_cointegration(prices_a, prices_b) → CointegrationResult

Simple cointegration test using OLS regression + ADF on residuals.
"""
function test_cointegration(prices_a::Vector{Float64}, prices_b::Vector{Float64})
    n = min(length(prices_a), length(prices_b))
    pa = prices_a[end-n+1:end]
    pb = prices_b[end-n+1:end]

    # OLS: pa = α + β*pb + ε
    x = [ones(n) pb]
    beta = x \ pa
    hedge_ratio = beta[2]
    residuals = pa .- x * beta

    # ADF test on residuals (simplified: check if residuals are stationary)
    # Use Dickey-Fuller: Δr_t = ρ*r_{t-1} + ε
    dr = diff(residuals)
    r_lag = residuals[1:end-1]
    rho = (r_lag' * dr) / (r_lag' * r_lag)

    # ADF statistic
    se = std(dr .- rho .* r_lag) / sqrt(sum(r_lag .^ 2))
    adf_stat = rho / max(se, 1e-10)

    # Critical values (approximate): -3.43 (1%), -2.86 (5%), -2.57 (10%)
    is_coint = adf_stat < -2.86
    # Approximate p-value
    p_val = adf_stat < -3.43 ? 0.01 : adf_stat < -2.86 ? 0.05 : adf_stat < -2.57 ? 0.10 : 0.50

    # Half-life of mean reversion
    half_life = -log(2) / min(rho, -0.001)
    half_life = clamp(half_life, 1.0, 500.0)

    # Hurst exponent (simplified via variance ratio)
    if n > 40
        returns = diff(log.(pa))
        var_1 = var(returns)
        var_20 = var([sum(returns[i:i+19]) for i in 1:length(returns)-19])
        hurst = log(var_20 / var_1) / (2 * log(20))
        hurst = clamp(hurst, 0.0, 1.0)
    else
        hurst = 0.5
    end

    return CointegrationResult(is_coint, p_val, hedge_ratio, half_life, hurst)
end

"""
    compute_spread(prices_a, prices_b, hedge_ratio) → (spread, zscore)

Compute the spread and its z-score for pairs trading signals.
"""
function compute_spread(prices_a::Vector{Float64}, prices_b::Vector{Float64},
                        hedge_ratio::Float64; lookback::Int=60)
    n = min(length(prices_a), length(prices_b))
    spread = prices_a[end-n+1:end] .- hedge_ratio .* prices_b[end-n+1:end]
    # Z-score using rolling window
    lb = min(lookback, length(spread))
    recent = spread[end-lb+1:end]
    mu = mean(recent)
    sigma = std(recent)
    zscore = sigma > 1e-10 ? (spread[end] - mu) / sigma : 0.0
    return (spread=spread, zscore=zscore, mu=mu, sigma=sigma)
end

"""
    simulate_pairs_trading(prices_a, prices_b, dates; capital, params...) → results

Simulate pairs trading on two price series.
"""
function simulate_pairs_trading(prices_a::Vector{Float64}, prices_b::Vector{Float64},
                                 dates::Vector{DateTime};
                                 capital::Float64=10000.0,
                                 position_pct::Float64=0.20,
                                 entry_z::Float64=2.0,
                                 exit_z::Float64=0.5,
                                 stop_z::Float64=3.5,
                                 max_hold_bars::Int=60,
                                 recalc_interval::Int=60,
                                 cost_per_leg::Float64=0.0011)
    n = min(length(prices_a), length(prices_b))
    pa = prices_a[end-n+1:end]
    pb = prices_b[end-n+1:end]
    dt = dates[end-n+1:end]

    equity = capital
    peak = capital
    equity_curve = Float64[equity]
    trades = NamedTuple[]
    position = nothing
    warmup = max(recalc_interval + 20, 80)

    # Initial cointegration test
    coint = test_cointegration(pa[1:warmup], pb[1:warmup])
    hedge_ratio = coint.hedge_ratio
    last_recalc = warmup

    for i in (warmup+1):n
        # Periodically recalculate cointegration
        if i - last_recalc >= recalc_interval
            coint = test_cointegration(pa[max(1,i-250):i], pb[max(1,i-250):i])
            hedge_ratio = coint.hedge_ratio
            last_recalc = i
            # If cointegration broke down, close position and pause
            if !coint.is_cointegrated && position !== nothing
                # Close position
                spread_info = compute_spread(pa[1:i], pb[1:i], hedge_ratio)
                pnl = _close_pairs_position!(position, pa[i], pb[i], spread_info.zscore,
                                              cost_per_leg, equity, dt[i], :coint_breakdown, trades)
                equity += pnl
                position = nothing
            end
        end

        if !coint.is_cointegrated
            push!(equity_curve, equity)
            continue
        end

        spread_info = compute_spread(pa[max(1,i-120):i], pb[max(1,i-120):i], hedge_ratio)
        z = spread_info.zscore

        # Manage existing position
        if position !== nothing
            bars_held = i - position.entry_time_idx
            should_exit = false
            exit_reason = :none

            if abs(z) <= exit_z  # spread reverted
                should_exit = true; exit_reason = :mean_reversion
            elseif abs(z) >= stop_z  # spread diverged further — stop out
                should_exit = true; exit_reason = :stop_loss
            elseif bars_held >= max_hold_bars
                should_exit = true; exit_reason = :time_expired
            end

            if should_exit
                pnl = _close_pairs_position!(position, pa[i], pb[i], z,
                                              cost_per_leg, equity, dt[i], exit_reason, trades)
                equity += pnl
                peak = max(peak, equity)
                position = nothing
            end
        end

        # Enter new position when flat
        if position === nothing && coint.is_cointegrated
            if z >= entry_z  # spread too high → short A, long B
                size = equity * position_pct
                entry_cost = size * 2 * cost_per_leg * 2  # 4 legs total (2 assets × buy+sell)
                equity -= entry_cost
                position = (direction=:short_a_long_b, entry_z=z, entry_price_a=pa[i],
                           entry_price_b=pb[i], size=size, entry_time=dt[i],
                           entry_time_idx=i, hedge_ratio=hedge_ratio)
            elseif z <= -entry_z  # spread too low → long A, short B
                size = equity * position_pct
                entry_cost = size * 2 * cost_per_leg * 2
                equity -= entry_cost
                position = (direction=:long_a_short_b, entry_z=z, entry_price_a=pa[i],
                           entry_price_b=pb[i], size=size, entry_time=dt[i],
                           entry_time_idx=i, hedge_ratio=hedge_ratio)
            end
        end

        push!(equity_curve, equity)
    end

    # Close remaining position
    if position !== nothing
        pnl = _close_pairs_position!(position, pa[end], pb[end], 0.0,
                                      cost_per_leg, equity, dt[end], :end_of_data, trades)
        equity += pnl
    end

    return (trades=trades, equity_curve=equity_curve, final_equity=equity,
            peak_equity=peak, cointegration=coint)
end

function _close_pairs_position!(pos, price_a, price_b, exit_z, cost_per_leg, equity, exit_time, reason, trades)
    if pos.direction == :short_a_long_b
        pnl_a = (pos.entry_price_a - price_a) / pos.entry_price_a  # short A profit
        pnl_b = (price_b - pos.entry_price_b) / pos.entry_price_b  # long B profit
    else
        pnl_a = (price_a - pos.entry_price_a) / pos.entry_price_a  # long A profit
        pnl_b = (pos.entry_price_b - price_b) / pos.entry_price_b  # short B profit
    end
    net_pnl = pos.size * (pnl_a + pnl_b) / 2  # average of both legs
    exit_cost = pos.size * 2 * cost_per_leg * 2
    net_pnl -= exit_cost

    push!(trades, (direction=pos.direction, entry_z=pos.entry_z, exit_z=exit_z,
                   entry_time=pos.entry_time, exit_time=exit_time,
                   pnl=net_pnl, pnl_pct=net_pnl/pos.size*100,
                   exit_reason=reason, size=pos.size))
    return net_pnl
end
