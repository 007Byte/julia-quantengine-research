# ── Rate Limiter Tests ────────────────────────────────────────

@testset "RateLimiter creation" begin
    limiter = RateLimiter(max_per_minute=30, max_per_second=2)
    @test limiter.max_per_minute == 30
    @test limiter.max_per_second == 2
    @test isempty(limiter.requests)
end

@testset "try_request! first request succeeds" begin
    limiter = RateLimiter(max_per_minute=30, max_per_second=2)
    @test try_request!(limiter) == true
    @test length(limiter.requests) == 1
end

@testset "try_request! per-second limit" begin
    limiter = RateLimiter(max_per_minute=100, max_per_second=2)

    # First two should succeed
    @test try_request!(limiter) == true
    @test try_request!(limiter) == true

    # Third should fail (per-second limit = 2)
    @test try_request!(limiter) == false
end

@testset "try_request! per-minute limit" begin
    limiter = RateLimiter(max_per_minute=3, max_per_second=100)

    @test try_request!(limiter) == true
    @test try_request!(limiter) == true
    @test try_request!(limiter) == true

    # Fourth should fail (per-minute limit = 3)
    @test try_request!(limiter) == false
end

@testset "create_rate_limiters" begin
    limiters = create_rate_limiters()

    @test haskey(limiters, :yahoo)
    @test haskey(limiters, :polymarket)
    @test haskey(limiters, :general)

    @test limiters[:yahoo].max_per_minute == 30
    @test limiters[:polymarket].max_per_minute == 60
    @test limiters[:general].max_per_minute == 120
end
