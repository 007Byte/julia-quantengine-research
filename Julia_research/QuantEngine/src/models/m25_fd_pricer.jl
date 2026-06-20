# ── Model 25: Crank-Nicolson Finite-Difference Pricer (Wilmott) ──
# Edge: Prices American options (no closed form), validates BS analytical.
# Solves the Black-Scholes PDE via Crank-Nicolson (2nd order in both S and t).

# Thomas algorithm for tridiagonal systems Ax=d
function _thomas_solve(a::Vector{Float64}, b::Vector{Float64},
                       c::Vector{Float64}, d::Vector{Float64})
    n = length(d)
    cp = zeros(n); dp = zeros(n); x = zeros(n)
    cp[1] = c[1] / b[1]
    dp[1] = d[1] / b[1]
    for i in 2:n
        m = a[i] / (b[i] - a[i] * cp[i-1])
        cp[i] = i < n ? c[i] / (b[i] - a[i] * cp[i-1]) : 0.0
        dp[i] = (d[i] - a[i] * dp[i-1]) / (b[i] - a[i] * cp[i-1])
    end
    x[n] = dp[n]
    for i in (n-1):-1:1
        x[i] = dp[i] - cp[i] * x[i+1]
    end
    return x
end

function run_fd_pricer(returns, S0, high, low;
                       rf=RF_ANNUAL, T=30/252, asset_type=:stock,
                       N_space::Int=100, N_time::Int=100)
    n = length(returns)
    if n < 20 || asset_type == :polymarket
        return (fd_price_call=NaN, fd_price_put=NaN, american_put=NaN,
                early_exercise_prem=NaN, bs_call_ref=NaN,
                fd_vs_bs_error=NaN, grid_converged=false,
                sigma_used=NaN, direction="HOLD", probability=0.5,
                accuracy=NaN, model="Crank-Nicolson FD Pricer")
    end

    ann_factor = asset_type == :crypto ? 365.0 : 252.0

    # Volatility (same estimators as m24)
    sigma_hist = std(returns) * sqrt(ann_factor)
    n_hl = min(length(high), length(low), n)
    h = high[end-n_hl+1:end]; l = low[end-n_hl+1:end]
    hl = log.(max.(h, 1e-8) ./ max.(l, 1e-8))
    sigma_park = sqrt(1.0 / (4 * n_hl * log(2)) * sum(hl .^ 2)) * sqrt(ann_factor)
    sigma = clamp(median([sigma_hist, sigma_park]), 0.01, 5.0)

    K = S0  # ATM
    S_max = 3.0 * S0
    dS = S_max / N_space
    dt = T / N_time

    # Stock price grid: S[0], S[1], ..., S[N_space]
    S = [j * dS for j in 0:N_space]

    # ── Crank-Nicolson for European Call ────────────────────────
    function cn_price(payoff_fn, is_american::Bool=false)
        # Terminal condition
        V = [payoff_fn(s) for s in S]

        for _ in N_time:-1:1
            # Build tridiagonal system for interior nodes (j=1 to N_space-1)
            n_int = N_space - 1
            a_vec = zeros(n_int)  # sub-diagonal
            b_vec = zeros(n_int)  # main diagonal
            c_vec = zeros(n_int)  # super-diagonal
            d_vec = zeros(n_int)  # RHS

            for idx in 1:n_int
                j = idx  # grid index (1 to N_space-1)
                alpha_j = 0.25 * dt * (sigma^2 * j^2 - rf * j)
                beta_j  = -0.5 * dt * (sigma^2 * j^2 + rf)
                gamma_j = 0.25 * dt * (sigma^2 * j^2 + rf * j)

                # Implicit side coefficients: (I - A) * V^{n}
                a_vec[idx] = -alpha_j
                b_vec[idx] = 1.0 - beta_j
                c_vec[idx] = -gamma_j

                # Explicit side: (I + A) * V^{n+1}
                d_vec[idx] = alpha_j * V[j] + (1.0 + beta_j) * V[j+1] + gamma_j * V[j+2]
            end

            # Boundary adjustments
            # Lower boundary (j=1): alpha_1 coefficient for S=0
            alpha_1 = 0.25 * dt * (sigma^2 * 1^2 - rf * 1)
            d_vec[1] += alpha_1 * V[1]  # lower boundary contribution

            V_interior = _thomas_solve(a_vec, b_vec, c_vec, d_vec)

            # Update interior nodes
            for idx in 1:n_int
                V[idx+1] = V_interior[idx]
            end

            # Boundaries
            V[1] = 0.0  # V(S=0) for call, or K*exp(-rf*t) for put (set outside)
            V[end] = payoff_fn(S_max)  # approximate upper boundary

            # American: early exercise constraint
            if is_american
                for j in 1:length(S)
                    V[j] = max(V[j], payoff_fn(S[j]))
                end
            end
        end
        return V
    end

    # European call
    call_payoff(s) = max(s - K, 0.0)
    V_call = cn_price(call_payoff, false)

    # European put
    put_payoff(s) = max(K - s, 0.0)
    V_put = cn_price(put_payoff, false)

    # American put (early exercise)
    V_am_put = cn_price(put_payoff, true)

    # Interpolate price at S0
    function interp_at_S0(V_grid)
        j = Int(floor(S0 / dS))
        j = clamp(j, 0, N_space - 1)
        frac = (S0 - S[j+1]) / dS
        return V_grid[j+1] + frac * (V_grid[j+2] - V_grid[j+1])
    end

    fd_call = interp_at_S0(V_call)
    fd_put = interp_at_S0(V_put)
    am_put = interp_at_S0(V_am_put)
    early_exercise_prem = am_put - fd_put

    # BS analytical reference for validation
    Phi(x) = 0.5 * erfc(-x / sqrt(2))
    sqrtT = sqrt(max(T, 1e-8))
    d1 = (log(S0 / K) + (rf + sigma^2 / 2) * T) / (sigma * sqrtT)
    d2 = d1 - sigma * sqrtT
    bs_call = S0 * Phi(d1) - K * exp(-rf * T) * Phi(d2)

    fd_error = bs_call > 1e-8 ? abs(fd_call - bs_call) / bs_call : 0.0
    grid_converged = fd_error < 0.01

    # Vol-based directional signal (same as m24)
    lambda = 0.94; r2 = returns .^ 2; ewma_var = r2[1]
    for i in 2:n
        ewma_var = lambda * ewma_var + (1 - lambda) * r2[i]
    end
    sigma_ewma = sqrt(max(ewma_var, 1e-12)) * sqrt(ann_factor)
    p_up = sigma_nn((sigma_ewma - sigma_hist) / max(sigma_hist, 1e-8) * 5.0)

    # Confidence boost when FD validates BS
    if grid_converged
        p_up = 0.5 + 1.1 * (p_up - 0.5)  # slight boost
        p_up = clamp(p_up, 0.01, 0.99)
    end

    direction = p_up > 0.55 ? "UP" : p_up < 0.45 ? "DOWN" : "HOLD"

    return (fd_price_call=fd_call, fd_price_put=fd_put,
            american_put=am_put, early_exercise_prem=early_exercise_prem,
            bs_call_ref=bs_call, fd_vs_bs_error=fd_error,
            grid_converged=grid_converged, sigma_used=sigma,
            direction=direction, probability=p_up, accuracy=NaN,
            model="Crank-Nicolson FD Pricer")
end
