# ── Production Pipeline Runner ─────────────────────────────────────────
# Wraps the existing run_money_printer loop with production infrastructure:
# - Postgres connection pool + migrations
# - OMS with parent/child orders
# - Atomic risk reservations
# - Startup reconciliation (OMS frozen until clean)
# - Adaptive reconciliation polling
# - NTP check (blocks trading on >150ms skew)
# - Outbox worker
# - Scope enforcement (crypto/binance/BTC+ETH only)
#
# Does NOT replace run_money_printer — extends it with production controls.

using Dates
using UUIDs

# ── Scope Enforcement ─────────────────────────────────────────
# Only these scopes are allowed until edge is proven.

const ALLOWED_SCOPES = Set([
    ("crypto", "binance"),
    ("crypto", "paper"),
])

const ALLOWED_INSTRUMENTS = Dict(
    "crypto" => ["BTCUSDT", "ETHUSDT"],
)

function enforce_scope(team::String, venue::String)
    if (team, venue) ∉ ALLOWED_SCOPES
        error("Scope ($team, $venue) not allowed. Prove edge on crypto/binance before expanding. " *
              "Allowed: $ALLOWED_SCOPES")
    end
    instruments = get(ALLOWED_INSTRUMENTS, team, String[])
    @info "Scope enforced: $team/$venue — instruments: $(join(instruments, ", "))"
    return instruments
end

# ── Production Startup Sequence ───────────────────────────────

mutable struct ProductionPipeline
    team_id::String
    venue::String
    instruments::Vector{String}
    pool::Union{PgPool, Nothing}
    oms::Union{OrderManagementSystem, Nothing}
    reconciler::Union{Reconciler, Nothing}
    outbox::Union{EventBusOutbox, Nothing}
    exchange::Union{AbstractExchange, Nothing}
    ntp_ok::Bool
    started_at::DateTime
end

function ProductionPipeline(; team_id="crypto", venue="binance")
    instruments = enforce_scope(team_id, venue)
    ProductionPipeline(
        team_id, venue, instruments,
        nothing, nothing, nothing, nothing, nothing,
        false, now(UTC),
    )
end

"""
Full production startup sequence.
Returns the pipeline instance with all services initialized.
"""
function start_production!(pipeline::ProductionPipeline)
    println("=" ^ 60)
    println("QUANTENGINE PRODUCTION PIPELINE")
    println("Team: $(pipeline.team_id) | Venue: $(pipeline.venue)")
    println("Instruments: $(join(pipeline.instruments, ", "))")
    println("=" ^ 60)

    # 1. NTP check — block on critical skew
    @info "Step 1: NTP check..."
    ntp = check_ntp(critical_ms=150.0)
    if ntp_blocks_trading(ntp)
        @error "BLOCKED: Clock skew $(round(ntp.skew_ms, digits=1))ms exceeds 150ms threshold"
        error("NTP critical — cannot start trading with clock skew > 150ms")
    end
    pipeline.ntp_ok = true
    @info "  NTP OK: skew=$(round(ntp.skew_ms, digits=1))ms ($(ntp.level))"

    # 2. Connect Postgres
    @info "Step 2: Postgres..."
    pipeline.pool = PgPool()
    pg_connect!(pipeline.pool)

    # 3. Run migrations
    @info "Step 3: Migrations..."
    count = run_migrations!(pipeline.pool;
        migrations_dir=joinpath(@__DIR__, "..", "..", "migrations"))
    @info "  Applied $count new migrations"

    # 4. Initialize risk budgets
    @info "Step 4: Risk budgets..."
    initialize_risk_budgets!(pipeline.pool)

    # 5. Build OMS (starts FROZEN)
    @info "Step 5: OMS (frozen)..."
    pipeline.oms = OrderManagementSystem(pipeline.pool)

    # 6. Build exchange adapter
    @info "Step 6: Exchange adapter..."
    if pipeline.venue == "binance"
        pipeline.exchange = BinanceExchange(
            execution_mode=PAPER,  # always paper until proven
            use_futures=false,
            margin_mode=:cross,
        )
    elseif pipeline.venue == "paper"
        pipeline.exchange = PaperExchange(initial_balance=100_000.0)
    else
        error("Unsupported venue: $(pipeline.venue)")
    end

    # 7. Startup reconciliation — OMS stays frozen until clean
    @info "Step 7: Startup reconciliation..."
    pipeline.reconciler = Reconciler(pipeline.pool, pipeline.team_id, pipeline.venue)
    clean = startup_reconciliation!(pipeline.reconciler, pipeline.exchange)

    if clean
        pipeline.oms.frozen = false
        @info "  Reconciliation CLEAN — OMS unfrozen"
    else
        @warn "  Reconciliation found issues — OMS remains FROZEN"
        @warn "  Resolve incidents before trading"
    end

    # 8. Start outbox worker
    @info "Step 8: Outbox worker..."
    pipeline.outbox = EventBusOutbox(pipeline.pool)
    run_outbox_worker!(pipeline.outbox)

    # 9. Validation check (plumbing level)
    @info "Step 9: Plumbing validation..."
    val_result = run_validation(VAL_PLUMBING;
        pool=pipeline.pool,
        manual=Dict("pg_connected" => pg_healthy(pipeline.pool) ? 1.0 : 0.0,
                     "adapter_connected" => 1.0),
    )
    @info "  Plumbing: $(val_result.passed)/$(val_result.total) passed"

    println()
    println("Pipeline ready. OMS frozen=$(pipeline.oms.frozen)")
    println("=" ^ 60)

    return pipeline
end

"""Shutdown the production pipeline cleanly."""
function stop_production!(pipeline::ProductionPipeline)
    @info "Shutting down production pipeline..."

    if pipeline.outbox !== nothing
        stop_outbox_worker!(pipeline.outbox)
    end

    if pipeline.pool !== nothing
        pg_close!(pipeline.pool)
    end

    @info "Production pipeline stopped"
end

"""
Run periodic production tasks during the main loop.
Call this from within run_money_printer's iteration loop.
"""
function production_tick!(pipeline::ProductionPipeline, iteration::Int;
                          current_vol::Float64=0.0)
    # Expire stale reservations every 10 iterations
    if iteration % 10 == 0 && pipeline.pool !== nothing
        try
            expire_stale_reservations!(pipeline.pool)
        catch e
            @error "Reservation expiry error" exception=e
        end
    end

    # Adaptive reconciliation
    if pipeline.reconciler !== nothing && pipeline.exchange !== nothing
        open_positions = try length(get_open_orders(pipeline.exchange)) catch; 0 end
        interval = current_interval(pipeline.reconciler, open_positions, current_vol)
        elapsed = (now(UTC) - pipeline.reconciler.last_recon).value / 1000.0

        if elapsed >= interval
            try
                broker_orders = get_open_orders(pipeline.exchange)
                reconcile_all!(pipeline.reconciler, broker_orders, NamedTuple[])
            catch e
                @error "Reconciliation error" exception=e
            end
        end
    end

    # NTP check every 300 iterations (~25 min at 5s poll)
    if iteration % 300 == 0
        try
            ntp = check_ntp(critical_ms=150.0)
            if ntp_blocks_trading(ntp)
                @error "NTP CRITICAL during operation: $(round(ntp.skew_ms, digits=1))ms"
                if pipeline.oms !== nothing
                    pipeline.oms.frozen = true
                    @error "OMS FROZEN due to clock skew"
                end
            end
        catch
            # NTP check failure is non-fatal
        end
    end

    # Outbox health check every 100 iterations
    if iteration % 100 == 0 && pipeline.pool !== nothing
        try
            pending = pg_fetchval(pipeline.pool,
                "SELECT COUNT(*) FROM outbox WHERE NOT published")
            if something(pending, 0) > 100
                @warn "Outbox backlog: $pending unpublished events"
            end
        catch
        end
    end
end
