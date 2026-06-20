# ── A/B Testing Framework for Ensemble Configurations ────────
# Run two ensemble configs simultaneously and track performance.
# Auto-promotes the winner after sufficient sample size.

"""Configuration for one arm of an A/B test."""
struct ABConfig
    name::String
    model_ids::Vector{Int}        # which models to include
    use_learned_weights::Bool     # use optimized ensemble weights
    kelly_multiplier::Float64     # scale Kelly fraction
end

"""Result tracking for one arm."""
mutable struct ABArm
    config::ABConfig
    n_signals::Int                # total signals generated
    n_trades::Int                 # trades executed
    total_pnl::Float64
    wins::Int
    losses::Int
    sharpe_numerator::Float64     # running sum for Sharpe calc
    sharpe_denominator::Float64   # running sum of squared returns
    lock::ReentrantLock
end

ABArm(config::ABConfig) = ABArm(config, 0, 0, 0.0, 0, 0, 0.0, 0.0, ReentrantLock())

"""A/B test comparing two ensemble configurations."""
mutable struct ABTest
    arm_a::ABArm
    arm_b::ABArm
    min_trades_to_decide::Int     # minimum trades before auto-promotion
    decided::Bool
    winner::String
    start_time::DateTime
end

"""Create an A/B test between two configurations."""
function create_ab_test(config_a::ABConfig, config_b::ABConfig;
                        min_trades::Int=50)
    ABTest(ABArm(config_a), ABArm(config_b), min_trades, false, "", now())
end

"""Record a signal from one arm (thread-safe)."""
function record_signal!(arm::ABArm, pnl::Float64)
    lock(arm.lock) do
        arm.n_signals += 1
        if !isnan(pnl) && pnl != 0.0
            arm.n_trades += 1
            arm.total_pnl += pnl
            if pnl > 0
                arm.wins += 1
            else
                arm.losses += 1
            end
            arm.sharpe_numerator += pnl
            arm.sharpe_denominator += pnl^2
        end
    end
end

"""Get arm statistics."""
function arm_stats(arm::ABArm)
    lock(arm.lock) do
        n = arm.n_trades
        win_rate = n > 0 ? arm.wins / n * 100.0 : 0.0
        avg_pnl = n > 0 ? arm.total_pnl / n : 0.0
        # Running Sharpe approximation
        if n > 1
            mean_r = arm.sharpe_numerator / n
            var_r = arm.sharpe_denominator / n - mean_r^2
            sharpe = var_r > 0 ? mean_r / sqrt(var_r) * sqrt(252) : 0.0
        else
            sharpe = 0.0
        end
        return (name=arm.config.name, n_trades=n, total_pnl=arm.total_pnl,
                win_rate=win_rate, avg_pnl=avg_pnl, sharpe=sharpe)
    end
end

"""Check if the test has enough data to decide a winner."""
function check_ab_winner!(test::ABTest)
    if test.decided
        return test.winner
    end

    stats_a = arm_stats(test.arm_a)
    stats_b = arm_stats(test.arm_b)

    if stats_a.n_trades < test.min_trades_to_decide ||
       stats_b.n_trades < test.min_trades_to_decide
        return ""  # not enough data
    end

    # Winner: higher Sharpe ratio with positive PnL
    if stats_a.sharpe > stats_b.sharpe && stats_a.total_pnl > 0
        test.decided = true
        test.winner = stats_a.name
    elseif stats_b.sharpe > stats_a.sharpe && stats_b.total_pnl > 0
        test.decided = true
        test.winner = stats_b.name
    end

    return test.winner
end

"""Print A/B test comparison."""
function print_ab_results(test::ABTest)
    a = arm_stats(test.arm_a)
    b = arm_stats(test.arm_b)

    println("  ╔══ A/B TEST RESULTS ══════════════════════════════╗")
    @printf("  ║ %-12s  Trades:%4d  PnL:%+8.2f  Sharpe:%5.2f ║\n",
            a.name, a.n_trades, a.total_pnl, a.sharpe)
    @printf("  ║ %-12s  Trades:%4d  PnL:%+8.2f  Sharpe:%5.2f ║\n",
            b.name, b.n_trades, b.total_pnl, b.sharpe)
    if test.decided
        println("  ║ WINNER: $(test.winner)" * " "^(42 - length(test.winner)) * "║")
    else
        println("  ║ UNDECIDED (need $(test.min_trades_to_decide) trades each)        ║")
    end
    println("  ╚══════════════════════════════════════════════════╝")
end

"""Create default A/B test: full 33-model vs fast 20-model subset."""
function create_default_ab_test()
    config_a = ABConfig("Full-33", collect(1:33), false, 1.0)
    config_b = ABConfig("Fast-20", [5,6,7,10,14,15,16,17,22,23,24,25,26,29,30,31,32,33,18,21],
                        false, 0.8)
    return create_ab_test(config_a, config_b; min_trades=30)
end
