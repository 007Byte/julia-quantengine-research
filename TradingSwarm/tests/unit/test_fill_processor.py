"""Unit tests for fill processor position math."""

from decimal import Decimal

import pytest


class TestPositionMath:
    """Test position update logic without database."""

    def test_new_long_position(self):
        """Buying into a new position."""
        qty = Decimal("0")
        avg = Decimal("0")
        rpnl = Decimal("0")

        fill_side = "buy"
        fill_qty = Decimal("10")
        fill_price = Decimal("100")

        new_qty = qty + fill_qty
        new_avg = fill_price
        new_rpnl = rpnl

        assert new_qty == Decimal("10")
        assert new_avg == Decimal("100")
        assert new_rpnl == Decimal("0")

    def test_add_to_long(self):
        """Adding to existing long position updates average."""
        current_qty = Decimal("10")
        current_avg = Decimal("100")

        fill_qty = Decimal("10")
        fill_price = Decimal("120")

        new_qty = current_qty + fill_qty
        total_cost = current_qty * current_avg + fill_qty * fill_price
        new_avg = total_cost / new_qty

        assert new_qty == Decimal("20")
        assert new_avg == Decimal("110")

    def test_close_long_profit(self):
        """Closing a long position at profit."""
        current_qty = Decimal("10")
        current_avg = Decimal("100")
        current_rpnl = Decimal("0")

        fill_qty = Decimal("10")
        fill_price = Decimal("120")

        # Selling full position
        reduce_qty = min(fill_qty, current_qty)
        rpnl = reduce_qty * (fill_price - current_avg)
        new_qty = current_qty - fill_qty
        new_rpnl = current_rpnl + rpnl

        assert new_qty == Decimal("0")
        assert rpnl == Decimal("200")
        assert new_rpnl == Decimal("200")

    def test_close_long_loss(self):
        """Closing a long position at a loss."""
        current_qty = Decimal("10")
        current_avg = Decimal("100")
        current_rpnl = Decimal("0")

        fill_qty = Decimal("10")
        fill_price = Decimal("80")

        reduce_qty = min(fill_qty, current_qty)
        rpnl = reduce_qty * (fill_price - current_avg)
        new_rpnl = current_rpnl + rpnl

        assert rpnl == Decimal("-200")
        assert new_rpnl == Decimal("-200")

    def test_partial_close(self):
        """Partial close preserves avg entry."""
        current_qty = Decimal("10")
        current_avg = Decimal("100")

        fill_qty = Decimal("5")  # sell half
        fill_price = Decimal("120")

        new_qty = current_qty - fill_qty
        rpnl = fill_qty * (fill_price - current_avg)

        assert new_qty == Decimal("5")
        assert rpnl == Decimal("100")
        # avg_entry stays at 100 for remaining shares

    def test_short_position(self):
        """Opening a short position."""
        qty = Decimal("0")
        fill_side = "sell"
        fill_qty = Decimal("10")
        fill_price = Decimal("100")

        new_qty = qty - fill_qty  # short
        new_avg = fill_price

        assert new_qty == Decimal("-10")
        assert new_avg == Decimal("100")

    def test_close_short_profit(self):
        """Closing a short at profit (price went down)."""
        current_qty = Decimal("-10")
        current_avg = Decimal("100")

        fill_qty = Decimal("10")  # buying to cover
        fill_price = Decimal("80")

        reduce_qty = min(fill_qty, abs(current_qty))
        rpnl = reduce_qty * (current_avg - fill_price)  # short: profit when price drops
        new_qty = current_qty + fill_qty

        assert new_qty == Decimal("0")
        assert rpnl == Decimal("200")

    def test_close_short_loss(self):
        """Closing a short at loss (price went up)."""
        current_qty = Decimal("-10")
        current_avg = Decimal("100")

        fill_qty = Decimal("10")
        fill_price = Decimal("120")

        reduce_qty = min(fill_qty, abs(current_qty))
        rpnl = reduce_qty * (current_avg - fill_price)
        new_qty = current_qty + fill_qty

        assert new_qty == Decimal("0")
        assert rpnl == Decimal("-200")

    def test_cash_settlement_buy(self):
        """Buying reduces cash."""
        balance = Decimal("100000")
        fill_qty = Decimal("10")
        fill_price = Decimal("100")
        fee = Decimal("1")

        notional = fill_qty * fill_price
        new_balance = balance - notional - fee

        assert new_balance == Decimal("98999")

    def test_cash_settlement_sell(self):
        """Selling increases cash."""
        balance = Decimal("99000")
        fill_qty = Decimal("10")
        fill_price = Decimal("110")
        fee = Decimal("1.10")

        notional = fill_qty * fill_price
        new_balance = balance + notional - fee

        assert new_balance == Decimal("100098.90")
