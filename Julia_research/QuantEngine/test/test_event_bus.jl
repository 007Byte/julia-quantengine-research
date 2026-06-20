# ── Event Bus Tests ───────────────────────────────────────────

using QuantEngine: PipelineEventBus, create_event_bus, emit_event!,
                   take_event!, event_bus_stats, close_event_bus!,
                   PipelineEvent

@testset "create_event_bus" begin
    bus = create_event_bus(buffer_size=10)
    stats = event_bus_stats(bus)
    @test stats.emitted == 0
    @test stats.processed == 0
    @test stats.dropped == 0
    close_event_bus!(bus)
end

@testset "emit and take event" begin
    bus = create_event_bus(buffer_size=10)
    event = PipelineEvent(now(), "AAPL", :stock, :price_jump,
                          Dict{String,Any}("change" => 0.05), 150.0, 1e6)

    emit_event!(bus, event)
    stats = event_bus_stats(bus)
    @test stats.emitted == 1

    result = take_event!(bus; timeout_ms=1000)
    @test result !== nothing
    @test result.asset == "AAPL"
    @test result.trigger_type == :price_jump

    stats = event_bus_stats(bus)
    @test stats.processed == 1
    close_event_bus!(bus)
end

@testset "take_event! timeout" begin
    bus = create_event_bus(buffer_size=10)

    # No events → should timeout
    t0 = time()
    result = take_event!(bus; timeout_ms=200)
    elapsed = time() - t0

    @test result === nothing
    @test elapsed >= 0.15  # should have waited ~200ms
    @test elapsed < 1.0    # but not too long
    close_event_bus!(bus)
end

@testset "emit multiple events" begin
    bus = create_event_bus(buffer_size=50)

    for i in 1:10
        event = PipelineEvent(now(), "ASSET$i", :stock, :volume_spike,
                              Dict{String,Any}(), 100.0 + i, Float64(i * 1e6))
        emit_event!(bus, event)
    end

    stats = event_bus_stats(bus)
    @test stats.emitted == 10
    @test stats.pending == 10

    # Take all events
    for i in 1:10
        result = take_event!(bus; timeout_ms=100)
        @test result !== nothing
        @test result.asset == "ASSET$i"
    end

    stats = event_bus_stats(bus)
    @test stats.processed == 10
    close_event_bus!(bus)
end

@testset "concurrent producers" begin
    bus = create_event_bus(buffer_size=100)

    tasks = Task[]
    for i in 1:5
        push!(tasks, @async begin
            for j in 1:4
                event = PipelineEvent(now(), "T$(i)_$(j)", :stock, :manual,
                                      Dict{String,Any}(), 100.0, 1e6)
                emit_event!(bus, event)
            end
        end)
    end
    for t in tasks; wait(t); end

    stats = event_bus_stats(bus)
    @test stats.emitted == 20
    close_event_bus!(bus)
end
