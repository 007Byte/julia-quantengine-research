# ── GARCH/EGARCH Tests ────────────────────────────────────────

@testset "run_garch_egarch basic" begin
    Random.seed!(42)
    # Generate synthetic GARCH-like returns
    n = 500
    returns = 0.02 .* randn(n)

    result = run_garch_egarch(returns)

    # All expected fields
    @test haskey(pairs(result) |> Dict, :garch_α)
    @test haskey(pairs(result) |> Dict, :garch_β)
    @test haskey(pairs(result) |> Dict, :garch_ω)
    @test haskey(pairs(result) |> Dict, :egarch_α)
    @test haskey(pairs(result) |> Dict, :egarch_β)
    @test haskey(pairs(result) |> Dict, :egarch_γ)
    @test haskey(pairs(result) |> Dict, :σ_annual_forecast)
    @test haskey(pairs(result) |> Dict, :persistence)
    @test haskey(pairs(result) |> Dict, :leverage_effect)

    # GARCH parameters are non-negative
    @test result.garch_ω >= 0
    @test result.garch_α >= 0
    @test result.garch_β >= 0

    # Volatility forecast is positive and finite
    @test result.σ_annual_forecast > 0
    @test isfinite(result.σ_annual_forecast)

    # Leverage effect is Bool
    @test result.leverage_effect isa Bool

    # After Sprint 2 reparameterization fix, persistence is structurally < 1.0
    @test result.persistence < 1.0
end

@testset "run_garch_egarch with volume" begin
    Random.seed!(42)
    n = 500
    returns = 0.02 .* randn(n)
    volumes = abs.(randn(n)) .* 1e6 .+ 1.0

    result = run_garch_egarch(returns; vol_data=volumes)

    # Volume correlation should be computed (not NaN)
    @test !isnan(result.vol_correlation)
    @test -1.0 <= result.vol_correlation <= 1.0
end

@testset "run_garch_egarch small sample" begin
    Random.seed!(42)
    returns = 0.02 .* randn(50)

    # Should still work with small samples
    result = run_garch_egarch(returns)
    @test isfinite(result.σ_annual_forecast)
end
