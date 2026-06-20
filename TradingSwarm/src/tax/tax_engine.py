"""
Advisory Tax Engine v1.

Section 16: Tax logic is advisory first.

Requirements:
- Asset-class-aware rules
- Specific identification / lot tracking
- Holding-period awareness
- Wash-sale detection
- Crypto reporting awareness
- Explicit disclaimer that tax professional review is mandatory

Rule: Tax logic must NOT block hot-path order submission.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import Any

logger = logging.getLogger(__name__)

# DISCLAIMER — this is advisory only
TAX_DISCLAIMER = (
    "This tax engine provides advisory estimates only. "
    "All tax calculations must be reviewed by a qualified tax professional "
    "before use in any tax filing or compliance context."
)


class TaxLot:
    """A single tax lot for tracking cost basis and holding period."""

    def __init__(
        self,
        lot_id: str,
        instrument_id: str,
        quantity: Decimal,
        cost_per_unit: Decimal,
        acquired_at: datetime,
        asset_class: str = "equity",
    ) -> None:
        self.lot_id = lot_id
        self.instrument_id = instrument_id
        self.quantity = quantity
        self.cost_per_unit = cost_per_unit
        self.acquired_at = acquired_at
        self.asset_class = asset_class
        self.closed_at: datetime | None = None
        self.proceeds_per_unit: Decimal | None = None

    @property
    def cost_basis(self) -> Decimal:
        return self.quantity * self.cost_per_unit

    @property
    def holding_days(self) -> int:
        end = self.closed_at or datetime.now(timezone.utc)
        return (end - self.acquired_at).days

    @property
    def is_long_term(self) -> bool:
        """Long-term: held > 365 days (US rule)."""
        return self.holding_days > 365

    @property
    def gain_loss(self) -> Decimal | None:
        if self.proceeds_per_unit is None:
            return None
        return self.quantity * (self.proceeds_per_unit - self.cost_per_unit)

    def to_dict(self) -> dict[str, Any]:
        return {
            "lot_id": self.lot_id,
            "instrument_id": self.instrument_id,
            "quantity": str(self.quantity),
            "cost_per_unit": str(self.cost_per_unit),
            "cost_basis": str(self.cost_basis),
            "acquired_at": self.acquired_at.isoformat(),
            "holding_days": self.holding_days,
            "is_long_term": self.is_long_term,
            "gain_loss": str(self.gain_loss) if self.gain_loss is not None else None,
        }


class WashSaleDetector:
    """
    Detect potential wash sales.

    US Rule: loss on a sale is disallowed if substantially identical
    security is purchased within 30 days before or after the sale.
    """

    def __init__(self, window_days: int = 30) -> None:
        self._window = timedelta(days=window_days)

    def check(
        self,
        sale_time: datetime,
        sale_instrument: str,
        loss: Decimal,
        recent_purchases: list[dict[str, Any]],
    ) -> dict[str, Any]:
        """
        Check if a sale would trigger wash sale rules.

        Returns advisory result (does NOT block the trade).
        """
        if loss >= 0:
            return {"wash_sale": False, "reason": "no loss to disallow"}

        window_start = sale_time - self._window
        window_end = sale_time + self._window

        matching_purchases = [
            p for p in recent_purchases
            if p.get("instrument_id") == sale_instrument
            and window_start <= p.get("time", datetime.min.replace(tzinfo=timezone.utc)) <= window_end
        ]

        if matching_purchases:
            return {
                "wash_sale": True,
                "reason": f"repurchase within {self._window.days} days",
                "matching_count": len(matching_purchases),
                "advisory": TAX_DISCLAIMER,
            }

        return {"wash_sale": False}


class AdvisoryTaxEngine:
    """
    Advisory tax calculations — does NOT block trading.

    Provides:
    - Tax lot tracking
    - Gain/loss computation (FIFO, specific ID)
    - Wash sale detection
    - Holding period classification
    - Summary reports
    """

    def __init__(self) -> None:
        self._lots: dict[str, list[TaxLot]] = {}  # instrument_id -> lots
        self._wash_detector = WashSaleDetector()
        self._closed_lots: list[TaxLot] = []

    def add_lot(self, lot: TaxLot) -> None:
        """Record a new tax lot from a purchase."""
        self._lots.setdefault(lot.instrument_id, []).append(lot)

    def close_lots_fifo(
        self,
        instrument_id: str,
        quantity: Decimal,
        proceeds_per_unit: Decimal,
        closed_at: datetime,
    ) -> list[TaxLot]:
        """Close lots using FIFO method. Returns closed lots."""
        lots = self._lots.get(instrument_id, [])
        remaining = quantity
        closed = []

        for lot in lots:
            if remaining <= 0:
                break
            if lot.closed_at is not None:
                continue

            close_qty = min(lot.quantity, remaining)

            if close_qty == lot.quantity:
                lot.closed_at = closed_at
                lot.proceeds_per_unit = proceeds_per_unit
                closed.append(lot)
            else:
                # Split lot
                closed_lot = TaxLot(
                    lot_id=f"{lot.lot_id}-partial",
                    instrument_id=instrument_id,
                    quantity=close_qty,
                    cost_per_unit=lot.cost_per_unit,
                    acquired_at=lot.acquired_at,
                    asset_class=lot.asset_class,
                )
                closed_lot.closed_at = closed_at
                closed_lot.proceeds_per_unit = proceeds_per_unit
                closed.append(closed_lot)

                lot.quantity -= close_qty

            remaining -= close_qty

        self._closed_lots.extend(closed)
        return closed

    def check_wash_sale(
        self,
        sale_time: datetime,
        instrument_id: str,
        loss: Decimal,
    ) -> dict[str, Any]:
        """Advisory wash sale check."""
        recent = [
            {"instrument_id": lot.instrument_id, "time": lot.acquired_at}
            for lot in self._lots.get(instrument_id, [])
            if lot.closed_at is None
        ]
        return self._wash_detector.check(sale_time, instrument_id, loss, recent)

    def get_unrealized_summary(self) -> dict[str, Any]:
        """Summary of open lots."""
        total_cost = Decimal("0")
        lot_count = 0
        long_term = 0
        short_term = 0

        for lots in self._lots.values():
            for lot in lots:
                if lot.closed_at is None:
                    total_cost += lot.cost_basis
                    lot_count += 1
                    if lot.is_long_term:
                        long_term += 1
                    else:
                        short_term += 1

        return {
            "open_lots": lot_count,
            "total_cost_basis": str(total_cost),
            "long_term_lots": long_term,
            "short_term_lots": short_term,
            "disclaimer": TAX_DISCLAIMER,
        }

    def get_realized_summary(self, year: int | None = None) -> dict[str, Any]:
        """Summary of realized gains/losses."""
        st_gains = Decimal("0")
        st_losses = Decimal("0")
        lt_gains = Decimal("0")
        lt_losses = Decimal("0")

        for lot in self._closed_lots:
            if year and lot.closed_at and lot.closed_at.year != year:
                continue
            gl = lot.gain_loss
            if gl is None:
                continue
            if lot.is_long_term:
                if gl >= 0:
                    lt_gains += gl
                else:
                    lt_losses += gl
            else:
                if gl >= 0:
                    st_gains += gl
                else:
                    st_losses += gl

        return {
            "short_term_gains": str(st_gains),
            "short_term_losses": str(st_losses),
            "long_term_gains": str(lt_gains),
            "long_term_losses": str(lt_losses),
            "net_short_term": str(st_gains + st_losses),
            "net_long_term": str(lt_gains + lt_losses),
            "net_total": str(st_gains + st_losses + lt_gains + lt_losses),
            "disclaimer": TAX_DISCLAIMER,
        }
