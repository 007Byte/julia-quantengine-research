# ── Fractional Differentiation Tests ──────────────────────────

@testset "fracdiff_weights" begin
    # d=0 → only weight is 1.0 (identity)
    w0 = fracdiff_weights(0.0)
    @test length(w0) == 1
    @test w0[1] ≈ 1.0

    # d=1 → first weight is 1.0
    w1 = fracdiff_weights(1.0)
    @test w1[1] ≈ 1.0
    @test length(w1) >= 1

    # d=0.5 → first weight is 1.0, generates multiple weights
    w05 = fracdiff_weights(0.5)
    @test length(w05) > 1
    @test w05[1] ≈ 1.0
end

@testset "fracdiff identity at d=0" begin
    series = [1.0, 2.0, 3.0, 4.0, 5.0]
    result = fracdiff(series, 0.0)
    # d=0 means no differentiation — output ≈ input
    @test result ≈ series
end

@testset "fracdiff at d=1" begin
    series = collect(1.0:20.0)
    result = fracdiff(series, 1.0)

    # Should have some valid (non-NaN) entries
    valid = filter(!isnan, result)
    @test length(valid) > 0
    # All valid values should be finite
    @test all(isfinite, valid)
end

@testset "fracdiff NaN padding" begin
    d = 0.5
    weights = fracdiff_weights(d)
    window = length(weights)
    n = window + 100  # ensure series is longer than window
    series = collect(1.0:Float64(n))
    result = fracdiff(series, d)

    # First (window-1) entries should be NaN
    @test all(isnan, result[1:window-1])
    @test !any(isnan, result[window:end])
end

@testset "adf_test white noise is stationary" begin
    Random.seed!(42)
    white_noise = randn(500)

    stat, crit, is_stationary = adf_test(white_noise)
    @test is_stationary == true
    @test stat < crit  # stat more negative than critical value
end

@testset "adf_test random walk is non-stationary" begin
    Random.seed!(42)
    random_walk = cumsum(randn(500))

    stat, crit, is_stationary = adf_test(random_walk)
    @test is_stationary == false
end

@testset "adf_test small sample returns gracefully" begin
    small = randn(10)
    stat, crit, is_stationary = adf_test(small)
    @test crit == -2.86
    # Should return without error
end

@testset "find_min_d" begin
    Random.seed!(42)

    # White noise: already stationary, so d should be low (< 1.0)
    wn = randn(500)
    d_wn = find_min_d(wn)
    @test d_wn <= 1.0

    # Random walk should need higher d (possibly > 1.0 for I(1) series)
    rw = cumsum(randn(500))
    d_rw = find_min_d(rw)
    @test d_rw > 0.0
    @test d_rw <= 2.0  # extended range after Sprint 2.3 fix
end

@testset "compute_fracdiff_features" begin
    Random.seed!(42)
    prices = cumsum(randn(300)) .+ 200.0
    prices = max.(prices, 1.0)
    returns = diff(log.(prices))

    result = compute_fracdiff_features(prices, returns)

    @test haskey(pairs(result) |> Dict, :fd_price)
    @test haskey(pairs(result) |> Dict, :fd_logprice)
    @test haskey(pairs(result) |> Dict, :d_price)
    @test haskey(pairs(result) |> Dict, :d_logprice)

    @test length(result.fd_price) == length(prices)
    @test length(result.fd_logprice) == length(prices)
    @test 0.0 <= result.d_price <= 2.0
    @test 0.0 <= result.d_logprice <= 2.0
end
