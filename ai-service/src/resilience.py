"""
Resilience: Circuit Breaker + graceful degradation for the LLM strategy.

State machine (docs/architecture-design.md, diagram 4):
    CLOSED --(failures >= threshold)--> OPEN --(reset_timeout elapsed)--> HALF_OPEN
    HALF_OPEN --(probe succeeds)--> CLOSED
    HALF_OPEN --(probe fails)-----> OPEN

While OPEN, calls fail fast (no request reaches the provider) and the advisor answers
from the rule-based strategy, flagged as `degraded` so it is routed to human review.
"""

from __future__ import annotations

import logging
import threading
import time
from collections.abc import Callable
from enum import StrEnum
from typing import TypeVar

from src.retrieval import RetrievedChunk
from src.strategy import PortfolioProfile, RiskAssessmentResult, RiskEvaluationStrategy

logger = logging.getLogger(__name__)
T = TypeVar("T")


class CircuitState(StrEnum):
    CLOSED = "CLOSED"
    OPEN = "OPEN"
    HALF_OPEN = "HALF_OPEN"


class CircuitOpenError(RuntimeError):
    """Raised without calling the dependency while the circuit is OPEN."""


class CircuitBreaker:
    def __init__(
        self,
        failure_threshold: int = 3,
        reset_timeout_s: float = 30.0,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._threshold = failure_threshold
        self._reset_timeout = reset_timeout_s
        self._clock = clock
        self._state = CircuitState.CLOSED
        self._failures = 0
        self._opened_at = 0.0
        self._lock = threading.Lock()  # FastAPI runs sync handlers in a threadpool

    @property
    def state(self) -> CircuitState:
        with self._lock:
            return self._current_state()

    def call(self, fn: Callable[[], T]) -> T:
        with self._lock:
            if self._current_state() == CircuitState.OPEN:
                raise CircuitOpenError("circuit open: failing fast")

        try:
            result = fn()
        except Exception:
            self._on_failure()
            raise
        self._on_success()
        return result

    def _current_state(self) -> CircuitState:
        if (
            self._state == CircuitState.OPEN
            and self._clock() - self._opened_at >= self._reset_timeout
        ):
            self._state = CircuitState.HALF_OPEN
        return self._state

    def _on_success(self) -> None:
        with self._lock:
            if self._state != CircuitState.CLOSED:
                logger.info("circuit breaker: probe succeeded, closing circuit")
            self._state = CircuitState.CLOSED
            self._failures = 0

    def _on_failure(self) -> None:
        with self._lock:
            self._failures += 1
            if self._state == CircuitState.HALF_OPEN or self._failures >= self._threshold:
                logger.warning("circuit breaker: opening circuit after %d failures", self._failures)
                self._state = CircuitState.OPEN
                self._opened_at = self._clock()


class ResilientRiskStrategy(RiskEvaluationStrategy):
    """Decorator: wraps a primary strategy with a circuit breaker and a fallback strategy."""

    def __init__(
        self,
        primary: RiskEvaluationStrategy,
        fallback: RiskEvaluationStrategy,
        breaker: CircuitBreaker | None = None,
    ) -> None:
        self.primary = primary
        self.fallback = fallback
        self.breaker = breaker or CircuitBreaker()

    @property
    def strategy_name(self) -> str:
        return f"Resilient[{self.primary.strategy_name} -> {self.fallback.strategy_name}]"

    def evaluate(
        self, profile: PortfolioProfile, context: list[RetrievedChunk] | None = None
    ) -> RiskAssessmentResult:
        try:
            return self.breaker.call(lambda: self.primary.evaluate(profile, context))
        except Exception as exc:  # noqa: BLE001 - any primary failure degrades gracefully
            logger.warning("primary strategy unavailable (%s); using fallback", exc)
            result = self.fallback.evaluate(profile, context)
            return result.model_copy(
                update={"degraded": True, "rationale": f"[DEGRADED: {exc}] {result.rationale}"}
            )
