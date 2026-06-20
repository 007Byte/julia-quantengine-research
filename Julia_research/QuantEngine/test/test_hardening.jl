# ── Hardening Tests ───────────────────────────────────────────

using QuantEngine: check_inventory_limits, auto_unwind_size, MMConfig,
                   dynamic_throttle

# ── Adaptive Selector Hardening ──────────────────────────────

@testset "adaptive selector protects core models" begin
    engine = AdaptiveEngine()

    # Record terrible performance for core model 14 (GARCH) in bull regime
    for _ in 1:35
        record_model_outcome!(engine, 14, :bull, false, -50.0)
    end

    # Profile as bullish stock
    profile = DataProfile("AAPL", :stock, 0.6, :normal, :normal,
                          :bullish, :normal, :neutral, Inf, 0.0)

    strategy = select_models(profile, engine)

    # Core model 14 should NOT be demoted (it's protected)
    @test 14 in strategy.model_ids
end

@testset "adaptive selector requires 500+ trades to demote" begin
    engine = AdaptiveEngine()

    # Only 200 bad predictions — not enough to demote (need 500)
    for _ in 1:200
        record_model_outcome!(engine, 5, :bull, false, -10.0)
    end

    profile = DataProfile("AAPL", :stock, 0.6, :normal, :normal,
                          :bullish, :normal, :neutral, Inf, 0.0)
    strategy = select_models(profile, engine)

    # Model 5 should still be included (< 30 trade threshold)
    @test 5 in strategy.model_ids
end

# ── Goal Tracker Scenarios ───────────────────────────────────

@testset "goal_progress scenarios" begin
    engine = AdaptiveEngine(goal_target=10_000_000.0, initial_bankroll=10_000.0)

    progress = goal_progress(engine)

    @test haskey(pairs(progress) |> Dict, :conservative_years)
    @test haskey(pairs(progress) |> Dict, :base_years)
    @test haskey(pairs(progress) |> Dict, :optimistic_years)

    # Conservative (0.15%/day) should take longer than optimistic (0.5%/day)
    @test progress.conservative_years > progress.optimistic_years
    @test progress.base_years > progress.optimistic_years
    @test progress.conservative_years > progress.base_years
end

# ── MM Inventory Limits ──────────────────────────────────────

@testset "check_inventory_limits safe" begin
    config = MMConfig(max_position_shares=500.0)
    result = check_inventory_limits(100.0; config=config)
    @test result.safe == true
    @test result.action == :none
end

@testset "check_inventory_limits warning" begin
    config = MMConfig(max_position_shares=500.0)
    result = check_inventory_limits(420.0; config=config)  # 84% of max
    @test result.safe == true
    @test result.action == :reduce_quotes
end

@testset "check_inventory_limits exceeded" begin
    config = MMConfig(max_position_shares=500.0)
    result = check_inventory_limits(600.0; config=config)
    @test result.safe == false
    @test result.action == :unwind
    @test result.direction == :sell
    @test result.excess_shares == 100.0
end

@testset "check_inventory_limits negative (short)" begin
    config = MMConfig(max_position_shares=500.0)
    result = check_inventory_limits(-700.0; config=config)
    @test result.safe == false
    @test result.action == :unwind
    @test result.direction == :buy
end

@testset "auto_unwind_size" begin
    config = MMConfig(max_position_shares=500.0)

    # Within limits → 0 unwind
    @test auto_unwind_size(200.0; config=config) == 0.0

    # Over limits → unwind to 50% of max
    unwind = auto_unwind_size(600.0; config=config, target_pct=0.5)
    @test unwind ≈ 350.0  # 600 - 250 (50% of 500)
end

# ── Dynamic Throttle ─────────────────────────────────────────

@testset "dynamic_throttle NEVER exceeds 1.0" begin
    engine = AdaptiveEngine(goal_target=10_000_000.0, initial_bankroll=10_000.0)

    throttle = dynamic_throttle(engine)
    @test 0.1 <= throttle.kelly_scale <= 1.0  # HARD CAP at 1.0
    @test throttle.urgency in [:normal, :patient]  # never :immediate
    @test throttle.max_daily_risk_pct == 2.0  # hard daily cap
end

@testset "dynamic_throttle losing money → emergency" begin
    engine = AdaptiveEngine(goal_target=10_000_000.0, initial_bankroll=10_000.0)
    update_bankroll!(engine, 8_000.0)  # -20% loss

    throttle = dynamic_throttle(engine)
    @test throttle.kelly_scale <= 0.25  # heavily reduced
    @test throttle.urgency == :patient  # slow down
end

@testset "dynamic_throttle behind schedule → does NOT increase risk" begin
    engine = AdaptiveEngine(goal_target=10_000_000.0, initial_bankroll=10_000.0)
    # Simulate being behind schedule (small growth after many days)
    update_bankroll!(engine, 10_050.0)

    throttle = dynamic_throttle(engine)
    @test throttle.kelly_scale <= 1.0  # NEVER exceeds 1.0
    # Must NOT be :immediate (no chasing losses)
    @test throttle.urgency != :immediate
end

@testset "dynamic_throttle large gains → strong protection" begin
    engine = AdaptiveEngine(goal_target=10_000_000.0, initial_bankroll=10_000.0)
    update_bankroll!(engine, 120_000.0)  # 12x initial

    throttle = dynamic_throttle(engine)
    @test throttle.kelly_scale < 0.7  # strong protection at 10x+
end

# ── Realistic Slippage ───────────────────────────────────────

@testset "realistic_costs" begin
    using QuantEngine: realistic_costs, round_trip_cost_bps, minimum_edge_required,
                       adjust_returns_for_costs, TransactionCosts

    crypto_costs = realistic_costs(:crypto)
    @test crypto_costs.fee_bps == 10.0
    @test crypto_costs.slippage_bps == 15.0
    @test round_trip_cost_bps(crypto_costs) > 50  # substantial round-trip cost

    poly_costs = realistic_costs(:polymarket)
    @test round_trip_cost_bps(poly_costs) > 200  # very expensive

    stock_costs = realistic_costs(:stock)
    @test round_trip_cost_bps(stock_costs) < 30  # cheapest
end

@testset "minimum_edge_required" begin
    using QuantEngine: minimum_edge_required

    # Polymarket needs the most edge
    @test minimum_edge_required(:polymarket) > minimum_edge_required(:crypto)
    @test minimum_edge_required(:crypto) > minimum_edge_required(:stock)
    @test minimum_edge_required(:polymarket) > 0.02  # > 2% minimum
end

@testset "adjust_returns_for_costs" begin
    using QuantEngine: adjust_returns_for_costs

    returns = [0.01, -0.005, 0.02, -0.01, 0.015]
    adjusted = adjust_returns_for_costs(returns, :crypto)

    # Adjusted returns should all be lower than raw returns
    @test all(adjusted .< returns)
    # Cost deduction should be consistent
    diff_amounts = returns .- adjusted
    @test all(d -> d ≈ diff_amounts[1], diff_amounts)  # same cost each bar
end

# ── Adverse Selection ────────────────────────────────────────

@testset "adverse selection guard" begin
    using QuantEngine: check_adverse_selection

    # Long + bearish flow → unsafe
    result = check_adverse_selection(:distribution, -0.5, 100.0)
    @test result.safe == false

    # Short + bullish flow → unsafe
    result = check_adverse_selection(:accumulation, 0.5, -100.0)
    @test result.safe == false

    # Strong directional flow → unsafe regardless
    result = check_adverse_selection(:neutral, 0.8, 0.0)
    @test result.safe == false

    # Neutral flow + any inventory → safe
    result = check_adverse_selection(:neutral, 0.1, 50.0)
    @test result.safe == true
end
