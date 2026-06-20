# ── Ensemble Optimizer Tests ──────────────────────────────────

using QuantEngine: learn_ensemble_weights, build_prediction_matrix

@testset "learn_ensemble_weights basic" begin
    Random.seed!(42)
    n_samples = 100
    n_models = 5

    # Create synthetic predictions — model 1 is best
    actuals = rand([0.0, 1.0], n_samples)
    predictions = zeros(n_samples, n_models)
    for i in 1:n_samples
        predictions[i, 1] = actuals[i] == 1.0 ? 0.7 : 0.3  # 70% accurate
        predictions[i, 2] = actuals[i] == 1.0 ? 0.6 : 0.4  # 60% accurate
        for j in 3:n_models
            predictions[i, j] = 0.5 + 0.1 * randn()  # near random
        end
    end

    weights = learn_ensemble_weights(predictions, actuals)

    @test length(weights) == n_models
    @test sum(weights) ≈ 1.0 atol=1e-6    # normalized
    @test all(w -> w > 0, weights)          # all positive
    @test weights[1] > weights[5]           # best model gets highest weight
end

@testset "learn_ensemble_weights small sample fallback" begin
    # Too few samples → uniform weights
    predictions = randn(5, 3)
    actuals = rand([0.0, 1.0], 5)

    weights = learn_ensemble_weights(predictions, actuals)
    @test length(weights) == 3
    @test all(w -> w ≈ 1/3, weights)
end

@testset "learn_ensemble_weights single model" begin
    predictions = randn(50, 1)
    actuals = rand([0.0, 1.0], 50)

    weights = learn_ensemble_weights(predictions, actuals)
    @test length(weights) == 1
    @test weights[1] ≈ 1.0
end

@testset "compute_composite with learned weights" begin
    results = Dict{String,Any}()
    results["Model A"] = (probability=0.7, accuracy=0.6)
    results["Model B"] = (probability=0.3, accuracy=0.6)

    # Without learned weights: accuracy-based (should average to ~0.5)
    comp1 = compute_composite(results)

    # With learned weights: heavily favor Model A
    lw = Dict("Model A" => 0.9, "Model B" => 0.1)
    comp2 = compute_composite(results; learned_weights=lw)

    # Learned weights should shift p_true toward Model A's prediction
    @test comp2.p_true > comp1.p_true
end

@testset "build_prediction_matrix" begin
    # Need at least 5 samples for build_prediction_matrix
    history = [
        Dict{String,Any}("M1" => (probability=0.7, accuracy=0.6),
                          "M2" => (probability=0.4, accuracy=0.5)),
        Dict{String,Any}("M1" => (probability=0.6, accuracy=0.6),
                          "M2" => (probability=0.5, accuracy=0.5)),
        Dict{String,Any}("M1" => (probability=0.8, accuracy=0.6),
                          "M2" => (probability=0.3, accuracy=0.5)),
        Dict{String,Any}("M1" => (probability=0.5, accuracy=0.6),
                          "M2" => (probability=0.6, accuracy=0.5)),
        Dict{String,Any}("M1" => (probability=0.7, accuracy=0.6),
                          "M2" => (probability=0.4, accuracy=0.5)),
    ]
    actuals = [1.0, 0.0, 1.0, 0.0, 1.0]

    preds, acts, names = build_prediction_matrix(history, actuals)

    @test size(preds) == (5, 2)
    @test length(acts) == 5
    @test length(names) == 2
    @test "M1" in names
    @test "M2" in names
end
