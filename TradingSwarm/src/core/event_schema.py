"""
Canonical event schema — every trade-critical entity and event type.

All types are immutable Pydantic models with required tracing fields.
Business entities carry their own IDs (not Redis stream message IDs).
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from decimal import Decimal
from enum import StrEnum
from typing import Any

import orjson
from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _utcnow() -> datetime:
    return datetime.now(timezone.utc)


def _new_id() -> uuid.UUID:
    return uuid.uuid4()


def _serialize(obj: BaseModel) -> bytes:
    return orjson.dumps(obj.model_dump(mode="json"))


def _deserialize(cls: type[BaseModel], data: bytes | str) -> BaseModel:
    return cls.model_validate(orjson.loads(data))


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

class AssetClass(StrEnum):
    CRYPTO = "crypto"
    EQUITY = "equity"
    ETF = "etf"
    FX = "fx"
    PREDICTION = "prediction"
    OPTION = "option"


class InstrumentType(StrEnum):
    SPOT = "spot"
    PERPETUAL = "perpetual"
    DATED_FUTURE = "dated_future"
    EQUITY = "equity"
    ETF = "etf"
    ADR = "adr"
    EQUITY_OPTION = "equity_option"
    FX_SPOT = "fx_spot"
    FX_CFD = "fx_cfd"
    YES_NO_SHARE = "yes_no_share"


class Side(StrEnum):
    BUY = "buy"
    SELL = "sell"


class OrderIntentType(StrEnum):
    MARKET = "market"
    LIMIT = "limit"
    STOP = "stop"
    STOP_LIMIT = "stop_limit"


class TimeInForce(StrEnum):
    GTC = "gtc"
    IOC = "ioc"
    FOK = "fok"
    DAY = "day"
    GTD = "gtd"


class OrderIntentState(StrEnum):
    INTENT_CREATED = "intent_created"
    RISK_PENDING = "risk_pending"
    RISK_APPROVED = "risk_approved"
    RESERVING_BUDGET = "reserving_budget"
    ACCEPTED_BY_OMS = "accepted_by_oms"
    ROUTING = "routing"
    WORKING = "working"
    PARTIALLY_FILLED = "partially_filled"
    FILLED = "filled"
    CANCELED = "canceled"
    REJECTED = "rejected"
    EXPIRED = "expired"
    SUSPENDED = "suspended"


class VenueOrderState(StrEnum):
    CHILD_CREATED = "child_created"
    SUBMITTED = "submitted"
    ACKNOWLEDGED = "acknowledged"
    PARTIALLY_FILLED = "partially_filled"
    FILLED = "filled"
    CANCEL_REQUESTED = "cancel_requested"
    CANCELED = "canceled"
    REJECTED = "rejected"
    EXPIRED = "expired"
    UNKNOWN_BUT_OPEN = "unknown_but_open"


class ReservationStatus(StrEnum):
    ACTIVE = "active"
    RELEASED = "released"
    CONSUMED = "consumed"
    EXPIRED = "expired"


class RiskDecisionType(StrEnum):
    APPROVED = "approved"
    REJECTED = "rejected"
    SIZE_REDUCED = "size_reduced"


class IncidentSeverity(StrEnum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    CRITICAL = "critical"


class IncidentStatus(StrEnum):
    OPEN = "open"
    ACKNOWLEDGED = "acknowledged"
    RESOLVED = "resolved"


# ---------------------------------------------------------------------------
# Tracing mixin — attached to all critical events/entities
# ---------------------------------------------------------------------------

class TracingFields(BaseModel):
    """Fields that every trade-critical entity/event must carry."""
    team_id: str
    instrument_id: uuid.UUID
    venue: str = ""
    strategy_id: str = ""
    signal_id: uuid.UUID | None = None
    order_intent_id: uuid.UUID | None = None
    reservation_id: uuid.UUID | None = None
    correlation_id: uuid.UUID = Field(default_factory=_new_id)
    event_time_utc: datetime = Field(default_factory=_utcnow)
    ingest_time_utc: datetime = Field(default_factory=_utcnow)
    model_version: str = ""
    feature_version: str = ""
    config_hash: str = ""


# ---------------------------------------------------------------------------
# Market data events
# ---------------------------------------------------------------------------

class NormalizedBar(BaseModel):
    instrument_id: uuid.UUID
    venue: str
    timeframe: str
    time: datetime
    open: Decimal
    high: Decimal
    low: Decimal
    close: Decimal
    volume: Decimal


class NormalizedTrade(BaseModel):
    instrument_id: uuid.UUID
    venue: str
    time: datetime
    price: Decimal
    quantity: Decimal
    side: Side | None = None


class NormalizedQuote(BaseModel):
    instrument_id: uuid.UUID
    venue: str
    time: datetime
    bid_price: Decimal
    bid_size: Decimal
    ask_price: Decimal
    ask_size: Decimal


# ---------------------------------------------------------------------------
# Signal events
# ---------------------------------------------------------------------------

class SignalEvent(BaseModel):
    signal_id: uuid.UUID = Field(default_factory=_new_id)
    team_id: str
    strategy_id: str
    instrument_id: uuid.UUID
    side: Side
    strength: float  # 0.0 to 1.0
    model_version: str
    feature_version: str
    config_hash: str
    correlation_id: uuid.UUID = Field(default_factory=_new_id)
    created_at: datetime = Field(default_factory=_utcnow)
    metadata: dict[str, Any] = Field(default_factory=dict)


# ---------------------------------------------------------------------------
# Order intent
# ---------------------------------------------------------------------------

class OrderIntent(BaseModel):
    order_intent_id: uuid.UUID = Field(default_factory=_new_id)
    idempotency_key: str
    team_id: str
    strategy_id: str
    instrument_id: uuid.UUID
    venue_preference: str = ""
    side: Side
    intent_type: OrderIntentType
    requested_qty: Decimal
    limit_price: Decimal | None = None
    stop_price: Decimal | None = None
    time_in_force: TimeInForce = TimeInForce.GTC
    signal_id: uuid.UUID | None = None
    correlation_id: uuid.UUID = Field(default_factory=_new_id)
    model_version: str
    feature_version: str
    config_hash: str
    current_state: OrderIntentState = OrderIntentState.INTENT_CREATED
    created_at: datetime = Field(default_factory=_utcnow)
    updated_at: datetime = Field(default_factory=_utcnow)


# ---------------------------------------------------------------------------
# Risk reservation
# ---------------------------------------------------------------------------

class RiskReservation(BaseModel):
    reservation_id: uuid.UUID = Field(default_factory=_new_id)
    order_intent_id: uuid.UUID
    scope: str  # "global", "team", "venue", "factor:<name>"
    reserved_notional: Decimal = Decimal("0")
    reserved_gross: Decimal = Decimal("0")
    reserved_margin: Decimal = Decimal("0")
    status: ReservationStatus = ReservationStatus.ACTIVE
    expires_at: datetime | None = None
    created_at: datetime = Field(default_factory=_utcnow)
    released_at: datetime | None = None


# ---------------------------------------------------------------------------
# Risk decision
# ---------------------------------------------------------------------------

class RiskDecision(BaseModel):
    decision_id: uuid.UUID = Field(default_factory=_new_id)
    order_intent_id: uuid.UUID
    team_id: str
    decision: RiskDecisionType
    reason: str = ""
    original_qty: Decimal | None = None
    approved_qty: Decimal | None = None
    risk_snapshot: dict[str, Any] = Field(default_factory=dict)
    decided_at: datetime = Field(default_factory=_utcnow)


# ---------------------------------------------------------------------------
# Venue order (child)
# ---------------------------------------------------------------------------

class VenueOrder(BaseModel):
    venue_order_id_internal: uuid.UUID = Field(default_factory=_new_id)
    order_intent_id: uuid.UUID
    venue: str
    child_seq: int
    broker_order_id: str | None = None
    current_state: VenueOrderState = VenueOrderState.CHILD_CREATED
    requested_qty: Decimal
    submitted_qty: Decimal | None = None
    filled_qty: Decimal = Decimal("0")
    remaining_qty: Decimal | None = None
    limit_price: Decimal | None = None
    avg_fill_price: Decimal | None = None
    submitted_at: datetime | None = None
    updated_at: datetime = Field(default_factory=_utcnow)


# ---------------------------------------------------------------------------
# Order event
# ---------------------------------------------------------------------------

class OrderEvent(BaseModel):
    event_id: uuid.UUID = Field(default_factory=_new_id)
    order_intent_id: uuid.UUID | None = None
    venue_order_id_internal: uuid.UUID | None = None
    event_type: str
    broker_order_id: str | None = None
    event_time_utc: datetime = Field(default_factory=_utcnow)
    ingest_time_utc: datetime = Field(default_factory=_utcnow)
    payload: dict[str, Any] = Field(default_factory=dict)


# ---------------------------------------------------------------------------
# Fill
# ---------------------------------------------------------------------------

class Fill(BaseModel):
    fill_id: uuid.UUID = Field(default_factory=_new_id)
    order_intent_id: uuid.UUID
    venue_order_id_internal: uuid.UUID | None = None
    instrument_id: uuid.UUID
    team_id: str
    strategy_id: str
    venue: str
    side: Side
    quantity: Decimal
    price: Decimal
    fee: Decimal = Decimal("0")
    fee_currency: str = ""
    expected_fill_price: Decimal | None = None
    slippage_bps: Decimal | None = None
    fill_time_utc: datetime = Field(default_factory=_utcnow)
    ingest_time_utc: datetime = Field(default_factory=_utcnow)


# ---------------------------------------------------------------------------
# Strategy position
# ---------------------------------------------------------------------------

class StrategyPosition(BaseModel):
    team_id: str
    strategy_id: str
    instrument_id: uuid.UUID
    quantity: Decimal = Decimal("0")
    avg_entry_price: Decimal | None = None
    realized_pnl: Decimal = Decimal("0")
    cost_basis: Decimal = Decimal("0")
    lots: list[dict[str, Any]] = Field(default_factory=list)
    updated_at: datetime = Field(default_factory=_utcnow)


# ---------------------------------------------------------------------------
# Reconciliation incident
# ---------------------------------------------------------------------------

class ReconciliationIncident(BaseModel):
    incident_id: uuid.UUID = Field(default_factory=_new_id)
    team_id: str
    venue: str
    incident_type: str
    severity: IncidentSeverity
    expected_state: dict[str, Any] = Field(default_factory=dict)
    actual_state: dict[str, Any] = Field(default_factory=dict)
    status: IncidentStatus = IncidentStatus.OPEN
    detected_at: datetime = Field(default_factory=_utcnow)
    resolved_at: datetime | None = None


# ---------------------------------------------------------------------------
# Stream event wrapper — used for Redis Streams transport
# ---------------------------------------------------------------------------

class StreamEnvelope(BaseModel):
    """Wraps any business event for Redis Streams transport."""
    envelope_id: uuid.UUID = Field(default_factory=_new_id)
    event_type: str
    payload: bytes  # serialized inner event
    correlation_id: uuid.UUID = Field(default_factory=_new_id)
    produced_at: datetime = Field(default_factory=_utcnow)
    idempotency_key: str = ""

    @classmethod
    def wrap(cls, event_type: str, event: BaseModel, idempotency_key: str = "") -> StreamEnvelope:
        return cls(
            event_type=event_type,
            payload=_serialize(event),
            correlation_id=getattr(event, "correlation_id", _new_id()),
            idempotency_key=idempotency_key or str(_new_id()),
        )

    def to_stream_dict(self) -> dict[str, str]:
        """Format for XADD."""
        return {
            "envelope_id": str(self.envelope_id),
            "event_type": self.event_type,
            "payload": self.payload.decode("utf-8") if isinstance(self.payload, bytes) else self.payload,
            "correlation_id": str(self.correlation_id),
            "produced_at": self.produced_at.isoformat(),
            "idempotency_key": self.idempotency_key,
        }
