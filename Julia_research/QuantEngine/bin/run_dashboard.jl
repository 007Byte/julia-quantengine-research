#!/usr/bin/env julia
# ── QuantEngine Standalone Dashboard ──────────────────────────
# Serves the web dashboard without running the trading pipeline.
# Connects to an existing SQLite database for historical data.
#
# Usage:
#   julia --project=. bin/run_dashboard.jl
#   julia --project=. bin/run_dashboard.jl --port 8080 --db ~/.quantengine/db
#
# Then open http://localhost:8080/dashboard

using QuantEngine

function main()
    port = 8080
    db_dir = expanduser("~/.quantengine/db")

    for i in eachindex(ARGS)
        if ARGS[i] == "--port" && i < length(ARGS)
            port = parse(Int, ARGS[i+1])
        elseif ARGS[i] == "--db" && i < length(ARGS)
            db_dir = ARGS[i+1]
        end
    end

    # Initialize minimal subsystems
    bankroll = parse(Float64, get(ENV, "QE_INITIAL_BANKROLL", "10000"))
    tracker = PositionTracker(bankroll)

    # Connect to database if it exists
    trade_db = nothing
    if isdir(db_dir) || isfile(joinpath(db_dir, "quantengine.db"))
        try
            trade_db = TradeDatabase(db_dir)
            last_state = db_load_last_state(trade_db)
            if last_state !== nothing
                lock(tracker.lock) do
                    tracker.bankroll = last_state.bankroll
                    tracker.peak_bankroll = last_state.peak_bankroll
                    tracker.total_trades = round(Int, last_state.total_trades)
                end
                println("  Loaded from database: \$$(round(last_state.bankroll, digits=2)) ($(round(Int, last_state.total_trades)) trades)")
            end
        catch e
            @warn "Could not connect to database: $(sprint(showerror, e)[1:min(60,end)])"
        end
    else
        println("  No database found at $db_dir — showing empty dashboard")
    end

    # Initialize goal tracker
    adaptive_engine = AdaptiveEngine(
        goal_target=parse(Float64, get(ENV, "QE_GOAL_TARGET", "10000000")),
        initial_bankroll=tracker.bankroll
    )

    println()
    println("╔══════════════════════════════════════════════════════════════╗")
    println("║     QuantEngine Dashboard — Standalone Viewer              ║")
    println("╚══════════════════════════════════════════════════════════════╝")
    println("  URL:  http://localhost:$port/dashboard")
    println("  DB:   $db_dir")
    println()
    println("  Press Ctrl+C to stop")
    println()

    # Start server (blocking)
    start_health_server(tracker; port=port, trade_db=trade_db,
                        adaptive_engine=adaptive_engine, verbose=true)

    # Keep alive
    while true
        sleep(60)
    end
end

main()
