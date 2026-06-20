# ── Kelly Criterion Tests ─────────────────────────────────────

@testset "run_kelly basic" begin
    Random.seed!(42)
    # Generate realistic returns: slightly positive drift
    returns = 0.001 .+ 0.02 .* randn(500)

    result = run_kelly(returns)

    # All expected fields exist
    @test haskey(pairs(result) |> Dict, :kelly_full)
    @test haskey(pairs(result) |> Dict, :kelly_three_quarter)
    @test haskey(pairs(result) |> Dict, :kelly_half)
    @test haskey(pairs(result) |> Dict, :kelly_quarter)
    @test haskey(pairs(result) |> Dict, :kelly_empirical)
    @test haskey(pairs(result) |> Dict, :kelly_mc)
    @test haskey(pairs(result) |> Dict, :win_rate)
    @test haskey(pairs(result) |> Dict, :edge_consistency)
    @test haskey(pairs(result) |> Dict, :edge_sharpe)

    # Fractional relationships
    @test result.kelly_three_quarter ≈ 0.75 * result.kelly_full
    @test result.kelly_half ≈ 0.50 * result.kelly_full
    @test result.kelly_quarter ≈ 0.25 * result.kelly_full

    # Bounded
    @test -1.0 <= result.kelly_full <= 2.0

    # Win rate is percentage
    @test 0.0 <= result.win_rate <= 100.0

    # Edge consistency is percentage
    @test 0.0 <= result.edge_consistency <= 100.0
end

@testset "run_kelly all positive returns" begin
    returns = abs.(randn(200)) .* 0.01 .+ 0.005  # larger margin to stay positive after costs
    result = run_kelly(returns)

    @test result.kelly_full > 0  # positive edge
    @test result.win_rate >= 90.0  # most should be wins even after cost adjustment
end

@testset "run_kelly all negative returns" begin
    returns = -(abs.(randn(200)) .* 0.01 .+ 0.001)
    result = run_kelly(returns)

    @test result.kelly_full < 0  # negative edge
    @test result.win_rate == 0.0
end

@testset "run_kelly MC simulation" begin
    Random.seed!(123)
    returns = 0.001 .+ 0.02 .* randn(500)
    result = run_kelly(returns)

    # MC probabilities are percentages
    @test 0.0 <= result.prob_profit_full <= 100.0
    @test 0.0 <= result.prob_ruin_full <= 100.0
    @test 0.0 <= result.prob_profit_half <= 100.0
    @test 0.0 <= result.prob_profit_quarter <= 100.0

    # MC Kelly should be non-negative
    @test result.kelly_mc >= 0.0
end
