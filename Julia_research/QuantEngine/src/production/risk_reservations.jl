# ── Atomic Risk Reservations — Postgres Row Locks ──────────────────────
# Risk is INLINE. Signal path blocks on the risk decision.
# No async "maybe later" approval.
#
# Approval is not enough: scarce budget must be atomically reserved.
# Uses SELECT ... FOR UPDATE to prevent concurrent oversubscription.
#
# Reservation lifecycle:
#   ACTIVE → CONSUMED (OMS uses it) | RELEASED (reject/cancel) | EXPIRED (TTL)

using Dates
using UUIDs

@enum ReservationStatus RES_ACTIVE RES_CONSUMED RES_RELEASED RES_EXPIRED
@enum RiskDecisionType DECISION_APPROVED DECISION_REJECTED DECISION_SIZE_REDUCED

struct RiskDecision
    decision_id::UUID
    order_intent_id::UUID
    team_id::String
    decision::RiskDecisionType
    reason::String
    original_qty::Float64
    approved_qty::Float64
    decided_at::DateTime
end

struct RiskReservation
    reservation_id::UUID
    order_intent_id::UUID
    scope::String           # "global", "team:crypto", etc.
    reserved_notional::Float64
    reserved_gross::Float64
    status::ReservationStatus
    expires_at::DateTime
    created_at::DateTime
end

# ── Risk Configuration ────────────────────────────────────────

struct RiskLimits
    global_max_daily_loss_pct::Float64
    global_max_drawdown_pct::Float64
    global_gross_exposure_cap::Float64
    per_team_daily_loss_pct::Float64
    single_position_cap_pct::Float64
    position_count_cap::Int
    reservation_expiry_seconds::Int
end

function default_risk_limits()
    RiskLimits(
        parse(Float64, get(ENV, "QE_MAX_DAILY_LOSS_PCT", "0.05")),
        parse(Float64, get(ENV, "QE_MAX_DRAWDOWN_PCT", "0.15")),
        parse(Float64, get(ENV, "QE_GROSS_EXPOSURE_CAP", "1000000.0")),
        parse(Float64, get(ENV, "QE_PER_TEAM_DAILY_LOSS_PCT", "0.03")),
        parse(Float64, get(ENV, "QE_SINGLE_POSITION_CAP_PCT", "0.10")),
        parse(Int, get(ENV, "QE_POSITION_COUNT_CAP", "50")),
        parse(Int, get(ENV, "QE_RESERVATION_EXPIRY_S", "60")),
    )
end

# ── Pre-Trade Risk Gate ───────────────────────────────────────

"""
Evaluate an order intent against all risk controls.
Returns (decision, reservation_or_nothing).

This is the ONLY entry point. Everything is atomic via Postgres transaction
with row-level locks on risk_budgets.
"""
function evaluate_risk(pool, intent_id::UUID, team_id::String,
                       requested_qty::Float64, estimated_notional::Float64;
                       limits::RiskLimits=default_risk_limits())

    decision_id = uuid4()
    reservation_id = uuid4()
    now = Dates.now(Dates.UTC)
    expires = now + Dates.Second(limits.reservation_expiry_seconds)

    with_locked_transaction(pool) do conn
        # Lock global budget row
        gb_result = LibPQ.execute(conn,
            "SELECT * FROM risk_budgets WHERE scope = 'global' FOR UPDATE"
        )
        gb = columntable(gb_result)
        close(gb_result)

        if isempty(first(values(gb)))
            return (
                decision = RiskDecision(decision_id, intent_id, team_id,
                    DECISION_REJECTED, "no global budget configured",
                    requested_qty, 0.0, now),
                reservation = nothing,
            )
        end

        current_gross = gb[:current_gross_exposure][1]
        max_gross = gb[:max_gross_exposure][1]
        current_loss = gb[:current_daily_loss][1]
        max_loss = gb[:max_daily_loss][1]
        pos_count = gb[:current_position_count][1]
        max_pos = gb[:max_position_count][1]

        # ── Hard limit checks ──

        # 1. Gross exposure cap
        if current_gross + estimated_notional > max_gross
            reason = "gross exposure would exceed cap: $(current_gross + estimated_notional) > $max_gross"
            _persist_rejection!(conn, decision_id, intent_id, team_id, reason, requested_qty, now)
            return (decision = RiskDecision(decision_id, intent_id, team_id,
                DECISION_REJECTED, reason, requested_qty, 0.0, now), reservation = nothing)
        end

        # 2. Daily loss limit
        if current_loss >= max_loss
            reason = "daily loss limit reached: $current_loss >= $max_loss"
            _persist_rejection!(conn, decision_id, intent_id, team_id, reason, requested_qty, now)
            return (decision = RiskDecision(decision_id, intent_id, team_id,
                DECISION_REJECTED, reason, requested_qty, 0.0, now), reservation = nothing)
        end

        # 3. Position count
        if pos_count >= max_pos
            reason = "position count cap: $pos_count >= $max_pos"
            _persist_rejection!(conn, decision_id, intent_id, team_id, reason, requested_qty, now)
            return (decision = RiskDecision(decision_id, intent_id, team_id,
                DECISION_REJECTED, reason, requested_qty, 0.0, now), reservation = nothing)
        end

        # 4. Single position cap
        single_cap = max_gross * limits.single_position_cap_pct
        if estimated_notional > single_cap
            reason = "single position exceeds cap: $estimated_notional > $single_cap"
            _persist_rejection!(conn, decision_id, intent_id, team_id, reason, requested_qty, now)
            return (decision = RiskDecision(decision_id, intent_id, team_id,
                DECISION_REJECTED, reason, requested_qty, 0.0, now), reservation = nothing)
        end

        # ── Approved: create atomic reservation ──

        # Debit budget counters
        LibPQ.execute(conn, """
            UPDATE risk_budgets SET
                current_gross_exposure = current_gross_exposure + \$1,
                current_notional = current_notional + \$1,
                current_position_count = current_position_count + 1,
                updated_at = NOW()
            WHERE scope = 'global'
        """, [estimated_notional])

        # Create reservation
        LibPQ.execute(conn, """
            INSERT INTO risk_reservations (
                reservation_id, order_intent_id, scope,
                reserved_notional, reserved_gross, status, expires_at
            ) VALUES (\$1, \$2, 'global', \$3, \$3, 'ACTIVE', \$4)
        """, [string(reservation_id), string(intent_id), estimated_notional, string(expires)])

        # Persist decision
        LibPQ.execute(conn, """
            INSERT INTO risk_decisions (
                decision_id, order_intent_id, team_id, decision,
                reason, original_qty, approved_qty, decided_at
            ) VALUES (\$1, \$2, \$3, 'APPROVED', 'all checks passed', \$4, \$4, NOW())
        """, [string(decision_id), string(intent_id), team_id, requested_qty])

        @info "APPROVED $(intent_id): notional=$estimated_notional, qty=$requested_qty"

        return (
            decision = RiskDecision(decision_id, intent_id, team_id,
                DECISION_APPROVED, "all checks passed",
                requested_qty, requested_qty, now),
            reservation = RiskReservation(reservation_id, intent_id, "global",
                estimated_notional, estimated_notional, RES_ACTIVE, expires, now),
        )
    end
end

"""Release a reservation — credits budget back."""
function release_reservation!(pool, reservation_id::UUID)
    with_locked_transaction(pool) do conn
        result = LibPQ.execute(conn,
            "SELECT * FROM risk_reservations WHERE reservation_id = \$1 FOR UPDATE",
            [string(reservation_id)]
        )
        data = columntable(result)
        close(result)

        if isempty(first(values(data))) || data[:status][1] != "ACTIVE"
            return
        end

        notional = data[:reserved_notional][1]
        gross = data[:reserved_gross][1]
        scope = data[:scope][1]

        LibPQ.execute(conn, """
            UPDATE risk_budgets SET
                current_gross_exposure = GREATEST(0, current_gross_exposure - \$1),
                current_notional = GREATEST(0, current_notional - \$2),
                current_position_count = GREATEST(0, current_position_count - 1),
                updated_at = NOW()
            WHERE scope = \$3
        """, [gross, notional, scope])

        LibPQ.execute(conn, """
            UPDATE risk_reservations SET status = 'RELEASED', released_at = NOW()
            WHERE reservation_id = \$1
        """, [string(reservation_id)])
    end

    @info "Released reservation: $reservation_id"
end

"""Expire stale reservations that the OMS never consumed."""
function expire_stale_reservations!(pool)::Int
    expired = 0
    with_connection(pool) do conn
        result = LibPQ.execute(conn, """
            SELECT reservation_id FROM risk_reservations
            WHERE status = 'ACTIVE' AND expires_at < NOW()
        """)
        ids = columntable(result)
        close(result)

        if !isempty(first(values(ids)))
            for rid in ids[:reservation_id]
                release_reservation!(pool, UUID(rid))
                expired += 1
            end
        end
    end

    if expired > 0
        @warn "Expired $expired stale reservations"
    end
    return expired
end

"""Initialize the global risk budget if it doesn't exist."""
function initialize_risk_budgets!(pool; limits::RiskLimits=default_risk_limits())
    pg_execute(pool, """
        INSERT INTO risk_budgets (scope, max_gross_exposure, max_notional, max_daily_loss, max_position_count)
        VALUES ('global', \$1, \$1, \$2, \$3)
        ON CONFLICT (scope) DO NOTHING
    """, [limits.global_gross_exposure_cap,
          limits.global_gross_exposure_cap * limits.global_max_daily_loss_pct,
          limits.position_count_cap])
    @info "Risk budgets initialized"
end

# ── Internal helpers ──────────────────────────────────────────

function _persist_rejection!(conn, decision_id::UUID, intent_id::UUID,
                             team_id::String, reason::String, qty::Float64, now::DateTime)
    LibPQ.execute(conn, """
        INSERT INTO risk_decisions (
            decision_id, order_intent_id, team_id, decision,
            reason, original_qty, approved_qty, decided_at
        ) VALUES (\$1, \$2, \$3, 'REJECTED', \$4, \$5, 0, NOW())
    """, [string(decision_id), string(intent_id), team_id, reason, qty])
    @warn "REJECTED $intent_id: $reason"
end
