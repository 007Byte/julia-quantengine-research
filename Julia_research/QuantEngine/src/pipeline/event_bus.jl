# ── Event Bus — Channel-Based Pipeline Triggers ──────────────
# Replaces polling with real-time event delivery from WebSocket/X feeds.
# Pipeline reacts to events as they arrive (sub-second), with polling fallback.

"""Statistics for the event bus."""
mutable struct EventBusStats
    events_emitted::Int
    events_processed::Int
    events_dropped::Int
    lock::ReentrantLock
end

EventBusStats() = EventBusStats(0, 0, 0, ReentrantLock())

"""Channel-based event bus for real-time pipeline triggers."""
mutable struct PipelineEventBus
    channel::Channel{PipelineEvent}
    stats::EventBusStats
end

"""Create a bounded event bus."""
function create_event_bus(; buffer_size::Int=100)
    PipelineEventBus(Channel{PipelineEvent}(buffer_size), EventBusStats())
end

"""Emit an event to the bus (non-blocking, drops if full)."""
function emit_event!(bus::PipelineEventBus, event::PipelineEvent)
    lock(bus.stats.lock) do
        bus.stats.events_emitted += 1
    end
    if isready(bus.channel) || isopen(bus.channel)
        try
            if !isfull_channel(bus.channel)
                put!(bus.channel, event)
            else
                lock(bus.stats.lock) do
                    bus.stats.events_dropped += 1
                end
            end
        catch
            lock(bus.stats.lock) do
                bus.stats.events_dropped += 1
            end
        end
    end
end

"""Check if channel is full (approximate)."""
function isfull_channel(ch::Channel)
    return Base.n_avail(ch) >= ch.sz_max
end

"""
    take_event!(bus; timeout_ms) → PipelineEvent or nothing

Blocking take with timeout. Returns event immediately if available,
or nothing after timeout_ms. This replaces sleep() in the main loop.
"""
function take_event!(bus::PipelineEventBus; timeout_ms::Int=5000)
    result = Ref{Union{PipelineEvent, Nothing}}(nothing)

    # Start a taker task
    t = @async try
        result[] = take!(bus.channel)
    catch e
        if !(e isa InvalidStateException)
            rethrow(e)
        end
    end

    # Wait with timeout
    deadline = time() + timeout_ms / 1000.0
    while !istaskdone(t) && time() < deadline
        sleep(0.05)  # 50ms poll resolution
    end

    if result[] !== nothing
        lock(bus.stats.lock) do
            bus.stats.events_processed += 1
        end
    end

    return result[]
end

"""Get event bus statistics (thread-safe)."""
function event_bus_stats(bus::PipelineEventBus)
    lock(bus.stats.lock) do
        return (emitted=bus.stats.events_emitted,
                processed=bus.stats.events_processed,
                dropped=bus.stats.events_dropped,
                pending=Base.n_avail(bus.channel))
    end
end

"""Close the event bus."""
function close_event_bus!(bus::PipelineEventBus)
    try; close(bus.channel); catch; end
end
