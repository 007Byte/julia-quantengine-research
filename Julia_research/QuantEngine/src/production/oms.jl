# ── Order Management System — Parent/Child with State Machine ──────────
# DB-first: all state transitions written to Postgres before anything else.
# No order without a durable intent. No fill without a durable record.
#
# Parent intent = strategic desire ("buy $10K BTC")
# Child venue order = tactical execution ("submit 0.2 BTC @ market on Binance")

using Dates
using UUIDs

# ── State Machines ────────────────────────────────────────────

@enum IntentState begin
    INTENT_CREATED
    RISK_PENDING
    RISK_APPROVED
    RESERVING_BUDGET
    ACCEPTED_BY_OMS
    ROUTING
    WORKING
    PARTIALLY_FILLED
    FILLED
    CANCELED
    REJECTED
    EXPIRED
    SUSPENDED
end

@enum VenueOrderState begin
    CHILD_CREATED
    SUBMITTED
    ACKNOWLEDGED
    VENUE_PARTIALLY_FILLED
    VENUE_FILLED
    CANCEL_REQUESTED
    VENUE_CANCELED
    VENUE_REJECTED
    VENUE_EXPIRED
    UNKNOWN_BUT_OPEN
end

# Valid parent intent transitions — DAG, no backward edges
const INTENT_TRANSITIONS = Dict{IntentState, Set{IntentState}}(
    INTENT_CREATED     => Set([RISK_PENDING]),
    RISK_PENDING       => Set([RISK_APPROVED, REJECTED]),
    RISK_APPROVED      => Set([RESERVING_BUDGET]),
    RESERVING_BUDGET   => Set([ACCEPTED_BY_OMS, REJECTED]),
    ACCEPTED_BY_OMS    => Set([ROUTING]),
    ROUTING            => Set([WORKING, REJECTED, CANCELED]),
    WORKING            => Set([PARTIALLY_FILLED, FILLED, CANCELED, SUSPENDED]),
    PARTIALLY_FILLED   => Set([PARTIALLY_FILLED, FILLED, CANCELED, SUSPENDED]),
    SUSPENDED          => Set([WORKING, CANCELED]),
)

# Terminal states — no further transitions
const TERMINAL_INTENT_STATES = Set([FILLED, CANCELED, REJECTED, EXPIRED])

# Valid child venue order transitions
const VENUE_TRANSITIONS = Dict{VenueOrderState, Set{VenueOrderState}}(
    CHILD_CREATED         => Set([SUBMITTED]),
    SUBMITTED             => Set([ACKNOWLEDGED, VENUE_REJECTED, UNKNOWN_BUT_OPEN]),
    ACKNOWLEDGED          => Set([VENUE_PARTIALLY_FILLED, VENUE_FILLED, CANCEL_REQUESTED, VENUE_CANCELED, VENUE_EXPIRED]),
    VENUE_PARTIALLY_FILLED => Set([VENUE_PARTIALLY_FILLED, VENUE_FILLED, CANCEL_REQUESTED, VENUE_CANCELED]),
    CANCEL_REQUESTED      => Set([VENUE_CANCELED, VENUE_FILLED, VENUE_PARTIALLY_FILLED]),
    UNKNOWN_BUT_OPEN      => Set([ACKNOWLEDGED, VENUE_FILLED, VENUE_CANCELED, VENUE_REJECTED]),
)

"""Check if a state transition is valid."""
function valid_transition(from::IntentState, to::IntentState)::Bool
    allowed = get(INTENT_TRANSITIONS, from, Set{IntentState}())
    return to in allowed
end

function valid_venue_transition(from::VenueOrderState, to::VenueOrderState)::Bool
    allowed = get(VENUE_TRANSITIONS, from, Set{VenueOrderState}())
    return to in allowed
end

# ── Data Types ────────────────────────────────────────────────

struct OrderIntent
    order_intent_id::UUID
    idempotency_key::String
    team_id::String
    strategy_id::String
    instrument_id::String      # canonical instrument identifier
    venue_preference::String
    side::Symbol               # :buy, :sell
    intent_type::Symbol        # :market, :limit, :stop, :stop_limit
    requested_qty::Float64
    limit_price::Float64       # 0.0 if market
    stop_price::Float64        # 0.0 if not stop
    time_in_force::Symbol      # :gtc, :ioc, :fok, :day
    signal_id::String
    correlation_id::UUID
    model_version::String
    feature_version::String
    config_hash::String
    current_state::IntentState
    created_at::DateTime
end

struct VenueOrder
    venue_order_id::UUID
    order_intent_id::UUID
    venue::String
    child_seq::Int
    broker_order_id::String
    current_state::VenueOrderState
    requested_qty::Float64
    submitted_qty::Float64
    filled_qty::Float64
    remaining_qty::Float64
    limit_price::Float64
    avg_fill_price::Float64
    submitted_at::Union{DateTime, Nothing}
end

struct Fill
    fill_id::UUID
    order_intent_id::UUID
    venue_order_id::UUID
    instrument_id::String
    team_id::String
    strategy_id::String
    venue::String
    side::Symbol
    quantity::Float64
    price::Float64
    fee::Float64
    fee_currency::String
    expected_price::Float64
    slippage_bps::Float64
    fill_time::DateTime
end

# ── OMS Core ──────────────────────────────────────────────────

mutable struct OrderManagementSystem
    pool::Any                  # PgPool — typed as Any to avoid circular deps
    frozen::Bool
    lock::ReentrantLock
end

function OrderManagementSystem(pool)
    return OrderManagementSystem(pool, true, ReentrantLock())  # starts FROZEN
end

"""Accept a risk-approved intent into the OMS. Deduplicates on idempotency_key."""
function accept_intent!(oms::OrderManagementSystem, intent::OrderIntent)
    if oms.frozen
        error("OMS is frozen — no new orders until reconciliation passes")
    end

    if intent.current_state != RISK_APPROVED
        error("OMS only accepts RISK_APPROVED intents, got $(intent.current_state)")
    end

    with_transaction(oms.pool) do conn
        # Dedupe check
        existing = LibPQ.execute(conn,
            "SELECT order_intent_id, current_state FROM order_intents WHERE idempotency_key = \$1",
            [intent.idempotency_key]
        )
        existing_data = columntable(existing)
        close(existing)

        if !isempty(first(values(existing_data)))
            @info "Duplicate intent: $(intent.idempotency_key)"
            return nothing
        end

        # Insert intent as ACCEPTED_BY_OMS
        LibPQ.execute(conn, """
            INSERT INTO order_intents (
                order_intent_id, idempotency_key, team_id, strategy_id,
                instrument_id, venue_preference, side, intent_type,
                requested_qty, limit_price, stop_price, time_in_force,
                signal_id, correlation_id, model_version, feature_version,
                config_hash, current_state
            ) VALUES (\$1,\$2,\$3,\$4,\$5,\$6,\$7,\$8,\$9,\$10,\$11,\$12,\$13,\$14,\$15,\$16,\$17,\$18)
        """, [
            string(intent.order_intent_id), intent.idempotency_key,
            intent.team_id, intent.strategy_id,
            intent.instrument_id, intent.venue_preference,
            string(intent.side), string(intent.intent_type),
            intent.requested_qty, intent.limit_price,
            intent.stop_price, string(intent.time_in_force),
            intent.signal_id, string(intent.correlation_id),
            intent.model_version, intent.feature_version,
            intent.config_hash, "ACCEPTED_BY_OMS",
        ])

        # Write order event
        LibPQ.execute(conn, """
            INSERT INTO order_events (event_id, order_intent_id, event_type, event_time_utc)
            VALUES (\$1, \$2, 'intent.accepted_by_oms', NOW())
        """, [string(uuid4()), string(intent.order_intent_id)])
    end

    @info "Intent accepted: $(intent.order_intent_id) [$(intent.side) $(intent.requested_qty)]"
    return intent
end

"""Transition a parent intent to a new state. Validates the state machine."""
function transition_intent!(oms::OrderManagementSystem, intent_id::UUID, new_state::IntentState;
                            event_type::String="", payload::String="{}")
    with_transaction(oms.pool) do conn
        # Lock the row
        result = LibPQ.execute(conn,
            "SELECT current_state FROM order_intents WHERE order_intent_id = \$1 FOR UPDATE",
            [string(intent_id)]
        )
        data = columntable(result)
        close(result)

        if isempty(first(values(data)))
            error("Unknown intent: $intent_id")
        end

        current_str = first(values(data))[1]
        current = parse_intent_state(current_str)

        if !valid_transition(current, new_state)
            error("Invalid transition: $current → $new_state")
        end

        LibPQ.execute(conn, """
            UPDATE order_intents SET current_state = \$1, updated_at = NOW()
            WHERE order_intent_id = \$2
        """, [string(new_state), string(intent_id)])

        etype = isempty(event_type) ? "intent.$(lowercase(string(new_state)))" : event_type
        LibPQ.execute(conn, """
            INSERT INTO order_events (event_id, order_intent_id, event_type, event_time_utc, payload)
            VALUES (\$1, \$2, \$3, NOW(), \$4)
        """, [string(uuid4()), string(intent_id), etype, payload])
    end

    @info "Intent $intent_id: → $new_state"
end

"""Create a child venue order for a parent intent."""
function create_child_order!(oms::OrderManagementSystem, intent_id::UUID, venue::String,
                             qty::Float64; limit_price::Float64=0.0)
    child_id = uuid4()
    child_seq = 1

    with_connection(oms.pool) do conn
        # Get next sequence
        result = LibPQ.execute(conn,
            "SELECT COALESCE(MAX(child_seq), 0) FROM venue_orders WHERE order_intent_id = \$1",
            [string(intent_id)]
        )
        data = columntable(result)
        close(result)
        max_seq = first(values(data))[1]
        child_seq = (max_seq === nothing ? 0 : max_seq) + 1

        LibPQ.execute(conn, """
            INSERT INTO venue_orders (
                venue_order_id_internal, order_intent_id, venue, child_seq,
                current_state, requested_qty, remaining_qty, limit_price
            ) VALUES (\$1,\$2,\$3,\$4,\$5,\$6,\$7,\$8)
        """, [
            string(child_id), string(intent_id), venue, child_seq,
            "CHILD_CREATED", qty, qty, limit_price,
        ])
    end

    @info "Child order: $child_id (parent=$intent_id, seq=$child_seq, venue=$venue)"
    return (id=child_id, seq=child_seq)
end

"""Record a fill and update order states."""
function record_fill!(oms::OrderManagementSystem, fill::Fill)
    with_transaction(oms.pool) do conn
        # Insert fill
        LibPQ.execute(conn, """
            INSERT INTO fills (
                fill_id, order_intent_id, venue_order_id_internal,
                instrument_id, team_id, strategy_id, venue, side,
                quantity, price, fee, fee_currency,
                expected_fill_price, slippage_bps, fill_time_utc
            ) VALUES (\$1,\$2,\$3,\$4,\$5,\$6,\$7,\$8,\$9,\$10,\$11,\$12,\$13,\$14,\$15)
        """, [
            string(fill.fill_id), string(fill.order_intent_id),
            string(fill.venue_order_id), fill.instrument_id,
            fill.team_id, fill.strategy_id, fill.venue,
            string(fill.side), fill.quantity, fill.price,
            fill.fee, fill.fee_currency,
            fill.expected_price, fill.slippage_bps,
            string(fill.fill_time),
        ])

        # Update venue order
        LibPQ.execute(conn, """
            UPDATE venue_orders SET
                filled_qty = filled_qty + \$1,
                remaining_qty = requested_qty - filled_qty - \$1,
                avg_fill_price = \$2,
                updated_at = NOW()
            WHERE venue_order_id_internal = \$3
        """, [fill.quantity, fill.price, string(fill.venue_order_id)])
    end

    @info "Fill: $(fill.fill_id) [$(fill.side) $(fill.quantity) @ $(fill.price)]"
end

"""Load all unfinished intents and venue orders (for restart recovery)."""
function load_unfinished(oms::OrderManagementSystem)
    intents = pg_fetch(oms.pool, """
        SELECT * FROM order_intents
        WHERE current_state NOT IN ('FILLED', 'CANCELED', 'REJECTED', 'EXPIRED')
        ORDER BY created_at
    """)

    orders = pg_fetch(oms.pool, """
        SELECT * FROM venue_orders
        WHERE current_state NOT IN ('VENUE_FILLED', 'VENUE_CANCELED', 'VENUE_REJECTED', 'VENUE_EXPIRED')
        ORDER BY updated_at
    """)

    @info "Loaded $(length(first(values(intents)))) unfinished intents, $(length(first(values(orders)))) unfinished venue orders"
    return (intents=intents, orders=orders)
end

# ── State Parsing ─────────────────────────────────────────────

function parse_intent_state(s::AbstractString)::IntentState
    mapping = Dict(
        "INTENT_CREATED" => INTENT_CREATED,
        "RISK_PENDING" => RISK_PENDING,
        "RISK_APPROVED" => RISK_APPROVED,
        "RESERVING_BUDGET" => RESERVING_BUDGET,
        "ACCEPTED_BY_OMS" => ACCEPTED_BY_OMS,
        "ROUTING" => ROUTING,
        "WORKING" => WORKING,
        "PARTIALLY_FILLED" => PARTIALLY_FILLED,
        "FILLED" => FILLED,
        "CANCELED" => CANCELED,
        "REJECTED" => REJECTED,
        "EXPIRED" => EXPIRED,
        "SUSPENDED" => SUSPENDED,
    )
    return get(mapping, uppercase(s), INTENT_CREATED)
end
