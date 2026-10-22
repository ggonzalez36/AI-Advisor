"""
LLM abstraction for structured generation.

`LLMClient.generate` returns a validated Pydantic model instead of free text, so the
rest of the pipeline never parses strings. Two implementations:

- `FakeLLMClient`: deterministic, offline, zero cost. Used in tests, CI and evals. It
  can also simulate failures and hallucinated citations to exercise the circuit
  breaker and guardrails.
- `AnthropicLLMClient`: Claude via the official SDK with schema-validated outputs
  (`messages.parse(output_format=...)`). Optional dependency: `uv sync --extra llm`.
"""

from __future__ import annotations

import os
from collections.abc import Callable, Mapping
from typing import Any, Protocol, TypeVar

from pydantic import BaseModel, ValidationError

T = TypeVar("T", bound=BaseModel)

DEFAULT_ANTHROPIC_MODEL = "claude-opus-5-5"


class LLMError(RuntimeError):
    """Any failure producing a valid structured answer (network, refusal, invalid schema)."""


class LLMClient(Protocol):
    name: str

    def generate(
        self,
        *,
        system: str,
        user: str,
        response_model: type[T],
        context: Mapping[str, Any],
    ) -> T:
        """Return `response_model` validated. `context` carries the same facts rendered in
        `user` as structured data (used by the fake client and for tracing)."""
        ...


Responder = Callable[[Mapping[str, Any]], dict[str, Any]]


class FakeLLMClient:
    """Deterministic stand-in for an LLM.

    Args:
        responder: builds the raw answer from the structured context.
        fail_times: number of initial calls that raise LLMError (simulates an outage).
        hallucinate: cite a document that was never retrieved (tests groundedness checks).
    """

    name = "fake-llm"

    def __init__(
        self,
        responder: Responder | None = None,
        *,
        fail_times: int = 0,
        hallucinate: bool = False,
    ) -> None:
        self._responder = responder or default_risk_responder
        self._remaining_failures = fail_times
        self._hallucinate = hallucinate
        self.calls = 0

    def generate(
        self,
        *,
        system: str,  # noqa: ARG002 - part of the protocol
        user: str,  # noqa: ARG002
        response_model: type[T],
        context: Mapping[str, Any],
    ) -> T:
        self.calls += 1
        if self._remaining_failures > 0:
            self._remaining_failures -= 1
            raise LLMError("simulated provider outage (HTTP 503)")

        raw = self._responder(context)
        if self._hallucinate:
            raw = {**raw, "citations": [*raw.get("citations", []), "sec_filing_2027#insider-tip"]}
        try:
            return response_model.model_validate(raw)
        except ValidationError as exc:
            raise LLMError(f"invalid structured output: {exc}") from exc


def default_risk_responder(context: Mapping[str, Any]) -> dict[str, Any]:
    """Plausible, grounded answer derived from the quantitative context."""
    metrics = context["metrics"]
    allocation = context["policy_allocation"]
    retrieved = list(context.get("retrieved_ids", []))

    score = min(
        1.0, metrics["volatility_annual"] / 0.30 + max(0.0, metrics["max_position_weight"] - 0.20)
    )
    citations = retrieved[:2]
    return {
        "risk_level": context["risk_tolerance"],
        "risk_score": round(score, 3),
        "equity": allocation.get("EQUITY", 0.0),
        "fixed_income": allocation.get("FIXED_INCOME", 0.0),
        "cash_equivalent": allocation.get("CASH_EQUIVALENT", 0.0),
        "commodity": allocation.get("COMMODITY", 0.0),
        "crypto": allocation.get("CRYPTO", 0.0),
        "rationale": (
            f"Annualized volatility {metrics['volatility_annual']:.1%} and largest position "
            f"{metrics['max_position_weight']:.1%} of AUM. Allocation follows the policy band "
            f"for {context['risk_tolerance']} investors (see {', '.join(citations) or 'policy'})."
        ),
        "citations": citations,
    }


INJECTION_MARKER = "SYSTEM OVERRIDE"


def injection_susceptible_responder(context: Mapping[str, Any]) -> dict[str, Any]:
    """Simulates a model VULNERABLE to indirect prompt injection: if a retrieved document
    contains instructions, it obeys them (allocates 50% to crypto and cites the poisoned document).
    Used to show that the guardrails contain the damage even when the model fails."""
    answer = default_risk_responder(context)
    poisoned = [
        cid for cid, text in context.get("retrieved_texts", {}).items() if INJECTION_MARKER in text
    ]
    if poisoned:
        answer.update(equity=0.3, fixed_income=0.1, cash_equivalent=0.1, commodity=0.0, crypto=0.5)
        answer["citations"] = [*answer["citations"], *poisoned]
    return answer


class AnthropicLLMClient:
    """Claude with schema-validated structured outputs."""

    def __init__(self, model: str = DEFAULT_ANTHROPIC_MODEL, max_tokens: int = 16000) -> None:
        try:
            import anthropic
        except ImportError as exc:  # pragma: no cover - depends on optional extra
            raise LLMError("install the 'llm' extra: uv sync --extra llm") from exc

        self._anthropic = anthropic
        self._client = anthropic.Anthropic()  # Credentials from env / `ant auth login`
        self._model = model
        self._max_tokens = max_tokens
        self.name = f"anthropic:{model}"

    def generate(
        self,
        *,
        system: str,
        user: str,
        response_model: type[T],
        context: Mapping[str, Any],  # noqa: ARG002 - rendered into `user` already
    ) -> T:
        try:
            response = self._client.messages.parse(
                model=self._model,
                max_tokens=self._max_tokens,
                system=system,
                messages=[{"role": "user", "content": user}],
                output_format=response_model,
            )
        except self._anthropic.APIError as exc:
            # Rate limits, 5xx and connection errors (after SDK retries) count as failures
            # for the circuit breaker, which degrades to the rule-based strategy.
            raise LLMError(f"anthropic API error: {exc}") from exc

        if response.stop_reason == "refusal":
            raise LLMError("model declined the request")
        if response.parsed_output is None:
            raise LLMError(f"no structured output (stop_reason={response.stop_reason})")
        return response.parsed_output


def llm_from_env() -> LLMClient:
    """`LLM_PROVIDER=anthropic` uses Claude; anything else (default) uses the fake client."""
    if os.getenv("LLM_PROVIDER", "fake").lower() == "anthropic":
        return AnthropicLLMClient(model=os.getenv("ANTHROPIC_MODEL", DEFAULT_ANTHROPIC_MODEL))
    return FakeLLMClient()
