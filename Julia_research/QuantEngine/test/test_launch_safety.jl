# ── Launch Safety Tests ───────────────────────────────────────

using QuantEngine: run_stress_test, StressTestResult,
                   CPCVValidationResult

# ── Monte Carlo Stress Test ──────────────────────────────────

@testset "stress test basic" begin
    Random.seed!(42)
    returns = 0.0005 .+ 0.02 .* randn(500)  # slightly positive drift

    result = run_stress_test(returns;
        initial_capital=10000.0, n_paths=100, horizon_days=60,
        kelly_fraction=0.10, verbose=false)

    @test result isa StressTestResult
    @test result.n_paths == 100
    @test 0.0 <= result.survival_rate <= 100.0
    @test result.median_final_value > 0.0
    @test result.worst_path_value >= 0.0
    @test 0.0 <= result.pct_profitable <= 100.0
    @test result.avg_max_drawdown >= 0.0
    @test !isempty(result.failure_reasons) || result.passes
end

@testset "stress test survival with conservative Kelly" begin
    Random.seed!(42)
    returns = 0.001 .+ 0.015 .* randn(500)

    result = run_stress_test(returns;
        initial_capital=10000.0, n_paths=200, horizon_days=60,
        kelly_fraction=0.05,  # very conservative
        verbose=false)

    # Conservative Kelly should have high survival
    @test result.survival_rate > 80.0
end

@testset "stress test high Kelly is dangerous" begin
    Random.seed!(42)
    returns = 0.0005 .+ 0.03 .* randn(500)  # high vol

    result_conservative = run_stress_test(returns;
        n_paths=100, horizon_days=60, kelly_fraction=0.05, verbose=false)
    result_aggressive = run_stress_test(returns;
        n_paths=100, horizon_days=60, kelly_fraction=0.40, verbose=false)

    # Aggressive Kelly should have worse survival than conservative
    @test result_aggressive.survival_rate <= result_conservative.survival_rate + 5.0
end

# ── CPCV Validation ──────────────────────────────────────────

@testset "CPCVValidationResult struct" begin
    result = CPCVValidationResult("TEST", 0, NamedTuple[],
        0.0, 0.0, 0.0, 0.0, 0.0, false, false, ["No folds"])

    @test result.ticker == "TEST"
    @test !result.passes_launch_check
    @test !isempty(result.failure_reasons)
end

# ── Integration: throttle + costs ────────────────────────────

@testset "throttle never exceeds 1.0 under any condition" begin
    # Test many scenarios
    for bankroll in [500.0, 5000.0, 10000.0, 50000.0, 200000.0]
        engine = AdaptiveEngine(goal_target=10_000_000.0, initial_bankroll=10_000.0)
        update_bankroll!(engine, bankroll)
        throttle = dynamic_throttle(engine)
        @test throttle.kelly_scale <= 1.0
        @test throttle.kelly_scale >= 0.10
        @test throttle.max_daily_risk_pct == 2.0
    end
end

@testset "losing money always reduces Kelly" begin
    engine = AdaptiveEngine(goal_target=10_000_000.0, initial_bankroll=10_000.0)

    # Progressively worse losses → progressively lower Kelly
    for (bankroll, max_kelly) in [(9500.0, 0.80), (9000.0, 0.55),
                                   (8500.0, 0.30), (7000.0, 0.30)]
        update_bankroll!(engine, bankroll)
        throttle = dynamic_throttle(engine)
        @test throttle.kelly_scale <= max_kelly
    end
end
