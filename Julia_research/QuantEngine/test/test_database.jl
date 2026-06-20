# ── Database Tests ────────────────────────────────────────────

@testset "TradeDatabase creation" begin
    dir = mktempdir()
    tdb = TradeDatabase(dir)

    @test isfile(tdb.filepath)
    @test occursin("quantengine.db", tdb.filepath)

    db_close!(tdb)
end

@testset "db_record_trade! and db_get_trades" begin
    dir = mktempdir()
    tdb = TradeDatabase(dir)

    db_record_trade!(tdb, "AAPL", :long, 150.0, 155.0, 1000.0, 33.33, 3.33;
                     exit_reason="take_profit", strategy="Aggressive",
                     confidence=72.0, execution_mode="PAPER")

    db_record_trade!(tdb, "BTC-USD", :short, 45000.0, 44000.0, 500.0, 11.11, 2.22;
                     exit_reason="time_expired", strategy="Conservative")

    trades = db_get_trades(tdb)
    @test length(trades) == 2

    # Filter by asset
    aapl_trades = db_get_trades(tdb; asset="AAPL")
    @test length(aapl_trades) == 1
    @test aapl_trades[1].asset == "AAPL"
    @test aapl_trades[1].pnl ≈ 33.33

    db_close!(tdb)
end

@testset "db_record_snapshot! and db_get_equity_curve" begin
    dir = mktempdir()
    tdb = TradeDatabase(dir)
    tracker = PositionTracker(5000.0)

    # Record multiple snapshots
    db_record_snapshot!(tdb, tracker)

    # Simulate some trading
    pos = PositionState("AAPL", :long, :spot_buy, 100.0, 100.0,
                       500.0, 0.1, now(), 24.0, 5.0, 3.0, 0.0, 0.0)
    open_position!(tracker, pos)
    close_position!(tracker, "AAPL", 110.0)

    db_record_snapshot!(tdb, tracker)

    curve = db_get_equity_curve(tdb)
    @test length(curve) == 2
    @test curve[1].bankroll == 5000.0
    @test curve[2].bankroll > 5000.0  # won the trade

    db_close!(tdb)
end

@testset "db_record_model_perf! and db_get_model_leaderboard" begin
    dir = mktempdir()
    tdb = TradeDatabase(dir)

    log1 = RalphLog("LSTM", true, 1500.0, "OK")
    log2 = RalphLog("XGBoost", true, 200.0, "OK")
    log3 = RalphLog("XGBoost", true, 180.0, "OK")

    db_record_model_perf!(tdb, "AAPL", log1; accuracy=0.62, probability=0.68)
    db_record_model_perf!(tdb, "AAPL", log2; accuracy=0.71, probability=0.73)
    db_record_model_perf!(tdb, "BTC-USD", log3; accuracy=0.69, probability=0.65)

    board = db_get_model_leaderboard(tdb)
    @test length(board) == 2  # LSTM and XGBoost

    # XGBoost should have 2 runs
    xgb = filter(r -> r.model_name == "XGBoost", board)
    @test length(xgb) == 1
    @test xgb[1].n_runs == 2

    db_close!(tdb)
end

@testset "db_load_last_state" begin
    dir = mktempdir()
    tdb = TradeDatabase(dir)

    # No data yet
    @test db_load_last_state(tdb) === nothing

    # Record a snapshot
    tracker = PositionTracker(7500.0)
    db_record_snapshot!(tdb, tracker)

    state = db_load_last_state(tdb)
    @test state !== nothing
    @test state.bankroll == 7500.0

    db_close!(tdb)
end

@testset "db_get_lifetime_stats" begin
    dir = mktempdir()
    tdb = TradeDatabase(dir)

    # No trades
    stats = db_get_lifetime_stats(tdb)
    @test stats.total_trades == 0

    # Add trades
    db_record_trade!(tdb, "AAPL", :long, 100.0, 110.0, 1000.0, 100.0, 10.0)
    db_record_trade!(tdb, "AAPL", :long, 105.0, 100.0, 1000.0, -47.6, -4.76)
    db_record_trade!(tdb, "MSFT", :long, 300.0, 315.0, 1000.0, 50.0, 5.0)

    stats = db_get_lifetime_stats(tdb)
    @test stats.total_trades == 3
    @test stats.wins == 2
    @test stats.losses == 1
    @test stats.win_rate ≈ 200.0/3
    @test stats.total_pnl ≈ 100.0 + (-47.6) + 50.0
    @test stats.best_trade ≈ 100.0
    @test stats.worst_trade ≈ -47.6

    db_close!(tdb)
end

@testset "db_get_daily_pnl" begin
    dir = mktempdir()
    tdb = TradeDatabase(dir)

    db_record_trade!(tdb, "AAPL", :long, 100.0, 110.0, 1000.0, 100.0, 10.0)
    db_record_trade!(tdb, "AAPL", :long, 105.0, 100.0, 1000.0, -50.0, -4.76)

    daily = db_get_daily_pnl(tdb)
    @test length(daily) >= 1
    @test daily[1].n_trades == 2

    db_close!(tdb)
end

@testset "Database thread safety" begin
    dir = mktempdir()
    tdb = TradeDatabase(dir)

    # Write from multiple tasks concurrently
    tasks = Task[]
    for i in 1:10
        t = @async begin
            db_record_trade!(tdb, "ASSET$i", :long, 100.0, 105.0,
                            100.0, 5.0, 5.0; exit_reason="test")
        end
        push!(tasks, t)
    end
    for t in tasks
        wait(t)
    end

    trades = db_get_trades(tdb; limit=100)
    @test length(trades) == 10

    db_close!(tdb)
end
