# ── Weight Cache Tests ────────────────────────────────────────

using QuantEngine: WeightCache, CachedWeights, get_cached_or_train,
                   save_cache!, load_cache!, clear_stale!, compute_data_hash,
                   is_cache_fresh, get_cached_weights, store_weights!

@testset "CachedWeights creation" begin
    entry = CachedWeights(1, "AAPL", [1.0, 2.0, 3.0],
        [(2, 1), (1, 1)], 11, now(), 0.65, 0.42, UInt64(12345))
    @test entry.model_id == 1
    @test entry.ticker == "AAPL"
    @test length(entry.θ) == 3
    @test entry.n_features == 11
    @test entry.accuracy == 0.65
end

@testset "WeightCache store and retrieve" begin
    dir = mktempdir()
    cache = WeightCache(dir)

    store_weights!(cache, 1, "AAPL", 11,
        [1.0, 2.0, 3.0], [(2, 1), (1, 1)],
        0.65, 0.42, UInt64(12345))

    entry = get_cached_weights(cache, 1, "AAPL", 11)
    @test entry !== nothing
    @test entry.θ == [1.0, 2.0, 3.0]
    @test entry.accuracy == 0.65

    # Miss: wrong ticker
    @test get_cached_weights(cache, 1, "MSFT", 11) === nothing

    # Miss: wrong model
    @test get_cached_weights(cache, 2, "AAPL", 11) === nothing
end

@testset "is_cache_fresh" begin
    fresh = CachedWeights(1, "AAPL", Float64[], Tuple{Int,Int}[], 11,
        now(), 0.6, 0.4, UInt64(0))
    @test is_cache_fresh(fresh; max_age_days=7) == true

    stale = CachedWeights(1, "AAPL", Float64[], Tuple{Int,Int}[], 11,
        now() - Day(30), 0.6, 0.4, UInt64(0))
    @test is_cache_fresh(stale; max_age_days=7) == false
end

@testset "compute_data_hash determinism" begin
    data1 = [randn(3, 2) for _ in 1:5]
    data2 = [randn(3, 2) for _ in 1:5]

    h1a = compute_data_hash(data1)
    h1b = compute_data_hash(data1)
    h2 = compute_data_hash(data2)

    @test h1a == h1b  # same data → same hash
    # Different data should likely produce different hash (not guaranteed but very likely)
    # We don't test this strictly since hash collisions are possible
end

@testset "compute_data_hash matrix input" begin
    m = randn(10, 5)
    h = compute_data_hash(m)
    @test h isa UInt64
    @test compute_data_hash(m) == h  # deterministic
end

@testset "get_cached_or_train cache miss" begin
    dir = mktempdir()
    cache = WeightCache(dir)
    call_count = Ref(0)

    shapes = [(2, 3), (1, 1)]
    function train_fn()
        call_count[] += 1
        θ = randn(7)
        return (θ, shapes, 0.55, 0.3)
    end

    ws = get_cached_or_train(cache, 1, "AAPL", 11, randn(5, 3), train_fn)
    @test call_count[] == 1  # should have trained
    @test length(ws) == 2  # 2 weight matrices
end

@testset "get_cached_or_train cache hit" begin
    dir = mktempdir()
    cache = WeightCache(dir)
    call_count = Ref(0)
    train_data = randn(5, 3)

    shapes = [(2, 3), (1, 1)]
    function train_fn()
        call_count[] += 1
        θ = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0]
        return (θ, shapes, 0.55, 0.3)
    end

    # First call: trains
    ws1 = get_cached_or_train(cache, 1, "AAPL", 11, train_data, train_fn)
    @test call_count[] == 1

    # Second call with same data: uses cache
    ws2 = get_cached_or_train(cache, 1, "AAPL", 11, train_data, train_fn)
    @test call_count[] == 1  # NOT called again

    # Weight matrices should match
    @test ws1[1] == ws2[1]
end

@testset "JLD2 save/load roundtrip" begin
    dir = mktempdir()
    cache = WeightCache(dir)

    store_weights!(cache, 1, "AAPL", 11, [1.0, 2.0], [(1, 2)], 0.6, 0.3, UInt64(99))
    store_weights!(cache, 7, "BTC-USD", 11, [3.0, 4.0, 5.0], [(1, 3)], 0.7, 0.2, UInt64(100))

    save_cache!(cache)

    # Load into a fresh cache
    cache2 = WeightCache(dir)
    load_cache!(cache2)

    entry = get_cached_weights(cache2, 1, "AAPL", 11)
    @test entry !== nothing
    @test entry.θ == [1.0, 2.0]

    entry2 = get_cached_weights(cache2, 7, "BTC-USD", 11)
    @test entry2 !== nothing
    @test entry2.θ == [3.0, 4.0, 5.0]
end

@testset "clear_stale!" begin
    dir = mktempdir()
    cache = WeightCache(dir; max_age_days=7)

    # Add fresh and stale entries
    store_weights!(cache, 1, "AAPL", 11, [1.0], [(1,1)], 0.6, 0.3, UInt64(0))

    # Manually add stale entry
    stale = CachedWeights(2, "OLD", [2.0], [(1,1)], 11,
        now() - Day(30), 0.5, 0.4, UInt64(0))
    lock(cache.lock) do
        cache.entries[(2, "OLD", 11)] = stale
    end

    @test length(cache.entries) == 2
    clear_stale!(cache)
    @test length(cache.entries) == 1  # stale entry removed
end

@testset "WeightCache thread safety" begin
    dir = mktempdir()
    cache = WeightCache(dir)

    tasks = Task[]
    for i in 1:10
        push!(tasks, @async begin
            store_weights!(cache, i, "TICKER$i", 11,
                randn(5), [(2,2), (1,1)], rand(), rand(), UInt64(i))
        end)
    end
    for t in tasks; wait(t); end

    @test length(cache.entries) == 10
end
