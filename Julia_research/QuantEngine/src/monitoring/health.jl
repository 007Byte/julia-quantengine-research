# ── Health Check, Monitoring & Dashboard Endpoint ─────────────
# HTTP server exposing /health, /metrics, /dashboard, and JSON APIs.

"""Start a health check and dashboard HTTP server on the given port (non-blocking)."""
function start_health_server(tracker::PositionTracker;
                              port::Int=8080,
                              trade_db::Union{TradeDatabase, Nothing}=nothing,
                              adaptive_engine::Union{AdaptiveEngine, Nothing}=nothing,
                              verbose::Bool=true)
    server_task = @async begin
        try
            HTTP.serve("0.0.0.0", port) do request
                path = request.target
                if path == "/health"
                    _handle_health(tracker)
                elseif path == "/metrics"
                    _handle_metrics(tracker)
                elseif path == "/dashboard"
                    _handle_dashboard()
                elseif path == "/api/positions"
                    _handle_api_positions(tracker)
                elseif path == "/api/goal"
                    _handle_api_goal(adaptive_engine)
                elseif path == "/api/equity"
                    _handle_api_equity(trade_db)
                elseif path == "/api/trades"
                    _handle_api_trades(trade_db)
                elseif path == "/api/models"
                    _handle_api_models(trade_db)
                elseif path == "/api/daily_pnl"
                    _handle_api_daily_pnl(trade_db)
                elseif path == "/api/stats"
                    _handle_api_stats(trade_db)
                else
                    HTTP.Response(404, "Not Found")
                end
            end
        catch e
            if verbose
                @warn "Health server error: $(sprint(showerror, e)[1:min(60,end)])"
            end
        end
    end
    verbose && println("  ✓ Health server started on port $port")
    return server_task
end

"""Handle /health endpoint — returns 200 + JSON status."""
function _handle_health(tracker::PositionTracker)
    snap = tracker_snapshot(tracker)
    body = JSON.json(Dict(
        "status" => "ok",
        "timestamp" => Dates.format(now(), "yyyy-mm-ddTHH:MM:SS"),
        "bankroll" => round(snap.bankroll, digits=2),
        "daily_pnl" => round(snap.daily_pnl, digits=2),
        "positions" => snap.n_positions,
        "trades" => snap.total_trades,
        "cooling" => snap.cooling
    ))
    return HTTP.Response(200, ["Content-Type" => "application/json"], body)
end

"""Handle /metrics endpoint — returns Prometheus-format metrics."""
function _handle_metrics(tracker::PositionTracker)
    snap = tracker_snapshot(tracker)

    lines = [
        "# HELP quantengine_bankroll Current bankroll in dollars",
        "# TYPE quantengine_bankroll gauge",
        "quantengine_bankroll $(round(snap.bankroll, digits=2))",
        "",
        "# HELP quantengine_daily_pnl Daily PnL in dollars",
        "# TYPE quantengine_daily_pnl gauge",
        "quantengine_daily_pnl $(round(snap.daily_pnl, digits=2))",
        "",
        "# HELP quantengine_positions_open Number of open positions",
        "# TYPE quantengine_positions_open gauge",
        "quantengine_positions_open $(snap.n_positions)",
        "",
        "# HELP quantengine_trades_total Total trades executed",
        "# TYPE quantengine_trades_total counter",
        "quantengine_trades_total $(snap.total_trades)",
        "",
        "# HELP quantengine_win_rate Win rate percentage",
        "# TYPE quantengine_win_rate gauge",
        "quantengine_win_rate $(round(snap.win_rate, digits=1))",
        "",
        "# HELP quantengine_drawdown_pct Current drawdown percentage",
        "# TYPE quantengine_drawdown_pct gauge",
        "quantengine_drawdown_pct $(round(snap.drawdown, digits=1))",
        "",
        "# HELP quantengine_consecutive_losses Current consecutive losses",
        "# TYPE quantengine_consecutive_losses gauge",
        "quantengine_consecutive_losses $(snap.consecutive_losses)",
        "",
        "# HELP quantengine_cooling Cooling period active (0/1)",
        "# TYPE quantengine_cooling gauge",
        "quantengine_cooling $(snap.cooling ? 1 : 0)",
    ]

    body = join(lines, "\n") * "\n"
    return HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8"], body)
end

"""Handle /dashboard — serves the HTML dashboard."""
function _handle_dashboard()
    html = _dashboard_html()
    return HTTP.Response(200, ["Content-Type" => "text/html; charset=utf-8"], html)
end

"""Handle /api/positions — returns full tracker snapshot as JSON."""
function _handle_api_positions(tracker::PositionTracker)
    snap = tracker_snapshot(tracker)
    body = JSON.json(Dict(
        "bankroll" => round(snap.bankroll, digits=2),
        "daily_pnl" => round(snap.daily_pnl, digits=2),
        "n_positions" => snap.n_positions,
        "total_trades" => snap.total_trades,
        "win_rate" => round(snap.win_rate, digits=1),
        "drawdown" => round(snap.drawdown, digits=1),
        "consecutive_losses" => snap.consecutive_losses,
        "cooling" => snap.cooling
    ))
    return HTTP.Response(200, ["Content-Type" => "application/json"], body)
end

"""Handle /api/goal — returns goal progress as JSON."""
function _handle_api_goal(engine::Union{AdaptiveEngine, Nothing})
    if engine === nothing
        return HTTP.Response(200, ["Content-Type" => "application/json"],
                             JSON.json(Dict("error" => "No adaptive engine configured")))
    end
    progress = goal_progress(engine)
    # Replace Inf/NaN with null-safe values for JSON
    _safe(x) = (isnan(x) || isinf(x)) ? -1.0 : x
    body = JSON.json(Dict(
        "completion_pct" => round(progress.completion_pct, digits=4),
        "total_return_pct" => round(_safe(progress.total_return_pct), digits=2),
        "daily_growth_pct" => round(_safe(progress.daily_growth_pct), digits=4),
        "current_bankroll" => round(progress.current_bankroll, digits=2),
        "goal_target" => progress.target,
        "on_track" => progress.on_track,
        "projected_days" => round(Int, clamp(_safe(progress.days_remaining), -1, 999999)),
        "elapsed_days" => round(Int, _safe(progress.days_elapsed))
    ))
    return HTTP.Response(200, ["Content-Type" => "application/json"], body)
end

"""Handle /api/equity — returns equity curve as JSON array."""
function _handle_api_equity(db::Union{TradeDatabase, Nothing})
    if db === nothing
        return HTTP.Response(200, ["Content-Type" => "application/json"], "[]")
    end
    try
        curve = db_get_equity_curve(db)
        entries = [Dict("date" => string(c.timestamp), "bankroll" => round(c.bankroll, digits=2))
                   for c in curve]
        return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(entries))
    catch
        return HTTP.Response(200, ["Content-Type" => "application/json"], "[]")
    end
end

"""Handle /api/trades — returns recent trades as JSON array."""
function _handle_api_trades(db::Union{TradeDatabase, Nothing})
    if db === nothing
        return HTTP.Response(200, ["Content-Type" => "application/json"], "[]")
    end
    try
        trades = db_get_trades(db; limit=50)
        entries = [Dict("asset" => t.asset, "direction" => string(t.direction),
                        "entry_price" => round(t.entry_price, digits=2),
                        "exit_price" => round(t.exit_price, digits=2),
                        "pnl" => round(t.pnl, digits=2),
                        "size" => round(t.size, digits=2),
                        "exit_reason" => t.exit_reason)
                   for t in trades]
        return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(entries))
    catch
        return HTTP.Response(200, ["Content-Type" => "application/json"], "[]")
    end
end

"""Handle /api/models — returns model leaderboard as JSON."""
function _handle_api_models(db::Union{TradeDatabase, Nothing})
    if db === nothing
        return HTTP.Response(200, ["Content-Type" => "application/json"], "[]")
    end
    try
        leaders = db_get_model_leaderboard(db)
        return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(leaders))
    catch
        return HTTP.Response(200, ["Content-Type" => "application/json"], "[]")
    end
end

"""Handle /api/daily_pnl — returns daily PnL breakdown as JSON."""
function _handle_api_daily_pnl(db::Union{TradeDatabase, Nothing})
    if db === nothing
        return HTTP.Response(200, ["Content-Type" => "application/json"], "[]")
    end
    try
        pnl = db_get_daily_pnl(db)
        return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(pnl))
    catch
        return HTTP.Response(200, ["Content-Type" => "application/json"], "[]")
    end
end

"""Handle /api/stats — returns lifetime stats as JSON."""
function _handle_api_stats(db::Union{TradeDatabase, Nothing})
    if db === nothing
        return HTTP.Response(200, ["Content-Type" => "application/json"], "{}")
    end
    try
        stats = db_get_lifetime_stats(db)
        return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(stats))
    catch
        return HTTP.Response(200, ["Content-Type" => "application/json"], "{}")
    end
end
