# ── Fractional Differentiation (Lopez de Prado Ch. 5) ─────────
# Achieves stationarity while preserving long-range memory.
# Key idea: instead of full differencing (d=1) which destroys memory,
# use d ∈ (0,1) — the minimum d that passes an ADF unit root test.

"""
    fracdiff_weights(d; threshold=1e-5, max_k=500) → Vector{Float64}

Compute fractional differentiation weights via the binomial series
expansion of (1-B)^d. Uses recurrence: w_k = w_{k-1} * (d-k+1)/k.
Truncates when |w_k| < threshold.
"""
function fracdiff_weights(d::Float64; threshold::Float64=1e-5, max_k::Int=500)
    weights = Float64[1.0]
    w = 1.0
    for k in 1:max_k
        w *= (d - k + 1) / k
        if abs(w) < threshold
            break
        end
        push!(weights, w)
    end
    return weights
end

"""
    fracdiff(series, d; threshold=1e-5) → Vector{Float64}

Apply fixed-width fractional differentiation of order d to a series.
First (window_len-1) entries are NaN (insufficient history).
"""
function fracdiff(series::Vector{Float64}, d::Float64; threshold::Float64=1e-5)
    n = length(series)
    weights = fracdiff_weights(d; threshold)
    window = length(weights)
    result = fill(NaN, n)
    for t in window:n
        val = 0.0
        for (k, w) in enumerate(weights)
            val += w * series[t - k + 1]
        end
        result[t] = val
    end
    return result
end

"""
    adf_test(series; max_lags=5) → (adf_stat, critical_5pct, is_stationary)

Simplified Augmented Dickey-Fuller unit root test.
Regresses Δy_t = α + γ*y_{t-1} + Σδ_i*Δy_{t-i} + ε.
Rejects unit root (series is stationary) if adf_stat < critical value.
"""
function adf_test(series::Vector{Float64}; max_lags::Int=5)
    valid = filter(!isnan, series)
    n = length(valid)
    if n < 20
        return (adf_stat=0.0, critical_5pct=-2.86, is_stationary=false)
    end

    dy = diff(valid)
    n_dy = length(dy)
    p = min(max_lags, div(n_dy, 5))  # limit lags to avoid overfitting

    # Build regression matrix: [y_{t-1}, Δy_{t-1}, ..., Δy_{t-p}, 1]
    n_obs = n_dy - p
    if n_obs < 10
        return (adf_stat=0.0, critical_5pct=-2.86, is_stationary=false)
    end

    X = zeros(n_obs, p + 2)  # y_{t-1}, p lags of Δy, intercept
    y_dep = dy[(p+1):end]

    for i in 1:n_obs
        t = p + i
        X[i, 1] = valid[t]                  # y_{t-1} (level)
        for j in 1:p
            X[i, 1+j] = dy[t - j]           # Δy_{t-j}
        end
        X[i, end] = 1.0                     # intercept
    end

    # OLS: β = (X'X)^{-1} X'y
    XtX = X' * X
    Xty = X' * y_dep
    beta = try
        XtX \ Xty
    catch
        pinv(XtX) * Xty
    end

    # Standard error of γ (coefficient on y_{t-1})
    residuals = y_dep .- X * beta
    sigma2 = sum(residuals .^ 2) / max(1, n_obs - size(X, 2))
    var_beta = try
        sigma2 * inv(XtX)
    catch
        sigma2 * pinv(XtX)
    end

    gamma = beta[1]
    se_gamma = sqrt(max(var_beta[1, 1], 1e-20))
    adf_stat = se_gamma > 1e-12 ? gamma / se_gamma : 0.0

    # Critical values (MacKinnon approximation for n > 100)
    critical_5pct = -2.86
    is_stationary = adf_stat < critical_5pct

    return (adf_stat=adf_stat, critical_5pct=critical_5pct, is_stationary=is_stationary)
end

"""
    find_min_d(series; tol=0.01, max_d=2.0) → Float64

Binary search for the minimum d ∈ (0, max_d) such that fracdiff(series, d)
passes ADF test at 5% significance. Returns d to `tol` resolution.

Handles I(2) series by extending search beyond d=1.0 up to max_d.
"""
function find_min_d(series::Vector{Float64}; tol::Float64=0.01, threshold::Float64=1e-5,
                    max_d::Float64=2.0)
    # Find the upper bound: smallest d in {1.0, 1.5, 2.0} that achieves stationarity
    d_high = -1.0
    for d_candidate in [1.0, 1.5, max_d]
        fd = fracdiff(series, d_candidate; threshold)
        valid = filter(!isnan, fd)
        if length(valid) < 20
            continue
        end
        _, _, is_stat = adf_test(valid)
        if is_stat
            d_high = d_candidate
            break
        end
    end

    # If even max_d doesn't achieve stationarity, return max_d with warning
    if d_high < 0.0
        @warn "find_min_d: series not stationary even at d=$(max_d) — returning $(max_d)"
        return max_d
    end

    # Warn if near-full differentiation
    if d_high >= 0.9
        @warn "find_min_d: high d=$(d_high) — near-full differentiation, limited memory preserved"
    end

    # Binary search in [0, d_high] for the minimum d
    d_low = 0.0
    while (d_high - d_low) > tol
        d_mid = (d_low + d_high) / 2.0
        fd = fracdiff(series, d_mid; threshold)
        valid = filter(!isnan, fd)
        if length(valid) < 20
            d_low = d_mid
            continue
        end
        _, _, stationary = adf_test(valid)
        if stationary
            d_high = d_mid
        else
            d_low = d_mid
        end
    end
    return clamp(d_high, 0.01, max_d)
end

"""
    compute_fracdiff_features(prices, returns) → NamedTuple

Compute fractional differentiation features for the price and log-price
series. Returns two feature columns plus the d values used.

If raw prices need d > 0.8, falls back to log prices for that feature
to preserve more memory.
"""
function compute_fracdiff_features(prices::Vector{Float64}, returns::Vector{Float64})
    log_prices = log.(max.(prices, 1e-8))

    d_price = find_min_d(prices)
    d_logprice = find_min_d(log_prices)

    # Fallback: if raw price d is very high, use log prices instead
    # (log transform often needs lower d, preserving more memory)
    if d_price > 0.8 && d_logprice < d_price
        d_price = d_logprice
        fd_price = fracdiff(log_prices, d_price)
    else
        fd_price = fracdiff(prices, d_price)
    end
    fd_logprice = fracdiff(log_prices, d_logprice)

    return (fd_price=fd_price, fd_logprice=fd_logprice,
            d_price=d_price, d_logprice=d_logprice)
end
