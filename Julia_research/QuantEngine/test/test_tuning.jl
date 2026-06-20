# ── Hyperparameter Tuning Tests ───────────────────────────────

using QuantEngine: SearchSpace, HyperParam, sample_point, normalize_point,
                   denormalize_point, get_search_space, tunable_models,
                   TuningTrial, _suggest_next, _normal_pdf, _normal_cdf

@testset "HyperParam and SearchSpace" begin
    hp = HyperParam("n_trees", 10.0, 300.0, :int)
    @test hp.name == "n_trees"
    @test hp.low == 10.0
    @test hp.high == 300.0

    space = SearchSpace("TestModel", 99, [hp])
    @test space.model_name == "TestModel"
    @test length(space.params) == 1
end

@testset "sample_point" begin
    Random.seed!(42)
    space = SearchSpace("Test", 1, [
        HyperParam("x", 0.0, 10.0, :float),
        HyperParam("n", 1.0, 100.0, :int),
        HyperParam("lr", log(0.001), log(0.1), :log_float),
    ])

    point = sample_point(space)
    @test haskey(point, "x")
    @test haskey(point, "n")
    @test haskey(point, "lr")
    @test 0.0 <= point["x"] <= 10.0
    @test 1.0 <= point["n"] <= 100.0
    @test point["lr"] > 0.0  # log_float always positive

    # Multiple samples should vary
    p2 = sample_point(space)
    @test p2 != point  # different random sample (very likely)
end

@testset "normalize_point roundtrip" begin
    space = SearchSpace("Test", 1, [
        HyperParam("x", 0.0, 10.0, :float),
        HyperParam("y", -5.0, 5.0, :float),
    ])

    point = Dict("x" => 5.0, "y" => 0.0)
    normalized = normalize_point(space, point)
    @test length(normalized) == 2
    @test normalized[1] ≈ 0.5  # midpoint
    @test normalized[2] ≈ 0.5  # midpoint

    # Denormalize back
    recovered = denormalize_point(space, normalized)
    @test recovered["x"] ≈ 5.0
    @test recovered["y"] ≈ 0.0
end

@testset "get_search_space" begin
    # All tunable models should have search spaces
    for mid in tunable_models()
        space = get_search_space(mid)
        @test !isempty(space.model_name)
        @test !isempty(space.params)
        @test space.model_id == mid
    end

    # Non-tunable model should error
    @test_throws ErrorException get_search_space(999)
end

@testset "tunable_models" begin
    models = tunable_models()
    @test length(models) >= 5
    @test 5 in models   # Random Forest
    @test 6 in models   # LightGBM
    @test 7 in models   # XGBoost
end

@testset "_suggest_next" begin
    Random.seed!(42)
    space = SearchSpace("Test", 1, [
        HyperParam("x", 0.0, 10.0, :float),
    ])

    # Create some trials
    trials = [
        TuningTrial(Dict("x" => 2.0), 0.55, 100.0),
        TuningTrial(Dict("x" => 5.0), 0.60, 100.0),
        TuningTrial(Dict("x" => 8.0), 0.52, 100.0),
    ]

    suggestion = _suggest_next(space, trials)
    @test haskey(suggestion, "x")
    @test 0.0 <= suggestion["x"] <= 10.0
end

@testset "_normal_pdf and _normal_cdf" begin
    @test _normal_pdf(0.0) ≈ 1.0 / sqrt(2π)
    @test _normal_cdf(0.0) ≈ 0.5
    @test _normal_cdf(10.0) ≈ 1.0 atol=1e-6
    @test _normal_cdf(-10.0) ≈ 0.0 atol=1e-6
end

@testset "save and load tuning result" begin
    dir = mktempdir()
    filepath = joinpath(dir, "tuning_test.json")

    result = TuningResult("XGBoost", 7,
        Dict("n_trees" => 80.0, "lr" => 0.05),
        0.62,
        [TuningTrial(Dict("n_trees" => 80.0), 0.62, 500.0)],
        1)

    save_tuning_result(result, filepath)
    @test isfile(filepath)

    loaded = load_tuning_result(filepath)
    @test loaded["model_name"] == "XGBoost"
    @test loaded["best_objective"] ≈ 0.62
    @test loaded["best_params"]["n_trees"] ≈ 80.0
end
