# ── CPCV Tests ────────────────────────────────────────────────

@testset "combinations_indices" begin
    # C(4,2) = 6
    combos = combinations_indices(4, 2)
    @test length(combos) == 6

    # C(6,2) = 15
    combos = combinations_indices(6, 2)
    @test length(combos) == 15

    # C(5,1) = 5
    combos = combinations_indices(5, 1)
    @test length(combos) == 5

    # Edge: k > n
    combos = combinations_indices(2, 5)
    @test isempty(combos)

    # Edge: k = 0
    combos = combinations_indices(5, 0)
    @test isempty(combos)
end

@testset "purged_splits" begin
    n = 100
    splits = purged_splits(n, 5; purge=5, embargo=3)

    @test length(splits) == 5

    for (train_idx, test_idx) in splits
        # Train and test should not overlap
        @test isempty(intersect(train_idx, test_idx))

        # All indices should be valid
        @test all(1 .<= train_idx .<= n)
        @test all(1 .<= test_idx .<= n)

        # Purge gap: no train index should be within `purge` of test boundary
        test_start = minimum(test_idx)
        test_end = maximum(test_idx)
        for ti in train_idx
            if ti < test_start
                @test ti < test_start - 5  # purge gap
            elseif ti > test_end
                @test ti > test_end + 5 + 3  # purge + embargo gap
            end
        end
    end
end

@testset "cpcv_splits" begin
    n = 300
    n_groups = 6
    n_test_groups = 2

    splits = cpcv_splits(n, n_groups, n_test_groups; purge=5, embargo=3)

    # Should have C(6,2) = 15 splits
    @test length(splits) == 15

    for (train_idx, test_idx) in splits
        # Non-overlapping
        @test isempty(intersect(train_idx, test_idx))

        # Valid range
        @test all(1 .<= train_idx .<= n)
        @test all(1 .<= test_idx .<= n)

        # Both non-empty
        @test !isempty(train_idx)
        @test !isempty(test_idx)
    end
end

@testset "cpcv_evaluate with trivial model" begin
    Random.seed!(42)
    n = 200
    X = randn(n, 5)
    y = rand([0.0, 1.0], n)

    # Trivial model: always predict 0.5
    trivial_model(X_tr, y_tr, X_te) = fill(0.5, size(X_te, 1))

    result = cpcv_evaluate(trivial_model, X, y; n_groups=6, n_test_groups=2)

    @test !isnan(result.mean_accuracy)
    @test 0.0 <= result.mean_accuracy <= 1.0
    @test result.n_folds == 15  # C(6,2)
    @test length(result.fold_accuracies) > 0
    @test length(result.oos_predictions) == n
end

@testset "cpcv_evaluate too few samples" begin
    X = randn(10, 3)
    y = rand([0.0, 1.0], 10)

    model(X_tr, y_tr, X_te) = fill(0.5, size(X_te, 1))
    result = cpcv_evaluate(model, X, y; n_groups=6, n_test_groups=2)

    # Should return gracefully with NaN accuracy
    @test isnan(result.mean_accuracy)
    @test result.n_folds == 0
end
