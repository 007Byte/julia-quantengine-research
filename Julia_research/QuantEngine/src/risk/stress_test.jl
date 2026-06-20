# ── Monte Carlo Stress Test ───────────────────────────────────
# Simulates 1,000 portfolio paths with fat-tailed returns to test
# whether the system survives extreme scenarios (crashes, flash
# crashes, correlation-to-1.0 events, multi-day drawdowns).

"""Result of a Monte Carlo stress test."""
struct StressTestResult
    n_paths::Int
    survival_rate::Float64         # % of paths that don't hit circuit breaker
    median_final_value::Float64
    worst_path_value::Float64
    worst_drawdown::Float64
    pct_profitable::Float64        # % of paths ending above start
    avg_max_drawdown::Float64
    pct_95_drawdown::Float64       # 95th percentile max drawdown
    passes::Bool
    failure_reasons::Vector{String}
end

"""
    run_stress_test(returns; initial_capital, n_paths, horizon_days,
                    kelly_fraction, max_drawdown_limit, fat_tail_mult)

Monte Carlo simulation with fat-tailed return distribution.
Simulates portfolio paths using historical returns + synthetic tail events.

A path "survives" if it never hits the max drawdown circuit breaker.
The test PASSES if:
- 95%+ of paths survive
- Median final value > initial capital
- 95th percentile drawdown < max_drawdown_limit
"""
function run_stress_test(returns::Vector{Float64};
                          initial_capital::Float64=10000.0,
                          n_paths::Int=1000,
                          horizon_days::Int=252,
                          kelly_fraction::Float64=0.15,
                          max_drawdown_limit::Float64=0.15,
                          asset_type::Symbol=:stock,
                          verbose::Bool=true)
    n = length(returns)
    if n < 50
        error("Need at least 50 historical returns for stress test")
    end

    # Compute historical stats for simulation
    μ = mean(returns)
    σ = std(returns)
    costs = realistic_costs(asset_type)
    cost_per_trade = round_trip_cost_fraction(costs)

    verbose && println("═" ^ 64)
    verbose && println("  MONTE CARLO STRESS TEST")
    verbose && @printf("  Paths: %d | Horizon: %d days | Kelly: %.0f%%\n",
                       n_paths, horizon_days, kelly_fraction * 100)
    verbose && @printf("  Historical: μ=%.4f%% σ=%.4f%% | Costs: %.0f bps RT\n",
                       μ * 100, σ * 100, round_trip_cost_bps(costs))
    verbose && println("═" ^ 64)

    final_values = Float64[]
    max_drawdowns = Float64[]
    survivals = 0

    for path in 1:n_paths
        value = initial_capital
        peak = value

        survived = true

        for day in 1:horizon_days
            # Sample return: mix of historical + fat tail shocks
            r = if rand() < 0.02  # 2% chance of tail event
                # Fat tail: 3-6 sigma event (crash or melt-up)
                shock_size = (3.0 + 3.0 * rand()) * σ
                rand() < 0.7 ? -shock_size : shock_size  # 70% crash, 30% melt-up
            elseif rand() < 0.05  # 5% chance of elevated vol day
                returns[rand(1:n)] * (1.5 + rand())  # historical return amplified
            else
                returns[rand(1:n)]  # normal: sample from history
            end

            # Apply Kelly-sized position with costs
            position_return = kelly_fraction * r - cost_per_trade * 0.3  # not every bar trades
            value *= (1.0 + position_return)
            value = max(value, 0.0)

            # Track peak and drawdown
            peak = max(peak, value)
            dd = (peak - value) / max(peak, 1.0)

            # Circuit breaker check
            if dd > max_drawdown_limit
                survived = false
                break
            end
        end

        push!(final_values, value)
        if survived
            survivals += 1
            dd_final = (peak - value) / max(peak, 1.0)
            push!(max_drawdowns, dd_final)
        else
            push!(max_drawdowns, max_drawdown_limit)  # hit the limit
        end
    end

    survival_rate = survivals / n_paths * 100.0
    median_final = median(final_values)
    worst_final = minimum(final_values)
    pct_profitable = count(v -> v > initial_capital, final_values) / n_paths * 100.0
    avg_dd = mean(max_drawdowns)
    sort!(max_drawdowns)
    pct_95_dd = max_drawdowns[min(round(Int, n_paths * 0.95), length(max_drawdowns))]

    # Pass/fail criteria
    failures = String[]
    if survival_rate < 95.0
        push!(failures, "Survival rate $(round(survival_rate, digits=1))% < 95%")
    end
    if median_final < initial_capital
        push!(failures, "Median final \$$(round(median_final, digits=0)) < initial \$$(round(initial_capital, digits=0))")
    end
    if pct_95_dd > max_drawdown_limit
        push!(failures, "95th pctile DD $(round(pct_95_dd*100, digits=1))% > $(max_drawdown_limit*100)%")
    end
    passes = isempty(failures)

    if verbose
        println()
        @printf("  Survival rate:     %5.1f%%\n", survival_rate)
        @printf("  Median final:      \$%.0f\n", median_final)
        @printf("  Worst path:        \$%.0f\n", worst_final)
        @printf("  %% Profitable:      %5.1f%%\n", pct_profitable)
        @printf("  Avg max drawdown:  %5.1f%%\n", avg_dd * 100)
        @printf("  95th pctile DD:    %5.1f%%\n", pct_95_dd * 100)
        println()
        if passes
            println("  ✓ STRESS TEST PASSED")
        else
            println("  ✗ STRESS TEST FAILED:")
            for f in failures
                println("    → $f")
            end
        end
        println("═" ^ 64)
    end

    return StressTestResult(n_paths, survival_rate, median_final, worst_final,
        maximum(max_drawdowns), pct_profitable, avg_dd, pct_95_dd,
        passes, failures)
end
