# ── Composite Signal Tests ────────────────────────────────────

@testset "compute_composite basics" begin
    # All models bullish
    results = Dict{String,Any}()
    for i in 1:10
        results["Model $i"] = (probability=0.7, accuracy=0.6, direction="UP")
    end
    comp = compute_composite(results)

    @test comp.direction == "BUY"
    @test comp.score > 0
    @test comp.p_true > 0.5
    @test comp.bull_pct == 100.0
    @test comp.n_directional == 10
    @test comp.n_total == 10
end

@testset "compute_composite bearish" begin
    results = Dict{String,Any}()
    for i in 1:10
        results["Model $i"] = (probability=0.3, accuracy=0.6, direction="DOWN")
    end
    comp = compute_composite(results)

    @test comp.direction == "DO NOT BUY"
    @test comp.score < 0
    @test comp.p_true < 0.5
    @test comp.bull_pct == 0.0
end

@testset "compute_composite mixed" begin
    results = Dict{String,Any}()
    for i in 1:5
        results["Bull $i"] = (probability=0.6, accuracy=0.55, direction="UP")
    end
    for i in 1:5
        results["Bear $i"] = (probability=0.4, accuracy=0.55, direction="DOWN")
    end
    comp = compute_composite(results)

    # Evenly split → should be near HOLD
    @test -1.0 <= comp.score <= 1.0
    @test comp.bull_pct ≈ 50.0
    @test 0.0 <= comp.confidence <= 100.0
end

@testset "compute_composite empty" begin
    comp = compute_composite(Dict{String,Any}())
    @test comp.direction == "HOLD"
    @test comp.score == 0.0
    @test comp.p_true == 0.5
    @test comp.n_models == 0
end

@testset "compute_composite accuracy weighting" begin
    # High-accuracy bullish model vs low-accuracy bearish models
    results = Dict{String,Any}(
        "HighAcc" => (probability=0.8, accuracy=0.85, direction="UP"),
        "LowAcc1" => (probability=0.3, accuracy=0.48, direction="DOWN"),
        "LowAcc2" => (probability=0.3, accuracy=0.48, direction="DOWN"),
    )
    comp = compute_composite(results)

    # High-accuracy model should dominate → bullish
    @test comp.p_true > 0.5
end

@testset "compute_composite NaN filtering" begin
    results = Dict{String,Any}(
        "Valid" => (probability=0.7, accuracy=0.6),
        "NaN" => (probability=NaN, accuracy=0.6),
        "Edge" => (probability=0.0, accuracy=0.6),  # exactly 0 excluded
        "Edge2" => (probability=1.0, accuracy=0.6),  # exactly 1 excluded
    )
    comp = compute_composite(results)
    @test comp.n_directional == 1  # only "Valid" passes the 0 < p < 1 filter
end
