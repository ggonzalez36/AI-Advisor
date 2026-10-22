"""Circuit breaker state machine and graceful degradation."""

import pytest

from src.llm import FakeLLMClient
from src.resilience import CircuitBreaker, CircuitOpenError, CircuitState, ResilientRiskStrategy
from src.strategy import LLMRagStrategy, RuleBasedStrategy


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


def failing():
    raise RuntimeError("boom")


def test_opens_after_threshold_and_fails_fast():
    breaker = CircuitBreaker(failure_threshold=2, reset_timeout_s=30, clock=FakeClock())
    calls = 0

    def flaky():
        nonlocal calls
        calls += 1
        raise RuntimeError("provider down")

    for _ in range(2):
        with pytest.raises(RuntimeError):
            breaker.call(flaky)
    assert breaker.state == CircuitState.OPEN

    with pytest.raises(CircuitOpenError):
        breaker.call(flaky)
    assert calls == 2  # While OPEN the dependency is not called


def test_half_open_probe_closes_or_reopens():
    clock = FakeClock()
    breaker = CircuitBreaker(failure_threshold=1, reset_timeout_s=30, clock=clock)
    with pytest.raises(RuntimeError):
        breaker.call(failing)

    clock.now = 31
    assert breaker.state == CircuitState.HALF_OPEN
    with pytest.raises(RuntimeError):
        breaker.call(failing)  # The probe fails -> back to OPEN
    assert breaker.state == CircuitState.OPEN

    clock.now = 62
    assert breaker.call(lambda: "ok") == "ok"  # The probe succeeds -> CLOSED
    assert breaker.state == CircuitState.CLOSED


def test_success_resets_failure_count():
    breaker = CircuitBreaker(failure_threshold=2, clock=FakeClock())
    with pytest.raises(RuntimeError):
        breaker.call(failing)
    breaker.call(lambda: None)
    with pytest.raises(RuntimeError):
        breaker.call(failing)
    assert breaker.state == CircuitState.CLOSED


def test_resilient_strategy_degrades_to_rule_based(balanced_profile):
    llm = FakeLLMClient(fail_times=10)
    strategy = ResilientRiskStrategy(
        LLMRagStrategy(llm),
        RuleBasedStrategy(),
        CircuitBreaker(failure_threshold=2, clock=FakeClock()),
    )

    results = [strategy.evaluate(balanced_profile) for _ in range(4)]

    assert all(r.degraded and r.strategy_used == "RuleBased-Policy" for r in results)
    assert llm.calls == 2  # Once the circuit opens, the provider stops receiving traffic
    assert strategy.breaker.state == CircuitState.OPEN


def test_resilient_strategy_uses_primary_when_healthy(balanced_profile):
    strategy = ResilientRiskStrategy(LLMRagStrategy(FakeLLMClient()), RuleBasedStrategy())
    result = strategy.evaluate(balanced_profile)
    assert not result.degraded
    assert result.strategy_used.startswith("LLM-RAG")
