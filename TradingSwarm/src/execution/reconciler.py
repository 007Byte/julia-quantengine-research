"""
Reconciler — broker truth vs internal state.

Runs both:
- Event-driven reconciliation (on broker events/fills)
- Periodic poll-based reconciliation (even if streams look healthy)

Mandatory because venue callbacks can gap.
"""

from __future__ import annotations

import logging
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Protocol

from src.core.event_schema import IncidentSeverity, IncidentStatus, ReconciliationIncident
from src.ledger import postgres

logger = logging.getLogger(__name__)


class BrokerAdapter(Protocol):
    """Protocol that broker adapters must implement for reconciliation."""

    async def get_open_orders(self) -> list[dict[str, Any]]: ...
    async def get_positions(self) -> list[dict[str, Any]]: ...
    async def get_balances(self) -> dict[str, Any]: ...


class Reconciler:
    """
    Compares internal OMS/position state against broker truth.

    On mismatch:
    1. Creates a reconciliation incident (DB + stream)
    2. Logs the discrepancy
    3. If severity is critical, freezes the OMS
    """

    def __init__(self, team_id: str, venue: str) -> None:
        self.team_id = team_id
        self.venue = venue

    async def reconcile_orders(self, adapter: BrokerAdapter) -> list[ReconciliationIncident]:
        """Compare internal open orders vs broker open orders."""
        incidents: list[ReconciliationIncident] = []

        # Get broker truth
        broker_orders = await adapter.get_open_orders()
        broker_by_id: dict[str, dict] = {
            o.get("broker_order_id", ""): o for o in broker_orders if o.get("broker_order_id")
        }

        # Get internal open orders
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            internal_orders = await conn.fetch("""
                SELECT * FROM venue_orders
                WHERE venue = $1
                AND current_state NOT IN ('filled', 'canceled', 'rejected', 'expired')
            """, self.venue)

            for order in internal_orders:
                broker_id = order["broker_order_id"]
                if not broker_id:
                    continue

                if broker_id not in broker_by_id:
                    # Internal says open, broker doesn't know about it
                    incident = ReconciliationIncident(
                        team_id=self.team_id,
                        venue=self.venue,
                        incident_type="orphaned_internal_order",
                        severity=IncidentSeverity.HIGH,
                        expected_state={"broker_order_id": broker_id, "state": order["current_state"]},
                        actual_state={"broker_state": "not_found"},
                    )
                    incidents.append(incident)

            # Check for broker orders we don't know about
            internal_broker_ids = {
                o["broker_order_id"] for o in internal_orders if o["broker_order_id"]
            }
            for broker_id, broker_order in broker_by_id.items():
                if broker_id not in internal_broker_ids:
                    incident = ReconciliationIncident(
                        team_id=self.team_id,
                        venue=self.venue,
                        incident_type="unknown_broker_order",
                        severity=IncidentSeverity.CRITICAL,
                        expected_state={"internal": "not_found"},
                        actual_state=broker_order,
                    )
                    incidents.append(incident)

        await self._persist_incidents(incidents)
        return incidents

    async def reconcile_positions(self, adapter: BrokerAdapter) -> list[ReconciliationIncident]:
        """Compare internal positions vs broker positions."""
        incidents: list[ReconciliationIncident] = []

        broker_positions = await adapter.get_positions()
        broker_pos_map: dict[str, dict] = {}
        for p in broker_positions:
            key = p.get("symbol", "") or p.get("instrument_id", "")
            if key:
                broker_pos_map[key] = p

        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            # Get internal positions for this team
            internal_positions = await conn.fetch("""
                SELECT sp.*, sm.venue_symbol
                FROM strategy_positions sp
                JOIN symbol_mapping sm ON sp.instrument_id = sm.instrument_id AND sm.venue = $1
                WHERE sp.team_id = $2 AND sp.quantity != 0
            """, self.venue, self.team_id)

            for pos in internal_positions:
                venue_symbol = pos["venue_symbol"]
                internal_qty = Decimal(str(pos["quantity"]))

                broker_pos = broker_pos_map.pop(venue_symbol, None)
                if broker_pos is None:
                    # We think we have a position, broker disagrees
                    incident = ReconciliationIncident(
                        team_id=self.team_id,
                        venue=self.venue,
                        incident_type="position_mismatch_missing_at_broker",
                        severity=IncidentSeverity.CRITICAL,
                        expected_state={"symbol": venue_symbol, "quantity": str(internal_qty)},
                        actual_state={"broker_quantity": "0"},
                    )
                    incidents.append(incident)
                    continue

                broker_qty = Decimal(str(broker_pos.get("quantity", 0)))
                if abs(internal_qty - broker_qty) > Decimal("0.00001"):
                    incident = ReconciliationIncident(
                        team_id=self.team_id,
                        venue=self.venue,
                        incident_type="position_quantity_mismatch",
                        severity=IncidentSeverity.HIGH,
                        expected_state={"symbol": venue_symbol, "quantity": str(internal_qty)},
                        actual_state={"broker_quantity": str(broker_qty)},
                    )
                    incidents.append(incident)

            # Broker has positions we don't know about
            for symbol, broker_pos in broker_pos_map.items():
                broker_qty = Decimal(str(broker_pos.get("quantity", 0)))
                if abs(broker_qty) > Decimal("0.00001"):
                    incident = ReconciliationIncident(
                        team_id=self.team_id,
                        venue=self.venue,
                        incident_type="unknown_broker_position",
                        severity=IncidentSeverity.CRITICAL,
                        expected_state={"internal": "no_position"},
                        actual_state={"symbol": symbol, "quantity": str(broker_qty)},
                    )
                    incidents.append(incident)

        await self._persist_incidents(incidents)
        return incidents

    async def reconcile_all(self, adapter: BrokerAdapter) -> list[ReconciliationIncident]:
        """Full reconciliation: orders + positions."""
        order_incidents = await self.reconcile_orders(adapter)
        position_incidents = await self.reconcile_positions(adapter)
        all_incidents = order_incidents + position_incidents

        if all_incidents:
            critical = [i for i in all_incidents if i.severity == IncidentSeverity.CRITICAL]
            logger.warning(
                "Reconciliation: %d incidents (%d critical) for %s/%s",
                len(all_incidents), len(critical), self.team_id, self.venue,
            )
        else:
            logger.info("Reconciliation clean: %s/%s", self.team_id, self.venue)

        return all_incidents

    async def get_unresolved_count(self) -> int:
        """Count unresolved incidents for this team/venue."""
        pool = await postgres.get_pool()
        count = await postgres.fetchval(
            """
            SELECT COUNT(*) FROM reconciliation_incidents
            WHERE team_id = $1 AND venue = $2 AND status != 'resolved'
            """,
            self.team_id, self.venue,
        )
        return count or 0

    async def resolve_incident(
        self, incident_id: uuid.UUID, notes: str = ""
    ) -> None:
        """Mark an incident as resolved."""
        await postgres.execute(
            """
            UPDATE reconciliation_incidents SET
                status = 'resolved', resolved_at = NOW(), resolution_notes = $2
            WHERE incident_id = $1
            """,
            incident_id, notes,
        )

    async def _persist_incidents(
        self, incidents: list[ReconciliationIncident]
    ) -> None:
        if not incidents:
            return
        pool = await postgres.get_pool()
        async with pool.acquire() as conn:
            for inc in incidents:
                await conn.execute(
                    """
                    INSERT INTO reconciliation_incidents (
                        incident_id, team_id, venue, incident_type,
                        severity, expected_state, actual_state, status, detected_at
                    ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
                    """,
                    inc.incident_id, inc.team_id, inc.venue,
                    inc.incident_type, inc.severity.value,
                    inc.expected_state, inc.actual_state,
                    inc.status.value, inc.detected_at,
                )


async def startup_reconciliation(
    team_id: str,
    venue: str,
    adapter: BrokerAdapter,
) -> bool:
    """
    Startup reconciliation — MUST pass before OMS unfreezes.

    Returns True if clean, False if incidents found.
    """
    recon = Reconciler(team_id, venue)
    incidents = await recon.reconcile_all(adapter)

    if incidents:
        critical = [i for i in incidents if i.severity == IncidentSeverity.CRITICAL]
        if critical:
            logger.error(
                "STARTUP RECONCILIATION FAILED: %d critical incidents. "
                "OMS will remain FROZEN.",
                len(critical),
            )
            return False
        logger.warning(
            "Startup reconciliation: %d non-critical incidents. "
            "Review before unfreezing.",
            len(incidents),
        )
        return False

    logger.info("Startup reconciliation CLEAN for %s/%s", team_id, venue)
    return True
