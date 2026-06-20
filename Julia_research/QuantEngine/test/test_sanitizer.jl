# ── Data Sanitizer Tests ──────────────────────────────────────

@testset "sanitize_price" begin
    @test sanitize_price(100.0) == 100.0
    @test sanitize_price(0.01) == 0.01
    @test sanitize_price(0.0) == 0.0
    @test sanitize_price(999_999_999.0) ≈ 999_999_999.0

    @test_throws ErrorException sanitize_price(NaN)
    @test_throws ErrorException sanitize_price(Inf)
    @test_throws ErrorException sanitize_price(-Inf)
    @test_throws ErrorException sanitize_price(-1.0)
    @test_throws ErrorException sanitize_price(-0.01)
    @test_throws ErrorException sanitize_price(2e9)
end

@testset "sanitize_volume" begin
    @test sanitize_volume(1e6) == 1e6
    @test sanitize_volume(0.0) == 0.0

    # NaN/Inf → 0.0 with warning (not error)
    @test sanitize_volume(NaN) == 0.0
    @test sanitize_volume(Inf) == 0.0

    # Negative → 0.0 with warning
    @test sanitize_volume(-5.0) == 0.0
end

@testset "sanitize_returns" begin
    # Normal returns pass through
    r = [0.01, -0.02, 0.005, -0.003]
    sanitized = sanitize_returns(r)
    @test sanitized == r

    # NaN replaced with 0.0
    r_nan = [0.01, NaN, 0.02]
    sanitized = sanitize_returns(r_nan)
    @test sanitized[2] == 0.0
    @test sanitized[1] == 0.01
    @test sanitized[3] == 0.02

    # Extreme returns clamped
    r_extreme = [0.01, 0.80, -0.90, 0.02]
    sanitized = sanitize_returns(r_extreme)
    @test sanitized[2] == 0.50
    @test sanitized[3] == -0.50

    # Inf replaced
    r_inf = [0.01, Inf, 0.02]
    sanitized = sanitize_returns(r_inf)
    @test sanitized[2] == 0.0

    # Does not mutate original
    original = [0.01, 0.80]
    sanitize_returns(original)
    @test original[2] == 0.80
end

@testset "sanitize_polymarket" begin
    # Valid market
    sanitize_polymarket([0.6, 0.4], ["Yes", "No"])  # should not throw

    # Prices out of range
    @test_throws ErrorException sanitize_polymarket([1.5, 0.4], ["Yes", "No"])
    @test_throws ErrorException sanitize_polymarket([-0.1, 0.4], ["Yes", "No"])

    # Too few outcomes
    @test_throws ErrorException sanitize_polymarket([1.0], ["Yes"])

    # Length mismatch
    @test_throws ErrorException sanitize_polymarket([0.6, 0.4], ["Yes"])
end

@testset "sanitize_ohlcv" begin
    n = 100
    dates = [DateTime(2024, 1, 1) + Day(i) for i in 1:n]
    high = fill(110.0, n)
    low = fill(90.0, n)
    close = fill(100.0, n)
    volume = fill(1e6, n)
    adj = fill(100.0, n)

    # Valid data should not throw
    sanitize_ohlcv(dates, high, low, close, volume, adj)

    # Length mismatch should throw
    @test_throws AssertionError sanitize_ohlcv(dates, high[1:50], low, close, volume, adj)

    # Too few valid prices
    adj_bad = fill(NaN, n)
    adj_bad[1:5] .= 100.0  # only 5 valid
    @test_throws ErrorException sanitize_ohlcv(dates, high, low, close, volume, adj_bad)
end
