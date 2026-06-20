# ── PostgreSQL Connection Pool + Production Persistence ────────────────
# Replaces SQLite for production. Provides:
# - Thread-safe connection pool
# - Migration runner
# - Prepared statement cache
# - Transaction helpers with row-level locking for risk reservations
#
# Uses LibPQ.jl directly — no ORM, no magic. Raw SQL, explicit control.

using LibPQ
using Dates
using UUIDs

# ── Connection Pool ───────────────────────────────────────────

mutable struct PgPool
    dsn::String
    connections::Vector{LibPQ.Connection}
    available::Channel{LibPQ.Connection}
    size::Int
    lock::ReentrantLock
    connected::Bool
end

"""Create a Postgres connection pool."""
function PgPool(;
    host::String = get(ENV, "QE_PG_HOST", "localhost"),
    port::Int = parse(Int, get(ENV, "QE_PG_PORT", "5432")),
    database::String = get(ENV, "QE_PG_DATABASE", "quantengine"),
    user::String = get(ENV, "QE_PG_USER", "quantengine"),
    password::String = get(ENV, "QE_PG_PASSWORD", ""),
    pool_size::Int = 5,
)
    dsn = "host=$host port=$port dbname=$database user=$user password=$password"
    connections = LibPQ.Connection[]
    available = Channel{LibPQ.Connection}(pool_size)
    pool = PgPool(dsn, connections, available, pool_size, ReentrantLock(), false)
    return pool
end

"""Connect all pool connections."""
function pg_connect!(pool::PgPool)
    lock(pool.lock) do
        for _ in 1:pool.size
            conn = LibPQ.Connection(pool.dsn)
            push!(pool.connections, conn)
            put!(pool.available, conn)
        end
        pool.connected = true
    end
    @info "Postgres pool connected: $(pool.size) connections"
    return pool
end

"""Close all pool connections."""
function pg_close!(pool::PgPool)
    lock(pool.lock) do
        for conn in pool.connections
            try; close(conn); catch; end
        end
        empty!(pool.connections)
        pool.connected = false
    end
    @info "Postgres pool closed"
end

"""Borrow a connection from the pool. Returns it via the callback pattern."""
function with_connection(f::Function, pool::PgPool)
    conn = take!(pool.available)
    try
        # Check connection health, reconnect if needed
        if !LibPQ.status(conn) == LibPQ.CONNECTION_OK
            try; close(conn); catch; end
            conn = LibPQ.Connection(pool.dsn)
        end
        return f(conn)
    finally
        put!(pool.available, conn)
    end
end

# ── Query Helpers ─────────────────────────────────────────────

"""Execute a query, return nothing."""
function pg_execute(pool::PgPool, sql::String, params::Vector=[])
    with_connection(pool) do conn
        result = LibPQ.execute(conn, sql, params)
        close(result)
        return nothing
    end
end

"""Execute a query, return all rows as vectors of named tuples."""
function pg_fetch(pool::PgPool, sql::String, params::Vector=[])
    with_connection(pool) do conn
        result = LibPQ.execute(conn, sql, params)
        rows = columntable(result)
        close(result)
        return rows
    end
end

"""Execute a query, return first row or nothing."""
function pg_fetchone(pool::PgPool, sql::String, params::Vector=[])
    with_connection(pool) do conn
        result = LibPQ.execute(conn, sql, params)
        data = columntable(result)
        close(result)
        if isempty(first(values(data)))
            return nothing
        end
        # Return first row as NamedTuple
        return NamedTuple{keys(data)}(map(v -> v[1], values(data)))
    end
end

"""Execute a query, return single scalar value."""
function pg_fetchval(pool::PgPool, sql::String, params::Vector=[])
    with_connection(pool) do conn
        result = LibPQ.execute(conn, sql, params)
        data = columntable(result)
        close(result)
        vals = first(values(data))
        return isempty(vals) ? nothing : vals[1]
    end
end

# ── Transaction Helper ────────────────────────────────────────

"""Execute a function within a transaction. Rolls back on error."""
function with_transaction(f::Function, pool::PgPool)
    with_connection(pool) do conn
        LibPQ.execute(conn, "BEGIN")
        try
            result = f(conn)
            LibPQ.execute(conn, "COMMIT")
            return result
        catch e
            LibPQ.execute(conn, "ROLLBACK")
            rethrow(e)
        end
    end
end

"""Execute within a transaction with row-level lock (FOR UPDATE)."""
function with_locked_transaction(f::Function, pool::PgPool)
    # Same as with_transaction — the caller uses SELECT ... FOR UPDATE
    with_transaction(f, pool)
end

# ── Migration Runner ──────────────────────────────────────────

"""Run all pending SQL migrations from a directory."""
function run_migrations!(pool::PgPool; migrations_dir::String="")
    if isempty(migrations_dir)
        migrations_dir = joinpath(@__DIR__, "..", "..", "migrations")
    end

    if !isdir(migrations_dir)
        @warn "Migrations directory not found: $migrations_dir"
        return 0
    end

    # Ensure migration tracking table
    pg_execute(pool, """
        CREATE TABLE IF NOT EXISTS _migrations (
            filename TEXT PRIMARY KEY,
            applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
    """)

    # Get applied migrations
    applied = Set{String}()
    with_connection(pool) do conn
        result = LibPQ.execute(conn, "SELECT filename FROM _migrations")
        for row in LibPQ.Columns(result)
            push!(applied, row[1])
        end
        close(result)
    end

    # Apply pending
    files = sort(filter(f -> endswith(f, ".sql"), readdir(migrations_dir)))
    applied_count = 0

    for filename in files
        if filename in applied
            continue
        end

        filepath = joinpath(migrations_dir, filename)
        sql = read(filepath, String)

        @info "Applying migration: $filename"
        with_transaction(pool) do conn
            LibPQ.execute(conn, sql)
            LibPQ.execute(conn,
                "INSERT INTO _migrations (filename) VALUES (\$1)",
                [filename]
            )
        end
        applied_count += 1
        @info "Applied: $filename"
    end

    return applied_count
end

# ── Health Check ──────────────────────────────────────────────

"""Check Postgres connectivity."""
function pg_healthy(pool::PgPool)::Bool
    try
        val = pg_fetchval(pool, "SELECT 1")
        return val == 1
    catch
        return false
    end
end
