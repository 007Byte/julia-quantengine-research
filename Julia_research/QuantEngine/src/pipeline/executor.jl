# ── Step 12: Execute Trade + Audit Log ────────────────────────

"""Execute a trade plan via the exchange interface and log everything."""
function execute_trade!(exchange::AbstractExchange, plan::TradePlan,
                        tracker::PositionTracker, audit::AuditLogger;
                        config::Union{PipelineConfig, Nothing}=nothing)
    # Execution mode guard: prevent LIVE mode with PaperExchange
    if config !== nothing && config.execution_mode == LIVE && exchange isa PaperExchange
        error("SAFETY: execution_mode=LIVE but exchange is PaperExchange. " *
              "Use a real exchange implementation for live trading.")
    end

    if !plan.execution_ready || plan.strategy.direction == :hold
        audit_log!(audit, plan.asset, :skip, 12, plan.strategy.rationale;
                   event_id=UInt64(hash(plan.timestamp)))
        return nothing
    end

    # Place the order
    order = place_order(exchange, plan.asset, plan.strategy.direction,
                        plan.strategy.instrument_name, plan.strategy.size_dollars;
                        order_type=plan.strategy.buy_type,
                        limit_price=plan.strategy.limit_price)

    if order.status != :filled
        audit_log!(audit, plan.asset, :order_rejected, 12,
                   "Order rejected: $(order.status)";
                   event_id=UInt64(hash(plan.timestamp)))
        return nothing
    end

    # Open position in tracker
    pos = PositionState(
        plan.asset, plan.strategy.direction, plan.strategy.instrument_name,
        order.fill_price, order.fill_price,
        plan.strategy.size_dollars, plan.strategy.size_fraction,
        now(), plan.strategy.hold_time_hours,
        plan.strategy.take_profit_pct, plan.strategy.stop_loss_pct,
        0.0, 0.0
    )
    open_position!(tracker, pos)

    # Full audit
    audit_trade!(audit, plan)

    return order
end

"""
    run_full_pipeline(event, config, tracker, exchange, audit) → TradePlan or nothing

The complete pipeline: Steps 1(done) → 2-9 → Decision → Orchestrator → Execute.
"""
function run_full_pipeline(event::PipelineEvent, config::PipelineConfig,
                           tracker::PositionTracker, exchange::AbstractExchange,
                           audit::AuditLogger; verbose::Bool=true)::Union{TradePlan, Nothing}
    # Log the trigger
    audit_log!(audit, event.asset, :trigger, 1, event.trigger_data;
               event_id=UInt64(hash(event.timestamp)))

    # Preflight risk check
    ok, reason = preflight_risk_check(tracker, config, event.asset)
    if !ok
        verbose && println("  ✗ Preflight FAILED: $reason")
        audit_log!(audit, event.asset, :skip, 0, reason;
                   event_id=UInt64(hash(event.timestamp)))
        return nothing
    end

    # Prepare analysis context
    ctx = try
        prepare_context(event.asset)
    catch e
        verbose && println("  ✗ Data preparation failed: $(sprint(showerror, e)[1:min(80,end)])")
        audit_log!(audit, event.asset, :error, 0,
                   "prepare_context failed: $(sprint(showerror, e)[1:min(80,end)])";
                   event_id=UInt64(hash(event.timestamp)))
        return nothing
    end

    state = PipelineState(event, ctx)

    # Run Steps 2-9
    verbose && println("  Running pipeline Steps 2-9...")
    steps_ok = run_pipeline_steps!(state, config; verbose)

    if !steps_ok
        verbose && println("  ✗ Pipeline aborted: $(state.abort_reason)")
        audit_log!(audit, event.asset, :abort, 0, state.abort_reason;
                   event_id=UInt64(hash(event.timestamp)))
        return nothing
    end

    # Steps 10-11: Decision + Orchestrator
    verbose && println("  Running Decision Layer + Orchestrator...")
    plan = try
        orchestrate(state, config, tracker)
    catch e
        verbose && println("  ✗ Orchestrator failed: $(sprint(showerror, e)[1:min(80,end)])")
        audit_log!(audit, event.asset, :error, 11,
                   "Orchestrator failed: $(sprint(showerror, e)[1:min(80,end)])";
                   event_id=UInt64(hash(event.timestamp)))
        return nothing
    end

    # Step 12: Execute
    if plan.execution_ready
        verbose && _print_trade_plan(plan)
        execute_trade!(exchange, plan, tracker, audit; config=config)
    else
        verbose && println("  → SKIP: $(plan.strategy.rationale)")
        audit_log!(audit, event.asset, :skip, 12, plan.strategy.rationale;
                   event_id=UInt64(hash(event.timestamp)))
    end

    return plan
end

"""Print a trade plan to console."""
function _print_trade_plan(plan::TradePlan)
    s = plan.strategy
    c = plan.comparison
    println()
    println("  ╔══════════════════════════════════════════════════╗")
    println("  ║  TRADE PLAN — $(rpad(plan.asset, 38))║")
    println("  ╠══════════════════════════════════════════════════╣")
    @printf("  ║  Strategy:   %-38s║\n", s.model_name)
    @printf("  ║  Instrument: %-38s║\n", s.instrument_name)
    @printf("  ║  Direction:  %-38s║\n", uppercase(string(s.direction)))
    @printf("  ║  Order:      %-38s║\n", "$(s.buy_type) @ \$$(round(s.limit_price, digits=2))")
    @printf("  ║  Size:       \$%-37s║\n", "$(round(s.size_dollars, digits=2)) ($(round(s.size_fraction*100, digits=1))%)")
    @printf("  ║  Hold:       %-38s║\n", "$(round(s.hold_time_hours, digits=0)) hours")
    @printf("  ║  TP/SL:      +%.1f%% / -%.1f%%%-24s║\n", s.take_profit_pct, s.stop_loss_pct, "")
    @printf("  ║  R:R:        1:%-36s║\n", "$(round(s.risk_reward_ratio, digits=2))")
    @printf("  ║  Confidence: %-38s║\n", "$(round(s.confidence, digits=0))%")
    println("  ╠══════════════════════════════════════════════════╣")
    @printf("  ║  Aggressive:   %-34s║\n", "$(c.aggressive.direction) \$$(round(c.aggressive.size_dollars, digits=0))")
    @printf("  ║  Conservative: %-34s║\n", "$(c.conservative.direction) \$$(round(c.conservative.size_dollars, digits=0))")
    @printf("  ║  Orchestrator: %-34s║\n", "$(c.recommended) (blend=$(round(c.blend_weight, digits=1)))")
    println("  ╚══════════════════════════════════════════════════╝")
    println()
end
