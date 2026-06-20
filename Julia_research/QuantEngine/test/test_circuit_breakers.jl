# ── Circuit Breaker Tests ─────────────────────────────────────

@testset "preflight_risk_check fresh tracker" begin
    config = load_pipeline_config()
    tracker = PositionTracker(2000.0)

    ok, reason = preflight_risk_check(tracker, config, "AAPL")
    @test ok == true
    @test reason == "OK"
end

@testset "preflight_risk_check max positions" begin
    config = load_pipeline_config()  # max_concurrent = 5
    tracker = PositionTracker(10000.0)

    # Fill up to max positions
    for i in 1:config.max_concurrent_positions
        pos = PositionState("ASSET$i", :long, :spot_buy, 100.0, 100.0,
                           100.0, 0.05, now(), 24.0, 5.0, 3.0, 0.0, 0.0)
        open_position!(tracker, pos)
    end

    ok, reason = preflight_risk_check(tracker, config, "NEW_ASSET")
    @test ok == false
    @test occursin("Max concurrent", reason)
end

@testset "preflight_risk_check already in asset" begin
    config = load_pipeline_config()
    tracker = PositionTracker(2000.0)

    pos = PositionState("AAPL", :long, :spot_buy, 100.0, 100.0,
                       200.0, 0.1, now(), 24.0, 5.0, 3.0, 0.0, 0.0)
    open_position!(tracker, pos)

    ok, reason = preflight_risk_check(tracker, config, "AAPL")
    @test ok == false
    @test occursin("Already in position", reason)
end

@testset "preflight_risk_check cooling period" begin
    config = load_pipeline_config()
    tracker = PositionTracker(2000.0)

    # Manually set cooling
    lock(tracker.lock) do
        tracker.cooling_countdown = 5
    end

    ok, reason = preflight_risk_check(tracker, config, "AAPL")
    @test ok == false
    @test occursin("Cooling", reason)
end

@testset "post_trade_risk_check! cooling after 3 losses" begin
    config = load_pipeline_config()
    tracker = PositionTracker(10000.0)

    # Simulate 3 consecutive losses
    for i in 1:3
        pos = PositionState("LOSS$i", :long, :spot_buy, 100.0, 100.0,
                           100.0, 0.01, now(), 24.0, 5.0, 3.0, 0.0, 0.0)
        open_position!(tracker, pos)
        close_position!(tracker, "LOSS$i", 95.0)
    end

    @test tracker.consecutive_losses == 3

    ok, reason = post_trade_risk_check!(tracker, config)
    @test ok == true  # returns true but with cooling message
    @test occursin("COOLING", reason)
    @test tracker.cooling_countdown == config.cooling_period_after_loss
end

@testset "tick_cooling!" begin
    tracker = PositionTracker(2000.0)
    lock(tracker.lock) do
        tracker.cooling_countdown = 3
    end

    tick_cooling!(tracker)
    @test tracker.cooling_countdown == 2

    tick_cooling!(tracker)
    @test tracker.cooling_countdown == 1

    tick_cooling!(tracker)
    @test tracker.cooling_countdown == 0

    # Should not go below 0
    tick_cooling!(tracker)
    @test tracker.cooling_countdown == 0
end

@testset "check_position_exits! stop-loss" begin
    tracker = PositionTracker(2000.0)
    pos = PositionState("AAPL", :long, :spot_buy, 100.0, 100.0,
                       500.0, 0.25, now(), 24.0, 5.0, 3.0, 0.0, 0.0)
    open_position!(tracker, pos)

    # Mock price function: price dropped enough to trigger 3% stop-loss
    get_price = asset -> 96.0  # -4% → triggers 3% SL

    exits = check_position_exits!(tracker, get_price)
    @test length(exits) == 1
    @test exits[1].reason == :stop_loss
    @test isempty(tracker.positions)
end

@testset "check_position_exits! take-profit" begin
    tracker = PositionTracker(2000.0)
    pos = PositionState("AAPL", :long, :spot_buy, 100.0, 100.0,
                       500.0, 0.25, now(), 24.0, 5.0, 3.0, 0.0, 0.0)
    open_position!(tracker, pos)

    # Price rose enough to trigger 5% TP
    get_price = asset -> 106.0  # +6% → triggers 5% TP

    exits = check_position_exits!(tracker, get_price)
    @test length(exits) == 1
    @test exits[1].reason == :take_profit
end

@testset "can_open_position bankroll check" begin
    config = load_pipeline_config()
    tracker = PositionTracker(5.0)  # Very low bankroll

    @test can_open_position(tracker, config, "AAPL") == false
end
