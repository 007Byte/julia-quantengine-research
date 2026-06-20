# ── Model 32: Time Decay / Volatility Compression ────────────
# Models how prediction market probabilities converge toward 0 or 1
# as the event date approaches. Exploits volatility compression.

"""
    run_time_decay(prices, days_to_expiry; current_price)

Analyze probability convergence and volatility compression.
As events approach, uncertainty shrinks and prices become more extreme.

Returns: expected volatility path, optimal entry/exit timing,
and convergence speed.
"""
function run_time_decay(prices::Vector{Float64}, days_to_expiry::Float64;
                         current_price::Float64=0.0)
    n = length(prices)
    p = current_price > 0.0 ? current_price : (isempty(prices) ? 0.5 : prices[end])

    if n < 5 || days_to_expiry <= 0
        return (direction="HOLD", probability=p, accuracy=NaN,
                vol_compression=0.0, convergence_speed=0.0,
                expected_move=0.0, time_value=0.0,
                optimal_hold_days=0.0,
                model="Time Decay (Prediction Market)")
    end

    # ── Volatility compression analysis ──
    # Compute rolling volatility at different lookbacks
    changes = diff(prices)
    recent_vol = n >= 10 ? std(changes[max(1,end-9):end]) : std(changes)
    full_vol = std(changes)

    # Compression ratio: how much has vol shrunk recently
    vol_compression = full_vol > 1e-8 ? 1.0 - recent_vol / full_vol : 0.0
    vol_compression = clamp(vol_compression, -1.0, 1.0)

    # ── Convergence speed ──
    # Fit exponential decay to |p - 0.5| over time
    distances_from_center = abs.(prices .- 0.5)
    if n >= 10
        # Simple linear regression on log(1 - distance) to estimate convergence
        recent_dist = distances_from_center[end-min(9,n-1):end]
        if all(d -> d > 0.01, recent_dist)
            x = collect(1.0:length(recent_dist))
            y = log.(recent_dist)
            slope = (mean(x .* y) - mean(x) * mean(y)) / (mean(x.^2) - mean(x)^2)
            convergence_speed = slope  # positive = moving away from 0.5, negative = converging
        else
            convergence_speed = 0.0
        end
    else
        convergence_speed = 0.0
    end

    # ── Time value ──
    # Prediction markets have "time value" similar to options
    # Maximum time value at p=0.5, zero at p=0 or p=1
    intrinsic = max(p, 1 - p)  # what it's worth if resolved now
    time_value = intrinsic * sqrt(days_to_expiry / 365.0) * recent_vol * 10

    # ── Expected move by expiry ──
    # Under random walk: expected absolute move = vol * sqrt(days)
    expected_daily_vol = max(recent_vol, 0.001)
    expected_move = expected_daily_vol * sqrt(days_to_expiry)

    # ── Optimal hold period ──
    # Trade early when vol is high, exit as vol compresses
    if vol_compression > 0.3
        optimal_hold_days = days_to_expiry * 0.3  # exit early, vol already compressing
    elseif days_to_expiry > 30
        optimal_hold_days = days_to_expiry * 0.6  # hold through most of the period
    else
        optimal_hold_days = days_to_expiry * 0.8  # close to expiry, hold tight
    end

    # ── Direction signal ──
    # Strong convergence + clear direction = trade the convergence
    direction = if p > 0.65 && convergence_speed > 0
        "UP"    # converging to YES
    elseif p < 0.35 && convergence_speed > 0
        "DOWN"  # converging to NO
    elseif abs(p - 0.5) < 0.1 && days_to_expiry < 7
        "HOLD"  # too uncertain near expiry
    else
        p > 0.5 ? "LEAN YES" : "LEAN NO"
    end

    return (direction=direction, probability=p, accuracy=NaN,
            vol_compression=vol_compression,
            convergence_speed=convergence_speed,
            expected_move=expected_move,
            time_value=time_value,
            optimal_hold_days=optimal_hold_days,
            recent_vol=recent_vol,
            days_to_expiry=days_to_expiry,
            model="Time Decay (Prediction Market)")
end
