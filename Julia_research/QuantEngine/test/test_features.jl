# ── Feature Engineering Tests ─────────────────────────────────

@testset "compute_features" begin
    Random.seed!(42)
    n = 300
    prices = cumsum(randn(n)) .+ 100.0
    prices = max.(prices, 1.0)  # ensure positive
    returns = diff(log.(prices))
    volumes = abs.(randn(n)) .* 1e6 .+ 1.0

    X, y, μ, σ = compute_features(prices, returns, volumes)

    # Output dimensions (9 base + 2 fracdiff + 3 new = 17)
    @test size(X, 2) == 18
    @test size(X, 1) > 0   # at least some valid samples
    @test length(y) == size(X, 1)

    # No NaN in output (valid region only)
    @test !any(isnan, X)
    @test !any(isnan, y)

    # Labels are binary
    @test all(yi -> yi == 0.0 || yi == 1.0, y)

    # Standardized features should have mean ≈ 0 and std ≈ 1
    # (columns 15-17 may be zero when no order book data provided)
    for col in 1:min(14, size(X, 2))
        @test abs(mean(X[:, col])) < 0.2  # close to 0
        @test 0.5 < std(X[:, col]) < 2.0   # close to 1
    end
end

@testset "make_sequences" begin
    Random.seed!(42)
    n = 50
    n_feat = 18
    X = randn(n, n_feat)
    y = rand([0.0, 1.0], n)

    seq_len = 10
    Xseq, yseq = make_sequences(X, y, seq_len)

    @test length(Xseq) == n - seq_len
    @test length(yseq) == n - seq_len

    # Each sequence is (seq_len, n_features)
    @test size(Xseq[1]) == (seq_len, n_feat)

    # Labels correspond to the step after the sequence
    @test yseq[1] == y[seq_len + 1]
end
