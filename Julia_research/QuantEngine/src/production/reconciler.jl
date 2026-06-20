# ── Reconciler — Broker Truth vs Internal State ────────────────────────
# Runs BOTH:
# - Event-driven reconciliation on broker events/fills
# - Periodic poll-based reconciliation (because venue callbacks can gap)
#
# Polling is correct engineering. Pretending you don't need it is wrong.
# Adaptive polling: 5s when positions open + vol > threshold, else 60s.

using Dates
using UUIDs

@enum IncidentSeverity INC_LOW INC_MEDIUM INC_HIGH INC_CRITICAL
@enum IncidentStatus INC_OPEN INC_ACKNOWLEDGED INC_RESOLVED

struct ReconciliationIncident
    incident_id::UUID
    team_id::String
    venue::String
    incident_type::String
    severity::IncidentSeverity
    expected_state::String
    actual_state::String
    detected_at::DateTime
end

mutable struct Reconciler
    pool::Any                  # PgPool
    team_id::String
    venue::String
    base_interval_s::Float64   # normal polling interval
    fast_interval_s::Float64   # high-vol / positions-open interval
    vol_threshold::Float64     # switch to fast polling above this
    last_recon::DateTime
end

function Reconciler(pool, team_id::String, venue::String)
    Reconciler(pool, team_id, venue, 60.0, 5.0, 0.03, DateTime(0))
end

"""
Determine the current reconciliation polling interval.
Adaptive: fast when positions are open and volatility is high.
"""
function current_interval(recon::Reconciler, open_position_count::Int, current_vol::Float64)::Float64
    if open_position_count > 0 && current_vol > recon.vol_threshold
        return recon.fast_interval_s
    elseif open_position_count > 0
        return min(recon.base_interval_s, 15.0)  # 15s with positions
    else
        return recon.base_interval_s
    end
end

"""
Reconcile internal open orders vs broker open orders.
Returns list of incidents.
"""
function reconcile_orders(recon::Reconciler, broker_open_orders::Vector{NamedTuple})::Vector{ReconciliationIncident}
    incidents = ReconciliationIncident[]
    now = Dates.now(Dates.UTC)

    # Build broker order map
    broker_by_id = Dict{String, NamedTuple}()
    for o in broker_open_orders
        bid = string(get(o, :broker_order_id, ""))
        if !isempty(bid)
            broker_by_id[bid] = o
        end
    end

    # Get internal open orders
    internal = pg_fetch(recon.pool, """
        SELECT venue_order_id_internal, broker_order_id, current_state
        FROM venue_orders
        WHERE venue = \$1
        AND current_state NOT IN ('VENUE_FILLED', 'VENUE_CANCELED', 'VENUE_REJECTED', 'VENUE_EXPIRED')
    """, [recon.venue])

    internal_broker_ids = Set{String}()

    if !isempty(first(values(internal)))
        for i in 1:length(internal[:venue_order_id_internal])
            bid = something(internal[:broker_order_id][i], "")
            if isempty(bid)
                continue
            end
            push!(internal_broker_ids, bid)

            if !haskey(broker_by_id, bid)
                push!(incidents, ReconciliationIncident(
                    uuid4(), recon.team_id, recon.venue,
                    "orphaned_internal_order", INC_HIGH,
                    "broker_order_id=$bid state=$(internal[:current_state][i])",
                    "not_found_at_broker",
                    now,
                ))
            end
        end
    end

    # Broker orders we don't know about
    for (bid, order) in broker_by_id
        if !(bid in internal_broker_ids)
            push!(incidents, ReconciliationIncident(
                uuid4(), recon.team_id, recon.venue,
                "unknown_broker_order", INC_CRITICAL,
                "no_internal_record",
                "broker_order_id=$bid",
                now,
            ))
        end
    end

    return incidents
end

"""
Reconcile internal positions vs broker positions.
Returns list of incidents.
"""
function reconcile_positions(recon::Reconciler, broker_positions::Vector{NamedTuple})::Vector{ReconciliationIncident}
    incidents = ReconciliationIncident[]
    now = Dates.now(Dates.UTC)

    # Build broker position map
    broker_by_sym = Dict{String, NamedTuple}()
    for p in broker_positions
        sym = string(get(p, :symbol, ""))
        qty = get(p, :quantity, 0.0)
        if !isempty(sym) && abs(qty) > 1e-10
            broker_by_sym[sym] = p
        end
    end

    # Get internal positions
    # (Use the existing PositionTracker state for comparison)
    # For now, check against strategy_positions in Postgres
    internal = pg_fetch(recon.pool, """
        SELECT instrument_id, quantity, avg_entry_price
        FROM strategy_positions
        WHERE team_id = \$1 AND quantity != 0
    """, [recon.team_id])

    # Note: in production, we need instrument_id → venue_symbol mapping
    # For now, log any non-zero positions for awareness

    # Check broker positions we don't track
    for (sym, bpos) in broker_by_sym
        broker_qty = get(bpos, :quantity, 0.0)
        if abs(broker_qty) > 1e-8
            # Check if we have a matching internal position
            # This requires symbol mapping — simplified for now
            push!(incidents, ReconciliationIncident(
                uuid4(), recon.team_id, recon.venue,
                "broker_position_check", INC_MEDIUM,
                "need_symbol_mapping_to_verify",
                "broker: $sym qty=$broker_qty",
                now,
            ))
        end
    end

    return incidents
end

"""Full reconciliation: orders + positions. Persists incidents to Postgres."""
function reconcile_all!(recon::Reconciler, broker_orders::Vector{NamedTuple},
                        broker_positions::Vector{NamedTuple})::Vector{ReconciliationIncident}
    order_incidents = reconcile_orders(recon, broker_orders)
    position_incidents = reconcile_positions(recon, broker_positions)
    all_incidents = vcat(order_incidents, position_incidents)

    recon.last_recon = Dates.now(Dates.UTC)

    # Persist incidents
    for inc in all_incidents
        pg_execute(recon.pool, """
            INSERT INTO reconciliation_incidents (
                incident_id, team_id, venue, incident_type,
                severity, expected_state, actual_state, status, detected_at
            ) VALUES (\$1, \$2, \$3, \$4, \$5, \$6, \$7, 'open', \$8)
        """, [
            string(inc.incident_id), inc.team_id, inc.venue,
            inc.incident_type, string(inc.severity),
            inc.expected_state, inc.actual_state,
            string(inc.detected_at),
        ])
    end

    critical = filter(i -> i.severity == INC_CRITICAL, all_incidents)
    if !isempty(critical)
        @error "RECONCILIATION: $(length(critical)) CRITICAL incidents on $(recon.venue)"
    elseif !isempty(all_incidents)
        @warn "Reconciliation: $(length(all_incidents)) incidents on $(recon.venue)"
    else
        @info "Reconciliation clean: $(recon.team_id)/$(recon.venue)"
    end

    return all_incidents
end

"""Startup reconciliation — OMS stays frozen until this returns clean."""
function startup_reconciliation!(recon::Reconciler, exchange::AbstractExchange)::Bool
    broker_orders = try
        get_open_orders(exchange)
    catch e
        @error "Startup recon: failed to get broker orders" exception=e
        return false
    end

    broker_positions = try
        # Use get_positions if available on the exchange
        NamedTuple[]  # placeholder — each exchange implements differently
    catch e
        @error "Startup recon: failed to get broker positions" exception=e
        return false
    end

    incidents = reconcile_all!(recon, broker_orders, broker_positions)
    critical = filter(i -> i.severity == INC_CRITICAL, incidents)

    if !isempty(critical)
        @error "STARTUP RECONCILIATION FAILED: $(length(critical)) critical incidents. OMS stays FROZEN."
        return false
    elseif !isempty(incidents)
        @warn "Startup reconciliation: $(length(incidents)) non-critical incidents. Review before unfreezing."
        return false
    end

    @info "Startup reconciliation CLEAN for $(recon.team_id)/$(recon.venue)"
    return true
end

"""Count unresolved incidents for this team/venue."""
function unresolved_incident_count(recon::Reconciler)::Int
    val = pg_fetchval(recon.pool, """
        SELECT COUNT(*) FROM reconciliation_incidents
        WHERE team_id = \$1 AND venue = \$2 AND status != 'resolved'
    """, [recon.team_id, recon.venue])
    return something(val, 0)
end
