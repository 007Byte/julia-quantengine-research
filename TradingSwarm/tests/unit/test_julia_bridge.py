"""Unit tests for Julia bridge circuit breaker logic."""

import time

import pytest

from src.core.julia_bridge import CircuitState, JuliaBridge


class TestCircuitBreaker:
    def test_initial_state_closed(self):
        bridge = JuliaBridge()
        assert bridge.circuit_state == CircuitState.CLOSED
        assert bridge.is_healthy

    def test_failure_opens_circuit(self):
        bridge = JuliaBridge()
        bridge._failure_threshold = 3

        for _ in range(3):
            bridge._record_failure()

        assert bridge.circuit_state == CircuitState.OPEN
        assert not bridge.is_healthy

    def test_below_threshold_stays_closed(self):
        bridge = JuliaBridge()
        bridge._failure_threshold = 5

        for _ in range(4):
            bridge._record_failure()

        assert bridge.circuit_state == CircuitState.CLOSED
        assert bridge.is_healthy

    def test_success_resets_count(self):
        bridge = JuliaBridge()
        bridge._failure_threshold = 3

        bridge._record_failure()
        bridge._record_failure()
        bridge._record_success()  # reset

        assert bridge._failure_count == 0
        assert bridge.circuit_state == CircuitState.CLOSED

    def test_open_blocks_requests(self):
        bridge = JuliaBridge()
        bridge._circuit = CircuitState.OPEN
        bridge._circuit_open_until = time.monotonic() + 9999

        allowed = bridge._check_circuit()
        assert not allowed

    def test_half_open_after_cooldown(self):
        bridge = JuliaBridge()
        bridge._circuit = CircuitState.OPEN
        bridge._circuit_open_until = time.monotonic() - 1  # expired

        allowed = bridge._check_circuit()
        assert allowed
        assert bridge.circuit_state == CircuitState.HALF_OPEN

    def test_success_closes_from_half_open(self):
        bridge = JuliaBridge()
        bridge._circuit = CircuitState.HALF_OPEN

        bridge._record_success()

        assert bridge.circuit_state == CircuitState.CLOSED

    def test_failure_from_half_open_reopens(self):
        bridge = JuliaBridge()
        bridge._circuit = CircuitState.HALF_OPEN
        bridge._failure_threshold = 1
        bridge._failure_count = 0

        bridge._record_failure()

        assert bridge.circuit_state == CircuitState.OPEN
