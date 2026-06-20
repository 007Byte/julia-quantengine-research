# ── Performance Database — SQLite Persistence ─────────────────
# Persists trades, equity snapshots, and model performance across sessions.
# Defense-in-Depth: file permissions restricted, no raw SQL from user input.

using SQLite

"""Thread-safe database handle for trade persistence."""
mutable struct TradeDatabase
    db::SQLite.DB
    filepath::String
    lock::ReentrantLock
end

"""Initialize or open the trade database with schema creation."""
function TradeDatabase(dir::String; filename::String="quantengine.db")
    mkpath(dir)
    # Restrict directory permissions
    try; chmod(dir, 0o700); catch; end

    filepath = joinpath(dir, filename)
    db = SQLite.DB(filepath)

    # Restrict file permissions
    try; chmod(filepath, 0o600); catch; end

    # Enable WAL mode for better concurrent performance
    SQLite.execute(db, "PRAGMA journal_mode=WAL")
    SQLite.execute(db, "PRAGMA synchronous=NORMAL")

    # Create tables if they don't exist
    _create_schema!(db)

    return TradeDatabase(db, filepath, ReentrantLock())
end

function _create_schema!(db::SQLite.DB)
    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS trades (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            asset TEXT NOT NULL,
            direction TEXT NOT NULL,
            instrument TEXT,
            entry_price REAL NOT NULL,
            exit_price REAL NOT NULL,
            size_dollars REAL NOT NULL,
            size_fraction REAL,
            pnl REAL NOT NULL,
            pnl_pct REAL NOT NULL,
            hold_hours REAL,
            exit_reason TEXT,
            strategy TEXT,
            confidence REAL,
            expected_return REAL,
            execution_mode TEXT DEFAULT 'PAPER',
            created_at TEXT DEFAULT (datetime('now'))
        )
    """)

    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS equity_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            bankroll REAL NOT NULL,
            daily_pnl REAL NOT NULL,
            drawdown_pct REAL NOT NULL,
            n_positions INTEGER NOT NULL,
            portfolio_heat REAL NOT NULL,
            total_trades INTEGER NOT NULL,
            win_rate REAL NOT NULL,
            peak_bankroll REAL NOT NULL,
            created_at TEXT DEFAULT (datetime('now'))
        )
    """)

    SQLite.execute(db, """
        CREATE TABLE IF NOT EXISTS model_performance (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT NOT NULL,
            asset TEXT NOT NULL,
            model_name TEXT NOT NULL,
            model_id INTEGER,
            success INTEGER NOT NULL,
            accuracy REAL,
            probability REAL,
            signal TEXT,
            execution_time_ms REAL NOT NULL,
            created_at TEXT DEFAULT (datetime('now'))
        )
    """)

    # Indices for common queries
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS idx_trades_asset ON trades(asset)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS idx_trades_timestamp ON trades(timestamp)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS idx_equity_timestamp ON equity_snapshots(timestamp)")
    SQLite.execute(db, "CREATE INDEX IF NOT EXISTS idx_model_perf_name ON model_performance(model_name)")
end

"""Record a closed trade to the database (thread-safe)."""
function db_record_trade!(tdb::TradeDatabase, asset::String, direction::Symbol,
                          entry_price::Float64, exit_price::Float64,
                          size_dollars::Float64, pnl::Float64, pnl_pct::Float64;
                          instrument::String="spot", size_fraction::Float64=0.0,
                          hold_hours::Float64=0.0, exit_reason::String="",
                          strategy::String="", confidence::Float64=0.0,
                          expected_return::Float64=0.0,
                          execution_mode::String="PAPER")
    lock(tdb.lock) do
        SQLite.execute(tdb.db, """
            INSERT INTO trades (timestamp, asset, direction, instrument,
                entry_price, exit_price, size_dollars, size_fraction,
                pnl, pnl_pct, hold_hours, exit_reason, strategy,
                confidence, expected_return, execution_mode)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (Dates.format(now(), "yyyy-mm-ddTHH:MM:SS"),
              asset, string(direction), instrument,
              entry_price, exit_price, size_dollars, size_fraction,
              pnl, pnl_pct, hold_hours, exit_reason, strategy,
              confidence, expected_return, execution_mode))
    end
end

"""Record an equity snapshot (thread-safe)."""
function db_record_snapshot!(tdb::TradeDatabase, tracker::PositionTracker)
    snap = tracker_snapshot(tracker)
    lock(tdb.lock) do
        SQLite.execute(tdb.db, """
            INSERT INTO equity_snapshots (timestamp, bankroll, daily_pnl,
                drawdown_pct, n_positions, portfolio_heat, total_trades,
                win_rate, peak_bankroll)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (Dates.format(now(), "yyyy-mm-ddTHH:MM:SS"),
              snap.bankroll, snap.daily_pnl, snap.drawdown,
              snap.n_positions, 0.0, snap.total_trades,
              snap.win_rate, snap.bankroll + snap.daily_pnl))
    end
end

"""Record model performance from a RALPH log entry (thread-safe)."""
function db_record_model_perf!(tdb::TradeDatabase, asset::String, log_entry::RalphLog;
                                model_id::Int=0, accuracy::Float64=NaN,
                                probability::Float64=NaN, signal::String="")
    lock(tdb.lock) do
        SQLite.execute(tdb.db, """
            INSERT INTO model_performance (timestamp, asset, model_name, model_id,
                success, accuracy, probability, signal, execution_time_ms)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (Dates.format(now(), "yyyy-mm-ddTHH:MM:SS"),
              asset, log_entry.model_name, model_id,
              log_entry.success ? 1 : 0,
              isnan(accuracy) ? nothing : accuracy,
              isnan(probability) ? nothing : probability,
              signal, log_entry.time_ms))
    end
end

"""Execute a query and return results as a Vector of NamedTuples (materialized)."""
function _query(db::SQLite.DB, sql::String, args=())
    stmt = SQLite.DBInterface.execute(db, sql, args)
    rows = NamedTuple[]
    for row in stmt
        nms = Tuple(propertynames(row))
        vals = Tuple(getproperty(row, n) for n in nms)
        push!(rows, NamedTuple{nms}(vals))
    end
    return rows
end

"""Load the last saved state for session resume."""
function db_load_last_state(tdb::TradeDatabase)
    lock(tdb.lock) do
        # Get latest equity snapshot using materialized query
        rows = _query(tdb.db, """
            SELECT bankroll, peak_bankroll, total_trades, win_rate, drawdown_pct
            FROM equity_snapshots ORDER BY id DESC LIMIT 1
        """)

        if isempty(rows)
            return nothing
        end

        row = first(rows)
        return (bankroll=Float64(something(row.bankroll, 0.0)),
                peak_bankroll=Float64(something(row.peak_bankroll, 0.0)),
                total_trades=something(row.total_trades, 0),
                win_rate=Float64(something(row.win_rate, 0.0)),
                drawdown=Float64(something(row.drawdown_pct, 0.0)))
    end
end

"""Close the database connection."""
function db_close!(tdb::TradeDatabase)
    lock(tdb.lock) do
        # SQLite.jl handles finalization automatically
        # but we can force a checkpoint for WAL mode
        try
            SQLite.execute(tdb.db, "PRAGMA wal_checkpoint(TRUNCATE)")
        catch; end
    end
end
