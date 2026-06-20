# ── Position Tracker Tests ────────────────────────────────────

function _make_config()
    load_pipeline_config()
end

function _make_position(; asset="AAPL", direction=:long, price=100.0, size=200.0)
    PositionState(asset, direction, :spot_buy, price, price,
                  size, size/2000.0, now(), 24.0, 5.0, 3.0, 0.0, 0.0)
end

@testset "PositionTracker creation" begin
    tracker = PositionTracker(2000.0)
    @test tracker.bankroll == 2000.0
    @test tracker.total_trades == 0
    @test tracker.winning_trades == 0
    @test tracker.losing_trades == 0
    @test tracker.consecutive_losses == 0
    @test isempty(tracker.positions)
    @test tracker.peak_bankroll == 2000.0
end

@testset "open_position! reduces bankroll" begin
    tracker = PositionTracker(2000.0)
    pos = _make_position(size=500.0)
    open_position!(tracker, pos)

    @test tracker.bankroll == 1500.0
    @test length(tracker.positions) == 1
    @test haskey(tracker.positions, "AAPL")
end

@testset "close_position! winning long" begin
    tracker = PositionTracker(2000.0)
    pos = _make_position(price=100.0, size=500.0)
    open_position!(tracker, pos)

    # Price went up 10%
    result = close_position!(tracker, "AAPL", 110.0)

    @test result !== nothing
    @test result.pnl ≈ 50.0  # 500 * (110/100 - 1) = 50
    @test tracker.bankroll ≈ 2050.0  # 1500 + 500 + 50
    @test tracker.winning_trades == 1
    @test tracker.losing_trades == 0
    @test tracker.consecutive_losses == 0
    @test isempty(tracker.positions)
end

@testset "close_position! losing long" begin
    tracker = PositionTracker(2000.0)
    pos = _make_position(price=100.0, size=500.0)
    open_position!(tracker, pos)

    # Price went down 5%
    result = close_position!(tracker, "AAPL", 95.0)

    @test result !== nothing
    @test result.pnl ≈ -25.0  # 500 * (95/100 - 1) = -25
    @test tracker.bankroll ≈ 1975.0
    @test tracker.winning_trades == 0
    @test tracker.losing_trades == 1
    @test tracker.consecutive_losses == 1
end

@testset "close_position! short trade" begin
    tracker = PositionTracker(2000.0)
    pos = _make_position(direction=:short, price=100.0, size=500.0)
    open_position!(tracker, pos)

    # Price went down 5% → profit for short
    result = close_position!(tracker, "AAPL", 95.0)

    @test result.pnl ≈ 25.0  # 500 * (1 - 95/100) = 25
    @test tracker.winning_trades == 1
end

@testset "close_position! nonexistent asset" begin
    tracker = PositionTracker(2000.0)
    result = close_position!(tracker, "FAKE", 100.0)
    @test result === nothing
end

@testset "consecutive losses tracking" begin
    tracker = PositionTracker(10000.0)

    for i in 1:3
        pos = _make_position(asset="LOSS$i", price=100.0, size=100.0)
        open_position!(tracker, pos)
        close_position!(tracker, "LOSS$i", 95.0)  # losing trade
    end

    @test tracker.consecutive_losses == 3

    # One win resets consecutive losses
    pos = _make_position(asset="WIN", price=100.0, size=100.0)
    open_position!(tracker, pos)
    close_position!(tracker, "WIN", 110.0)

    @test tracker.consecutive_losses == 0
end

@testset "peak_bankroll updates" begin
    tracker = PositionTracker(2000.0)
    pos = _make_position(price=100.0, size=500.0)
    open_position!(tracker, pos)
    close_position!(tracker, "AAPL", 120.0)  # big win

    @test tracker.peak_bankroll > 2000.0
    @test tracker.peak_bankroll == tracker.bankroll
end

@testset "portfolio_heat" begin
    tracker = PositionTracker(2000.0)
    @test portfolio_heat(tracker) == 0.0

    pos = _make_position(size=500.0)
    open_position!(tracker, pos)

    heat = portfolio_heat(tracker)
    @test heat > 0.0
    @test heat < 100.0
end

@testset "tracker_snapshot" begin
    tracker = PositionTracker(2000.0)
    snap = tracker_snapshot(tracker)

    @test snap.bankroll == 2000.0
    @test snap.daily_pnl == 0.0
    @test snap.n_positions == 0
    @test snap.total_trades == 0
    @test snap.win_rate == 0.0
    @test snap.consecutive_losses == 0
    @test snap.cooling == false
end
