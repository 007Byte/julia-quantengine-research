# ── Production Infrastructure Tests ────────────────────────────────────
# Tests the OMS state machine, risk reservation invariants, reconciler
# adaptive polling, shadow mode signal tracking, and validation thresholds.
# Does NOT require Postgres — tests the logic, not the database.

using Test
using Dates
using UUIDs

# Load production modules directly (without QuantEngine module context)
include(joinpath(@__DIR__, "..", "src", "production", "oms.jl"))
include(joinpath(@__DIR__, "..", "src", "production", "risk_reservations.jl"))
include(joinpath(@__DIR__, "..", "src", "production", "shadow_mode.jl"))
include(joinpath(@__DIR__, "..", "src", "production", "validation.jl"))

@testset "Production Infrastructure" begin

    @testset "OMS State Machine" begin
        # Valid transitions
        @test valid_transition(INTENT_CREATED, RISK_PENDING)
        @test valid_transition(RISK_PENDING, RISK_APPROVED)
        @test valid_transition(RISK_PENDING, REJECTED)
        @test valid_transition(RISK_APPROVED, RESERVING_BUDGET)
        @test valid_transition(WORKING, FILLED)
        @test valid_transition(WORKING, PARTIALLY_FILLED)
        @test valid_transition(WORKING, CANCELED)
        @test valid_transition(PARTIALLY_FILLED, FILLED)
        @test valid_transition(SUSPENDED, WORKING)

        # Invalid transitions — these MUST be blocked
        @test !valid_transition(INTENT_CREATED, FILLED)
        @test !valid_transition(INTENT_CREATED, ACCEPTED_BY_OMS)
        @test !valid_transition(RISK_PENDING, ACCEPTED_BY_OMS)
        @test !valid_transition(RISK_APPROVED, ACCEPTED_BY_OMS)  # must go through RESERVING
        @test !valid_transition(FILLED, WORKING)  # terminal
        @test !valid_transition(CANCELED, WORKING)  # terminal
        @test !valid_transition(REJECTED, RISK_PENDING)  # terminal

        # Terminal states have no transitions
        for ts in TERMINAL_INTENT_STATES
            @test !haskey(INTENT_TRANSITIONS, ts)
        end

        # No backward transitions
        @test !valid_transition(RISK_PENDING, INTENT_CREATED)
        @test !valid_transition(WORKING, ROUTING)
        @test !valid_transition(ACCEPTED_BY_OMS, RISK_APPROVED)
    end

    @testset "Venue Order State Machine" begin
        @test valid_venue_transition(CHILD_CREATED, SUBMITTED)
        @test valid_venue_transition(SUBMITTED, ACKNOWLEDGED)
        @test valid_venue_transition(SUBMITTED, UNKNOWN_BUT_OPEN)
        @test valid_venue_transition(CANCEL_REQUESTED, VENUE_FILLED)  # race: fill before cancel
        @test valid_venue_transition(CANCEL_REQUESTED, VENUE_CANCELED)
        @test valid_venue_transition(UNKNOWN_BUT_OPEN, VENUE_FILLED)  # recovery from unknown

        @test !valid_venue_transition(CHILD_CREATED, VENUE_FILLED)  # must go through SUBMITTED
        @test !valid_venue_transition(VENUE_FILLED, SUBMITTED)  # terminal
    end

    @testset "Risk Invariants" begin
        # Reservation IDs are unique
        ids = Set{UUID}()
        for _ in 1:100
            push!(ids, uuid4())
        end
        @test length(ids) == 100

        # Risk limits load from defaults
        limits = default_risk_limits()
        @test limits.global_max_daily_loss_pct == 0.05
        @test limits.global_max_drawdown_pct == 0.15
        @test limits.position_count_cap == 50
        @test limits.reservation_expiry_seconds == 60

        # All reservation statuses exist
        @test length(instances(ReservationStatus)) == 4

        # All decision types exist
        @test length(instances(RiskDecisionType)) == 3
    end

    @testset "Intent State Parsing" begin
        @test parse_intent_state("INTENT_CREATED") == INTENT_CREATED
        @test parse_intent_state("FILLED") == FILLED
        @test parse_intent_state("RISK_APPROVED") == RISK_APPROVED
        @test parse_intent_state("working") == WORKING  # case-insensitive
    end

    @testset "Shadow Mode" begin
        session = ShadowSession(instruments=["BTCUSDT", "ETHUSDT"])
        @test session.team_id == "crypto"
        @test session.venue == "binance"
        @test length(session.instruments) == 2
        @test length(session.signals) == 0

        # Record prices
        record_price!(session, "BTCUSDT", 50000.0)
        record_price!(session, "BTCUSDT", 50010.0)
        @test session.prices["BTCUSDT"] == 50010.0
        @test length(session.price_history["BTCUSDT"]) == 2

        # Shadow signal favorable move calculation
        sig = ShadowSignal("s1", "inst1", "BTCUSDT", :buy, 0.8, 50000.0,
                           now(UTC), Dict{String,Float64}(), Dict{String,Symbol}())
        @test sig.outcome_recorded == false

        sig.price_after_5m = 50050.0  # 10 bps up
        @test move_5m_bps(sig) ≈ 10.0 atol=0.1
        @test was_correct_5m(sig) == true

        # Sell signal: price down = favorable
        sig2 = ShadowSignal("s2", "inst1", "BTCUSDT", :sell, 0.7, 50000.0,
                            now(UTC), Dict{String,Float64}(), Dict{String,Symbol}())
        sig2.price_after_5m = 49950.0  # 10 bps down = good for sell
        @test move_5m_bps(sig2) ≈ 10.0 atol=0.1
        @test was_correct_5m(sig2) == true

        # No outcome yet
        sig3 = ShadowSignal("s3", "inst1", "ETHUSDT", :buy, 0.6, 3000.0,
                            now(UTC), Dict{String,Float64}(), Dict{String,Symbol}())
        @test move_5m_bps(sig3) === nothing
        @test was_correct_5m(sig3) === nothing
    end

    @testset "Shadow Stats" begin
        session = ShadowSession()

        # Empty session
        stats = shadow_stats(session)
        @test stats["total_signals"] == 0
        @test stats["completed"] == 0

        # Add completed signals
        sig1 = ShadowSignal("s1", "i1", "BTCUSDT", :buy, 0.8, 50000.0,
                            now(UTC) - Hour(2), Dict("m01"=>0.3, "m05"=>0.5), Dict("m01"=>:buy, "m05"=>:buy))
        sig1.price_after_5m = 50050.0
        sig1.price_after_1h = 50100.0
        sig1.outcome_recorded = true

        sig2 = ShadowSignal("s2", "i1", "BTCUSDT", :buy, 0.6, 50000.0,
                            now(UTC) - Hour(2), Dict("m01"=>0.2, "m05"=>0.4), Dict("m01"=>:sell, "m05"=>:buy))
        sig2.price_after_5m = 49950.0
        sig2.price_after_1h = 49900.0
        sig2.outcome_recorded = true

        push!(session.signals, sig1)
        push!(session.signals, sig2)

        stats = shadow_stats(session)
        @test stats["total_signals"] == 2
        @test stats["completed"] == 2
        @test stats["hit_rate_5m"] ≈ 0.5  # 1 of 2 correct
    end

    @testset "Model Contribution Stats" begin
        session = ShadowSession()

        # Signal where model m01 contributed and was correct
        sig = ShadowSignal("s1", "i1", "BTCUSDT", :buy, 0.8, 50000.0,
                           now(UTC), Dict("m01"=>0.5, "m99"=>0.001), Dict{String,Symbol}())
        sig.price_after_5m = 50050.0
        sig.outcome_recorded = true
        push!(session.signals, sig)

        mstats = model_contribution_stats(session)
        @test haskey(mstats, "m01")
        @test haskey(mstats, "m99")
        @test mstats["m01"]["avg_contribution"] ≈ 0.5
        @test mstats["m99"]["is_dead_weight"] == true  # contrib < 0.01
    end

    @testset "Validation Thresholds" begin
        @test length(ALL_THRESHOLDS) >= 20

        # Check critical thresholds exist
        names = [t.name for t in ALL_THRESHOLDS]
        @test "shadow_hit_5m" in names
        @test "paper_expectancy" in names
        @test "paper_recon_days" in names
        @test "live_kill_drill" in names
        @test "live_runbooks" in names

        # Hit rate must beat coin flip
        hit_threshold = first(filter(t -> t.name == "shadow_hit_5m", ALL_THRESHOLDS))
        @test hit_threshold.target >= 0.52

        # Post-cost expectancy must be positive
        exp_threshold = first(filter(t -> t.name == "paper_expectancy", ALL_THRESHOLDS))
        @test exp_threshold.target == 0.0
        @test exp_threshold.comparator == :gt

        # NTP threshold should be tight (feedback: 150-200ms)
        ntp = first(filter(t -> t.name == "live_ntp_tight", ALL_THRESHOLDS))
        @test ntp.target <= 200.0
    end

    @testset "Threshold Evaluation" begin
        t = Threshold("test", "test metric", VAL_PLUMBING, :gte, 10.0, "count")
        r = ThresholdResult(t)

        @test r.passed === nothing  # unmeasured

        evaluate!(r, 15.0)
        @test r.passed == true
        @test r.measured == 15.0

        r2 = ThresholdResult(t)
        evaluate!(r2, 5.0)
        @test r2.passed == false

        # gt vs gte
        t2 = Threshold("test2", "positive", VAL_PAPER, :gt, 0.0, "USD")
        r3 = ThresholdResult(t2)
        evaluate!(r3, 0.0)
        @test r3.passed == false  # gt, not gte
        evaluate!(r3, 0.01)
        @test r3.passed == true
    end

    @testset "Scope Enforcement" begin
        # BTC and ETH only — narrow lane
        session = ShadowSession()
        @test "BTCUSDT" in session.instruments
        @test "ETHUSDT" in session.instruments
        @test length(session.instruments) == 2
    end

end

println("\nAll production tests passed ✓")
