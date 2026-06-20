# ── RALPH Error Handling Tests ────────────────────────────────

function _make_test_ctx()
    AnalysisContext(
        "TEST", :stock, "TEST", mktempdir(),
        [DateTime(2024,1,1)], [100.0], [0.01], [1e6], [101.0], [99.0], 100.0,
        zeros(1, 18), [0.5], zeros(1, 18), [0.5],
        [reshape(zeros(18), 1, 18)], [0.5],
        [reshape(zeros(18), 1, 18)], [0.5],
        18, 1, nothing, Float64[],
        Dict{String,Any}(), RalphLog[], ReentrantLock(),
        nothing  # weight_cache
    )
end

@testset "ralph successful model" begin
    ctx = _make_test_ctx()

    result = ralph(() -> (probability=0.65, accuracy=0.58), "TestModel", ctx; verbose=false)

    @test result !== nothing
    @test result.probability == 0.65

    # Result stored in ctx.results
    @test haskey(ctx.results, "TestModel")
    @test ctx.results["TestModel"].probability == 0.65

    # Log entry recorded
    @test length(ctx.log) == 1
    @test ctx.log[1].success == true
    @test ctx.log[1].model_name == "TestModel"
end

@testset "ralph failing model" begin
    ctx = _make_test_ctx()

    result = ralph(() -> error("model crashed"), "FailModel", ctx;
                   max_retries=2, verbose=false)

    @test result === nothing

    # Should NOT be in results
    @test !haskey(ctx.results, "FailModel")

    # Log entry recorded as failure
    @test length(ctx.log) == 1
    @test ctx.log[1].success == false
    @test occursin("model crashed", ctx.log[1].message)
end

@testset "ralph no data" begin
    ctx = _make_test_ctx()
    ctx.returns = Float64[]  # no data

    result = ralph(() -> (probability=0.5,), "NoDataModel", ctx; verbose=false)

    @test result === nothing
    @test length(ctx.log) == 1
    @test ctx.log[1].success == false
    @test occursin("No data", ctx.log[1].message)
end

@testset "ralph retry on failure" begin
    ctx = _make_test_ctx()
    call_count = Ref(0)

    function flaky_model()
        call_count[] += 1
        if call_count[] < 2
            error("transient error")
        end
        return (probability=0.55, accuracy=0.52)
    end

    result = ralph(flaky_model, "FlakyModel", ctx; max_retries=3, verbose=false)

    @test result !== nothing
    @test call_count[] == 2  # failed once, succeeded on retry
    @test ctx.log[1].success == true
end

@testset "ralph with NaN outputs" begin
    ctx = _make_test_ctx()

    result = ralph(() -> (probability=NaN, accuracy=0.5), "NaNModel", ctx; verbose=false)

    # NaN results are still stored (with warning in verbose mode)
    @test result !== nothing
    @test isnan(result.probability)
    @test haskey(ctx.results, "NaNModel")
end
