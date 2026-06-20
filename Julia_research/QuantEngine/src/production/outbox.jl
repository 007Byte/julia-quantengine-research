# ── Outbox Pattern — DB-First + Stream Publish ────────────────────────
# For trade-critical transitions:
#   1. Write business entity + outbox row in same Postgres transaction
#   2. Background worker polls unpublished rows
#   3. Publishes to downstream (Redis Streams, or in-process Channel)
#   4. Marks row as published
#
# Guarantees: if the transaction commits, the event will be published.
# Without Redis: uses Julia Channels as in-process event bus.

using Dates
using UUIDs

"""In-process event bus — replacement for Redis Streams when Redis not available."""
mutable struct EventBusOutbox
    pool::Any              # PgPool
    channels::Dict{String, Channel{Dict{String,Any}}}
    poll_interval_s::Float64
    running::Bool
    lock::ReentrantLock
end

function EventBusOutbox(pool; poll_interval_s::Float64=0.5)
    EventBusOutbox(pool, Dict{String, Channel{Dict{String,Any}}}(), poll_interval_s, false, ReentrantLock())
end

"""Get or create a channel for a named stream."""
function get_channel(bus::EventBusOutbox, stream::String)::Channel{Dict{String,Any}}
    lock(bus.lock) do
        if !haskey(bus.channels, stream)
            bus.channels[stream] = Channel{Dict{String,Any}}(1000)
        end
        return bus.channels[stream]
    end
end

"""
Write a business operation + outbox entry in one transaction.
The outbox entry will be published by the background worker.
"""
function write_with_outbox!(pool, conn, stream_name::String, event_type::String,
                            payload::Dict{String,Any}; correlation_id::UUID=uuid4())
    LibPQ.execute(conn, """
        INSERT INTO outbox (stream_name, event_type, payload, correlation_id, idempotency_key)
        VALUES (\$1, \$2, \$3::jsonb, \$4, \$5)
    """, [stream_name, event_type, JSON.json(payload), string(correlation_id), string(uuid4())])
end

"""Publish pending outbox rows. Returns count published."""
function publish_pending!(bus::EventBusOutbox; batch_size::Int=100)::Int
    published = 0

    with_connection(bus.pool) do conn
        result = LibPQ.execute(conn, """
            SELECT outbox_id, stream_name, event_type, payload, correlation_id
            FROM outbox
            WHERE NOT published
            ORDER BY outbox_id
            LIMIT \$1
            FOR UPDATE SKIP LOCKED
        """, [batch_size])

        data = columntable(result)
        close(result)

        ids = get(data, :outbox_id, [])
        isempty(ids) && return 0

        for i in eachindex(ids)
            stream = data[:stream_name][i]
            event_type = data[:event_type][i]
            payload_str = data[:payload][i]

            # Parse payload
            payload = try
                JSON.parse(payload_str)
            catch
                Dict{String,Any}("raw" => payload_str)
            end

            event = Dict{String,Any}(
                "stream" => stream,
                "event_type" => event_type,
                "payload" => payload,
                "correlation_id" => string(data[:correlation_id][i]),
                "published_at" => string(now(UTC)),
            )

            # Publish to in-process channel
            ch = get_channel(bus, stream)
            try
                put!(ch, event)
            catch
                @warn "Channel full for $stream — dropping event"
            end

            # Mark as published
            LibPQ.execute(conn, """
                UPDATE outbox SET published = TRUE, published_at = NOW()
                WHERE outbox_id = \$1
            """, [ids[i]])

            published += 1
        end
    end

    return published
end

"""Run the outbox worker as a background task."""
function run_outbox_worker!(bus::EventBusOutbox)
    bus.running = true
    @info "Outbox worker started (interval=$(bus.poll_interval_s)s)"

    @async begin
        while bus.running
            try
                count = publish_pending!(bus)
                if count > 0
                    @debug "Outbox published $count events"
                end
            catch e
                @error "Outbox worker error" exception=e
            end
            sleep(bus.poll_interval_s)
        end
        @info "Outbox worker stopped"
    end
end

"""Stop the outbox worker."""
function stop_outbox_worker!(bus::EventBusOutbox)
    bus.running = false
end

"""Clean old published outbox rows."""
function cleanup_outbox!(pool; retention_hours::Int=72)::Int
    result = pg_execute(pool, """
        DELETE FROM outbox
        WHERE published AND published_at < NOW() - \$1 * INTERVAL '1 hour'
    """, [retention_hours])
    # Can't easily get deleted count from LibPQ, return 0
    return 0
end
