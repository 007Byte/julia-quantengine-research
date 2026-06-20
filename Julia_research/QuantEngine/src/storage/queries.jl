# ── Database Query Functions ──────────────────────────────────
# _query() helper is defined in database.jl (loaded first)

"""Get trade history, optionally filtered by asset and date range."""
function db_get_trades(tdb::TradeDatabase;
                       asset::String="", limit::Int=100)
    lock(tdb.lock) do
        if isempty(asset)
            return _query(tdb.db, "SELECT * FROM trades ORDER BY id DESC LIMIT ?", (limit,))
        else
            return _query(tdb.db, "SELECT * FROM trades WHERE asset = ? ORDER BY id DESC LIMIT ?",
                          (asset, limit))
        end
    end
end

"""Get the equity curve from snapshots."""
function db_get_equity_curve(tdb::TradeDatabase; limit::Int=10000)
    lock(tdb.lock) do
        return _query(tdb.db, """
            SELECT timestamp, bankroll, daily_pnl, drawdown_pct
            FROM equity_snapshots ORDER BY id ASC LIMIT ?
        """, (limit,))
    end
end

"""Get model performance leaderboard (average accuracy, sorted)."""
function db_get_model_leaderboard(tdb::TradeDatabase)
    lock(tdb.lock) do
        return _query(tdb.db, """
            SELECT model_name,
                   COUNT(*) as n_runs,
                   AVG(CASE WHEN accuracy IS NOT NULL THEN accuracy END) as avg_accuracy,
                   SUM(success) as n_success,
                   AVG(execution_time_ms) as avg_time_ms
            FROM model_performance
            GROUP BY model_name
            ORDER BY avg_accuracy DESC
        """)
    end
end

"""Get daily PnL summary."""
function db_get_daily_pnl(tdb::TradeDatabase; days::Int=30)
    lock(tdb.lock) do
        return _query(tdb.db, """
            SELECT DATE(timestamp) as trade_date,
                   COUNT(*) as n_trades,
                   SUM(pnl) as total_pnl,
                   AVG(pnl_pct) as avg_pnl_pct,
                   SUM(CASE WHEN pnl > 0 THEN 1 ELSE 0 END) as wins,
                   SUM(CASE WHEN pnl <= 0 THEN 1 ELSE 0 END) as losses
            FROM trades
            GROUP BY DATE(timestamp)
            ORDER BY trade_date DESC
            LIMIT ?
        """, (days,))
    end
end

"""Get total lifetime statistics."""
function db_get_lifetime_stats(tdb::TradeDatabase)
    lock(tdb.lock) do
        rows = _query(tdb.db, """
            SELECT COUNT(*) as total_trades,
                   SUM(pnl) as total_pnl,
                   AVG(pnl) as avg_pnl,
                   SUM(CASE WHEN pnl > 0 THEN 1 ELSE 0 END) as wins,
                   SUM(CASE WHEN pnl <= 0 THEN 1 ELSE 0 END) as losses,
                   MAX(pnl) as best_trade,
                   MIN(pnl) as worst_trade,
                   AVG(hold_hours) as avg_hold_hours
            FROM trades
        """)

        if isempty(rows)
            return (total_trades=0, total_pnl=0.0, avg_pnl=0.0,
                    wins=0, losses=0, win_rate=0.0,
                    best_trade=0.0, worst_trade=0.0, avg_hold_hours=0.0)
        end

        row = first(rows)
        _f(v) = v === missing ? 0.0 : Float64(v)
        _i(v) = v === missing ? 0 : Int(v)
        total = _i(row.total_trades)
        wins = _i(row.wins)
        return (total_trades=total,
                total_pnl=_f(row.total_pnl),
                avg_pnl=_f(row.avg_pnl),
                wins=wins, losses=_i(row.losses),
                win_rate=total > 0 ? Float64(wins) / total * 100.0 : 0.0,
                best_trade=_f(row.best_trade),
                worst_trade=_f(row.worst_trade),
                avg_hold_hours=_f(row.avg_hold_hours))
    end
end
