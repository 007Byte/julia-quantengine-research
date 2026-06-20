"""Shared test fixtures."""

import os
import sys

# Ensure src is importable
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

# Set test environment
os.environ.setdefault("QE_ENVIRONMENT", "dev")
os.environ.setdefault("QE_PG_PASSWORD", "testpassword")
