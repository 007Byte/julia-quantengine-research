# ── Monitoring & Health Check Tests ───────────────────────────

using QuantEngine: _handle_health, _handle_metrics

@testset "health endpoint" begin
    tracker = PositionTracker(5000.0)
    response = _handle_health(tracker)

    @test response.status == 200
    body = JSON.parse(String(response.body))
    @test body["status"] == "ok"
    @test body["bankroll"] == 5000.0
    @test body["positions"] == 0
    @test body["trades"] == 0
    @test body["cooling"] == false
    @test haskey(body, "timestamp")
end

@testset "health endpoint with positions" begin
    tracker = PositionTracker(5000.0)
    pos = PositionState("AAPL", :long, :spot_buy, 150.0, 150.0,
                       500.0, 0.1, now(), 24.0, 5.0, 3.0, 0.0, 0.0)
    open_position!(tracker, pos)

    response = _handle_health(tracker)
    body = JSON.parse(String(response.body))
    @test body["positions"] == 1
    @test body["bankroll"] == 4500.0
end

@testset "metrics endpoint Prometheus format" begin
    tracker = PositionTracker(5000.0)
    response = _handle_metrics(tracker)

    @test response.status == 200
    body = String(response.body)

    # Should contain Prometheus-format metrics
    @test occursin("quantengine_bankroll 5000.0", body)
    @test occursin("quantengine_positions_open 0", body)
    @test occursin("quantengine_trades_total 0", body)
    @test occursin("quantengine_win_rate 0.0", body)
    @test occursin("quantengine_cooling 0", body)

    # Should have TYPE and HELP annotations
    @test occursin("# TYPE quantengine_bankroll gauge", body)
    @test occursin("# HELP quantengine_bankroll", body)
end

@testset "metrics after trading" begin
    tracker = PositionTracker(10000.0)

    # Simulate 2 winning trades and 1 losing trade
    for (asset, exit_p) in [("AAPL", 110.0), ("MSFT", 105.0), ("GOOGL", 95.0)]
        pos = PositionState(asset, :long, :spot_buy, 100.0, 100.0,
                           500.0, 0.05, now(), 24.0, 5.0, 3.0, 0.0, 0.0)
        open_position!(tracker, pos)
        close_position!(tracker, asset, exit_p)
    end

    response = _handle_metrics(tracker)
    body = String(response.body)

    @test occursin("quantengine_trades_total 3", body)
    # Win rate should be ~66.7%
    @test occursin("quantengine_win_rate 66.7", body)
end
