# ── 24/7 Event Loop — Money Printing Machine ─────────────────

"""
    run_money_printer(assets; config, db_dir, use_websockets) → never returns (runs forever)

The main 24/7 loop: poll → detect triggers → run pipeline → execute → compound.
Optionally persists all trades and snapshots to SQLite via TradeDatabase.
When use_websockets=true, launches real-time feeds (Binance for crypto,
Polygon.io for stocks) alongside polling as a fallback.
"""
function run_money_printer(assets::Vector{String};
                           config::PipelineConfig=load_pipeline_config(),
                           db_dir::String="",
                           use_websockets::Bool=false)
    # Validate API keys for each asset type
    for asset in assets
        validate_api_keys(detect_asset_type(asset))
    end

    # Initialize subsystems
    exchange = PaperExchange(config.initial_bankroll)
    tracker  = PositionTracker(config.initial_bankroll)
    audit_dir = joinpath(resolve_output_base(), "audit")
    audit    = AuditLogger(audit_dir)
    rate_limiters = create_rate_limiters()
    history  = RollingHistory(max_entries=1000)

    # ── Phase 3: Initialize Adaptive Engine (Goal Tracker) ──────
    adaptive_engine = AdaptiveEngine(
        goal_target=parse(Float64, get(ENV, "QE_GOAL_TARGET", "10000000")),
        initial_bankroll=config.initial_bankroll
    )

    # Launch X (Twitter) stream (optional — requires QE_X_BEARER_TOKEN)
    tweet_buffer = TweetBuffer(max_size=1000)
    feed_tasks = Task[]
    if haskey(ENV, "QE_X_BEARER_TOKEN") && !isempty(get(ENV, "QE_X_BEARER_TOKEN", ""))
        x_keywords = vcat(
            [uppercase(replace(a, "-USD" => "", "poly:" => "")) for a in assets],
            ["crypto", "stocks", "trading", "whale"]
        )
        try
            x_task = @async start_x_stream(x_keywords, assets, tweet_buffer;
                callback=(asset, sentiment, text) -> begin
                    if abs(sentiment) > 0.5
                        ts = Dates.format(now(), "HH:MM:SS")
                        emoji = sentiment > 0 ? "+" : "-"
                        println("  [$ts] X: $asset $(emoji)$(round(abs(sentiment), digits=2)) — $(first(text, 60))")
                    end
                end)
            push!(feed_tasks, x_task)
            println("  ✓ X stream launched for $(join(x_keywords[1:min(4,end)], ", "))...")
        catch e
            @warn "X stream failed to start: $(sprint(showerror, e)[1:min(60,end)])"
        end
    end

    # Launch WebSocket feeds (optional — runs alongside polling fallback)
    if use_websockets
        crypto_assets = filter(a -> detect_asset_type(a) == :crypto, assets)
        stock_assets = filter(a -> detect_asset_type(a) == :stock, assets)

        if !isempty(crypto_assets)
            try
                feed = BinanceFeed(crypto_assets, history;
                    callback=(asset, snap) -> begin
                        update_price!(exchange, asset, snap.price)
                    end)
                t = @async start_feed!(feed)
                push!(feed_tasks, t)
                println("  ✓ Binance WebSocket feed launched for $(join(crypto_assets, ", "))")
            catch e
                @warn "Binance feed failed to start: $(sprint(showerror, e)[1:min(60,end)])"
                println("  ⚠ Binance feed failed — falling back to polling")
            end
        end

        if !isempty(stock_assets) && haskey(ENV, "QE_POLYGON_API_KEY")
            try
                feed = PolygonFeed(stock_assets, history;
                    callback=(asset, snap) -> begin
                        update_price!(exchange, asset, snap.price)
                    end)
                t = @async start_feed!(feed)
                push!(feed_tasks, t)
                println("  ✓ Polygon.io WebSocket feed launched for $(join(stock_assets, ", "))")
            catch e
                @warn "Polygon feed failed to start: $(sprint(showerror, e)[1:min(60,end)])"
                println("  ⚠ Polygon feed failed — falling back to polling")
            end
        end
    end

    # Initialize database (optional — empty db_dir disables persistence)
    trade_db = nothing
    if !isempty(db_dir)
        trade_db = TradeDatabase(db_dir)
        # Resume from last saved state if available
        last_state = db_load_last_state(trade_db)
        if last_state !== nothing
            lock(tracker.lock) do
                tracker.bankroll = last_state.bankroll
                tracker.peak_bankroll = last_state.peak_bankroll
                tracker.total_trades = round(Int, last_state.total_trades)
            end
            exchange = PaperExchange(last_state.bankroll)
            update_bankroll!(adaptive_engine, last_state.bankroll)
            println("  ✓ Resumed from database: \$$(round(last_state.bankroll, digits=2)) " *
                    "($(round(Int, last_state.total_trades)) trades)")
        end
    end

    # Initialize correlation tracker and alert config
    corr_tracker = CorrelationTracker(window=60)
    alert_config = create_alert_config()
    mm_config = MMConfig()
    mm_inventory = Dict{String, Float64}()  # asset → net shares held

    # ── Phase 4: Start Dashboard + Health Server ────────────────
    start_health_server(tracker; port=8080, verbose=true)
    println("  Dashboard: http://localhost:8080/dashboard")

    println()
    println("╔══════════════════════════════════════════════════════════════╗")
    println("║     MONEY PRINTING MACHINE — 24/7 Pipeline Active          ║")
    println("╚══════════════════════════════════════════════════════════════╝")
    println("  Assets:    $(join(assets, ", "))")
    println("  Bankroll:  \$$(config.initial_bankroll)")
    println("  Threads:   $(Threads.nthreads())")
    println("  EV min:    $(config.ev_gap_min * 100)%")
    println("  Kelly:     $(config.kelly_min_fraction*100)%-$(config.kelly_max_fraction*100)%")
    println("  Max pos:   $(config.max_concurrent_positions)")
    println("  Poll:      $(config.poll_interval_ms)ms")
    println("  Audit:     $(audit.filepath)")
    println("  Mode:      $(config.force_conservative ? "CONSERVATIVE ONLY" : "FULL (aggressive + conservative)")")
    println("  Goal:      \$$(round(adaptive_engine.goal_target, digits=0))")
    println()
    println("  Press Ctrl+C to stop")
    println()

    iteration = 0

    while true
        iteration += 1

        # ── Kill Switch: check every iteration ──────────────────
        kill_file = expanduser("~/.quantengine/KILL_SWITCH")
        if isfile(kill_file) || lowercase(get(ENV, "QE_KILL_SWITCH", "false")) == "true"
            println("\n  KILL SWITCH ACTIVATED — forcing PAPER mode and exiting")
            try send_alert(alert_config, "KILL SWITCH activated. Pipeline halted immediately."; level=:critical) catch; end
            # Close all open positions at market
            for (asset, pos) in tracker.positions
                try
                    close_position!(tracker, asset, pos.current_price; reason=:kill_switch)
                catch; end
            end
            rm(kill_file; force=true)
            break
        end

        tick_cooling!(tracker)

        # Check for position exits (stop-loss, take-profit, time)
        exits = check_position_exits!(tracker, asset -> begin
            snap = try fetch_live_snapshot(asset, detect_asset_type(asset)) catch; return NaN end
            update_price!(exchange, asset, snap.price)
            snap.price
        end)

        for exit in exits
            snap = tracker_snapshot(tracker)
            pnl_str = exit.pnl >= 0 ? "+\$$(round(exit.pnl, digits=2))" : "-\$$(round(abs(exit.pnl), digits=2))"
            println("  EXIT [$(exit.reason)] $(exit.asset) → $pnl_str | Bankroll: \$$(round(snap.bankroll, digits=2))")
            audit_log!(audit, exit.asset, :exit, 0,
                       Dict("reason" => string(exit.reason), "pnl" => exit.pnl,
                            "exit_price" => exit.exit_price))
            # Persist trade to database
            if trade_db !== nothing
                try
                    db_record_trade!(trade_db, exit.asset, :long,
                        0.0, exit.exit_price, 0.0, exit.pnl, 0.0;
                        exit_reason=string(exit.reason),
                        execution_mode=string(config.execution_mode))
                catch e
                    @warn "DB write failed: $(sprint(showerror, e)[1:min(60,end)])"
                end
            end
            # Post-trade risk check
            ok, msg = post_trade_risk_check!(tracker, config)
            if !ok
                println("  ⚠ $msg")
            end
            # ── Phase 3: Sync bankroll with goal tracker ────────
            update_bankroll!(adaptive_engine, snap.bankroll)
        end

        # Poll for triggers
        events = try
            poll_for_triggers(assets, config, history, rate_limiters)
        catch e
            @warn "Trigger polling error: $(sprint(showerror, e)[1:min(100,end)])"
            PipelineEvent[]
        end

        # Process triggered events
        for event in events
            ts = Dates.format(now(), "HH:MM:SS")
            println("  [$ts] TRIGGER: $(event.asset) — $(event.trigger_type) at \$$(round(event.price_at_trigger, digits=2))")

            try
                plan = run_full_pipeline(event, config, tracker, exchange, audit; verbose=true)
            catch e
                println("  ✗ Pipeline error: $(sprint(showerror, e)[1:min(100,end)])")
                audit_log!(audit, event.asset, :error, 0,
                           "Pipeline crash: $(sprint(showerror, e)[1:min(200,end)])";
                           event_id=UInt64(hash(event.timestamp)))
            end
        end

        # Periodic status (every 50 iterations)
        if iteration % 50 == 0
            snap = tracker_snapshot(tracker)
            ts = Dates.format(now(), "HH:MM:SS")
            @printf("  [%s] Status: Bankroll \$%.2f | PnL today \$%.2f | Positions %d | Trades %d (%.0f%% win) | DD %.1f%%\n",
                ts, snap.bankroll, snap.daily_pnl, snap.n_positions,
                snap.total_trades, snap.win_rate, snap.drawdown)

            # Correlation risk monitoring
            open_assets = collect(keys(tracker.positions))
            if length(open_assets) >= 2
                corr_risk = portfolio_correlation_risk(corr_tracker, open_assets)
                if corr_risk > 0.7
                    msg = "Correlation risk $(round(corr_risk, digits=2)) > 0.7 across $(join(open_assets, ", "))"
                    println("  ⚠ $msg")
                    send_alert(alert_config, msg; level=:warn)
                end
            end

            # ── Market-making on Polymarket (guarded by QE_ENABLE_MM) ──
            enable_mm = lowercase(get(ENV, "QE_ENABLE_MM", "false")) == "true"
            if enable_mm
                poly_assets = filter(a -> detect_asset_type(a) == :polymarket, assets)
                for pa in poly_assets
                    try
                        slug = replace(pa, "poly:" => "")
                        pdata = fetch_polymarket_data(slug)
                        price = pdata.prices[1]
                        vol = tryparse(Float64, string(pdata.volume))
                        vol = vol !== nothing ? vol : 0.0
                        spread = length(pdata.prices) >= 2 ? abs(pdata.prices[1] - pdata.prices[2]) : 0.05

                        mm_check = should_market_make(vol, spread, price; config=mm_config)
                        if mm_check.make
                            inv = get(mm_inventory, pa, 0.0)
                            fee = 0.02 * 4.0 * price * (1.0 - price)  # Polymarket fee
                            mm_quote = compute_mm_quotes(price, fee, inv; config=mm_config)
                            if mm_quote.edge_per_share > 0.001
                                print_mm_quote(slug, mm_quote)
                            end
                        end
                    catch; end
                end
            end

            # Persist equity snapshot to database
            if trade_db !== nothing
                try
                    db_record_snapshot!(trade_db, tracker)
                catch e
                    @warn "DB snapshot failed: $(sprint(showerror, e)[1:min(60,end)])"
                end
            end
        end

        # ── Phase 3: Goal progress (every 200 iterations ≈ ~17 min) ──
        if iteration % 200 == 0
            print_goal_progress(adaptive_engine)
        end

        # ── Phase 5: Automated Monte Carlo re-validation (every 200 iterations) ──
        if iteration % 200 == 0 && trade_db !== nothing
            try
                recent_trades = db_get_trades(trade_db; limit=500)
                if length(recent_trades) >= 20
                    trade_returns = [t.pnl / max(t.size, 1.0) for t in recent_trades]
                    stress = run_stress_test(trade_returns; n_paths=1000, kelly_fraction=0.15)
                    if stress.passed
                        println("  ✓ Monte Carlo re-run: survival $(round(stress.survival_rate, digits=1))%, PASSED")
                    else
                        println("  ✗ Monte Carlo re-run FAILED — halting pipeline")
                        try send_alert(alert_config, "Monte Carlo re-run FAILED. Survival: $(round(stress.survival_rate, digits=1))%. Pipeline halted."; level=:critical) catch; end
                        break  # Exit the while loop
                    end
                end
            catch e
                @warn "Stress re-run error: $(sprint(showerror, e)[1:min(60,end)])"
            end
        end

        sleep(config.poll_interval_ms / 1000.0)
    end
end
