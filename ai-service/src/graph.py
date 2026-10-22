"""
Advisory workflow orchestrated with LangGraph.

    retrieve -> assess -> propose -> guardrails --blocking------------> reject
                                               --needs review-------> human_review --approved--> execute
                                               |                                   --rejected--> reject
                                               --clean--------------> execute

- `human_review` pauses the graph with `interrupt()`; the state is persisted by the
  checkpointer and resumed later with `Command(resume=...)` (human-in-the-loop).
- `execute` sends orders to portfolio-api with an Idempotency-Key derived from the
  thread id, so retries or replays never duplicate orders.
- State values are JSON-serializable dicts so any checkpointer (memory, Postgres,
  Redis) can persist them.
"""

from __future__ import annotations

import inspect
import json
import logging
import operator
import time
import uuid
from collections import Counter
from collections.abc import Callable
from typing import Annotated, Any, Literal, Protocol, TypedDict

import httpx
from langchain_core.runnables import RunnableConfig
from langgraph.checkpoint.memory import MemorySaver
from langgraph.graph import END, START, StateGraph
from langgraph.types import Command, interrupt

from src.guardrails import GuardrailReport, evaluate_guardrails
from src.rebalancing import TradeProposal, propose_trades
from src.retrieval import Chunk, RetrievedChunk, Retriever
from src.strategy import (
    AssetClass,
    PortfolioProfile,
    RiskAssessmentResult,
    RiskEvaluationStrategy,
    compute_portfolio_metrics,
)

logger = logging.getLogger(__name__)


def merge_dicts(left: dict[str, Any] | None, right: dict[str, Any] | None) -> dict[str, Any]:
    return {**(left or {}), **(right or {})}


class AdvisoryState(TypedDict, total=False):
    profile: dict[str, Any]
    retrieved: list[dict[str, Any]]
    assessment: dict[str, Any]
    proposals: list[dict[str, Any]]
    guardrails: dict[str, Any]
    review: dict[str, Any]
    executions: list[dict[str, Any]]
    status: str
    trace: Annotated[list[str], operator.add]  # Reducer: cada nodo agrega su paso
    node_latency_ms: Annotated[dict[str, float], merge_dicts]  # Observabilidad por nodo
    initiator: str  # Quién solicitó la asesoría (control four-eyes en la revisión)


def timed(name: str, fn: Callable[..., AdvisoryState]) -> Callable[..., AdvisoryState]:
    """Envuelve un nodo para medir su latencia (observabilidad por paso del grafo)."""
    takes_config = "config" in inspect.signature(fn).parameters

    def wrapper(state: AdvisoryState, config: RunnableConfig) -> AdvisoryState:
        start = time.perf_counter()
        update = dict(fn(state, config) if takes_config else fn(state))
        update["node_latency_ms"] = {name: round((time.perf_counter() - start) * 1000, 2)}
        return update

    return wrapper


class OrderExecutor(Protocol):
    def submit(
        self, portfolio_id: str, proposal: TradeProposal, idempotency_key: str
    ) -> dict[str, Any]: ...


class DryRunExecutor:
    """Records orders without sending them (default when portfolio-api is not configured)."""

    def __init__(self) -> None:
        self.submitted: list[dict[str, Any]] = []

    def submit(
        self, portfolio_id: str, proposal: TradeProposal, idempotency_key: str
    ) -> dict[str, Any]:
        record = {
            "portfolio_id": portfolio_id,
            "symbol": proposal.symbol,
            "quantity": proposal.quantity,
            "price": proposal.limit_price,
            "idempotency_key": idempotency_key,
            "status": "DRY_RUN",
        }
        self.submitted.append(record)
        return record


class PortfolioApiExecutor:
    """Submits orders to the Go transactional backend (POST /api/v1/orders/buy)."""

    def __init__(self, base_url: str, timeout_s: float = 5.0) -> None:
        self._client = httpx.Client(base_url=base_url, timeout=timeout_s)

    def submit(
        self, portfolio_id: str, proposal: TradeProposal, idempotency_key: str
    ) -> dict[str, Any]:
        base = {
            "symbol": proposal.symbol,
            "quantity": proposal.quantity,
            "idempotency_key": idempotency_key,
        }
        try:
            resp = self._client.post(
                "/api/v1/orders/buy",
                headers={"Idempotency-Key": idempotency_key},
                json={
                    "portfolio_id": portfolio_id,
                    "symbol": proposal.symbol,
                    "quantity": proposal.quantity,
                    "price": proposal.limit_price,
                },
            )
        except httpx.HTTPError as exc:
            return {**base, "status": "FAILED", "error": str(exc)}

        if resp.status_code in (200, 202):
            return {**base, "status": "SUBMITTED", "order_id": resp.json()["order"]["id"]}
        if resp.status_code == 429:
            return {**base, "status": "RETRY_LATER", "retry_after": resp.headers.get("Retry-After")}
        return {
            **base,
            "status": "FAILED",
            "http_status": resp.status_code,
            "error": resp.text[:200],
        }


def build_retrieval_queries(profile: PortfolioProfile) -> list[str]:
    """Descompone el perfil en sub-consultas, una por preocupación relevante (multi-query)."""
    metrics = compute_portfolio_metrics(profile)
    queries = [
        f"{profile.risk_tolerance.value.lower()} risk tolerance strategic allocation bands",
        "suitability human review recommendation",
    ]
    if profile.investment_horizon_years > 15 or profile.investment_horizon_years < 3:
        queries.append(f"investment horizon {profile.investment_horizon_years} years glide path")
    held = {h.asset_class for h in profile.holdings}
    if AssetClass.CRYPTO in held:
        queries.append("crypto volatility exposure cap")
    if metrics.max_position_weight > 0.20:
        queries.append("single stock concentration risk diversification")
    if metrics.weights.get(AssetClass.CASH_EQUIVALENT.value, 0.0) > 0.20:
        queries.append("excess idle cash drag deploy")
    if AssetClass.FIXED_INCOME in held or profile.risk_tolerance.value in (
        "CONSERVATIVE",
        "BALANCED",
    ):
        queries.append("fixed income bonds interest rates")
    return queries


def _to_chunks(retrieved: list[dict[str, Any]]) -> list[RetrievedChunk]:
    return [
        RetrievedChunk(Chunk(r["chunk_id"], r["doc_id"], r["title"], r["text"]), r["score"])
        for r in retrieved
    ]


def build_advisory_graph(
    strategy: RiskEvaluationStrategy,
    retriever: Retriever,
    executor: OrderExecutor,
    checkpointer: Any | None = None,
    top_k: int = 5,
):
    def retrieve(state: AdvisoryState) -> AdvisoryState:
        profile = PortfolioProfile.model_validate(state["profile"])
        hits = retriever.search_many(build_retrieval_queries(profile), k=top_k)
        return {
            "retrieved": [
                {
                    "chunk_id": h.chunk_id,
                    "doc_id": h.doc_id,
                    "title": h.chunk.title,
                    "text": h.chunk.text,
                    "score": round(h.score, 4),
                }
                for h in hits
            ],
            "trace": ["retrieve"],
        }

    def assess(state: AdvisoryState) -> AdvisoryState:
        profile = PortfolioProfile.model_validate(state["profile"])
        result = strategy.evaluate(profile, _to_chunks(state.get("retrieved", [])))
        return {"assessment": result.model_dump(mode="json"), "trace": ["assess"]}

    def propose(state: AdvisoryState) -> AdvisoryState:
        profile = PortfolioProfile.model_validate(state["profile"])
        assessment = RiskAssessmentResult.model_validate(state["assessment"])
        proposals = propose_trades(profile, assessment)
        return {"proposals": [p.model_dump() for p in proposals], "trace": ["propose"]}

    def guardrails(state: AdvisoryState) -> AdvisoryState:
        report = evaluate_guardrails(
            PortfolioProfile.model_validate(state["profile"]),
            RiskAssessmentResult.model_validate(state["assessment"]),
            [TradeProposal.model_validate(p) for p in state.get("proposals", [])],
            [r["chunk_id"] for r in state.get("retrieved", [])],
        )
        return {"guardrails": report.model_dump(), "trace": ["guardrails"]}

    def route_after_guardrails(
        state: AdvisoryState,
    ) -> Literal["reject", "human_review", "execute"]:
        report = GuardrailReport.model_validate(state["guardrails"])
        if not report.passed:
            return "reject"
        return "human_review" if report.review_reasons else "execute"

    def human_review(state: AdvisoryState) -> AdvisoryState:
        # Pausa el grafo hasta que un asesor responda; el valor de reanudación llega aquí.
        decision = interrupt(
            {
                "portfolio_id": state["profile"]["portfolio_id"],
                "reasons": state["guardrails"]["review_reasons"],
                "proposals": state.get("proposals", []),
            }
        )
        return {"review": dict(decision), "trace": ["human_review"]}

    def route_after_review(state: AdvisoryState) -> Literal["execute", "reject"]:
        return "execute" if state.get("review", {}).get("approved") else "reject"

    def execute(state: AdvisoryState, config: RunnableConfig) -> AdvisoryState:
        thread_id = config["configurable"]["thread_id"]
        portfolio_id = state["profile"]["portfolio_id"]
        proposals = [TradeProposal.model_validate(p) for p in state.get("proposals", [])]
        if not proposals:
            return {"executions": [], "status": "NO_ACTION", "trace": ["execute"]}

        executions = [
            executor.submit(portfolio_id, p, idempotency_key=f"{thread_id}:{i}:{p.symbol}")
            for i, p in enumerate(proposals)
        ]
        ok = all(e["status"] in ("SUBMITTED", "DRY_RUN") for e in executions)
        return {
            "executions": executions,
            "status": "EXECUTED" if ok else "PARTIALLY_EXECUTED",
            "trace": ["execute"],
        }

    def reject(_state: AdvisoryState) -> AdvisoryState:
        return {"status": "REJECTED", "trace": ["reject"]}

    graph = StateGraph(AdvisoryState)
    graph.add_node("retrieve", timed("retrieve", retrieve))
    graph.add_node("assess", timed("assess", assess))
    graph.add_node("propose", timed("propose", propose))
    graph.add_node("guardrails", timed("guardrails", guardrails))
    graph.add_node("human_review", timed("human_review", human_review))
    graph.add_node("execute", timed("execute", execute))
    graph.add_node("reject", timed("reject", reject))

    graph.add_edge(START, "retrieve")
    graph.add_edge("retrieve", "assess")
    graph.add_edge("assess", "propose")
    graph.add_edge("propose", "guardrails")
    graph.add_conditional_edges("guardrails", route_after_guardrails)
    graph.add_conditional_edges("human_review", route_after_review)
    graph.add_edge("execute", END)
    graph.add_edge("reject", END)

    return graph.compile(checkpointer=checkpointer or MemorySaver())


class ReviewNotPendingError(RuntimeError):
    pass


class FourEyesViolationError(PermissionError):
    """Quien solicita una asesoría no puede ser quien la aprueba."""


class AdvisoryService:
    """Facade over the compiled graph: start an advisory run, review it, inspect it.

    Also keeps health counters (fallback, guardrail blocks, human overrides) and emits a
    structured JSON log line per run — the signals LLMOps recommends monitoring in production.
    """

    def __init__(
        self,
        strategy: RiskEvaluationStrategy,
        retriever: Retriever | None = None,
        executor: OrderExecutor | None = None,
        checkpointer: Any | None = None,
    ) -> None:
        self.strategy = strategy
        self.executor = executor or DryRunExecutor()
        self.graph = build_advisory_graph(
            strategy, retriever or Retriever.from_knowledge_base(), self.executor, checkpointer
        )
        self.counters: Counter[str] = Counter()

    def start(self, profile: PortfolioProfile, initiator: str = "anonymous") -> dict[str, Any]:
        thread_id = f"adv_{uuid.uuid4().hex[:16]}"
        self.graph.invoke(
            {"profile": profile.model_dump(mode="json"), "trace": [], "initiator": initiator},
            {"configurable": {"thread_id": thread_id}},
        )
        result = self.get(thread_id)
        self._record_run(result)
        return result

    def review(
        self, thread_id: str, approved: bool, reviewer: str, comment: str = ""
    ) -> dict[str, Any]:
        config: RunnableConfig = {"configurable": {"thread_id": thread_id}}
        snapshot = self.graph.get_state(config)
        if not snapshot.values:
            raise KeyError(thread_id)
        if "human_review" not in snapshot.next:
            raise ReviewNotPendingError(f"advice {thread_id} is not awaiting review")
        if reviewer == snapshot.values.get("initiator"):
            raise FourEyesViolationError("the initiator of an advice cannot approve it")

        self.graph.invoke(
            Command(resume={"approved": approved, "reviewer": reviewer, "comment": comment}), config
        )
        self.counters["reviews_approved" if approved else "reviews_rejected"] += 1
        result = self.get(thread_id)
        self._log_event("advice_reviewed", result)
        return result

    def get(self, thread_id: str) -> dict[str, Any]:
        snapshot = self.graph.get_state({"configurable": {"thread_id": thread_id}})
        if not snapshot.values:
            raise KeyError(thread_id)
        values = snapshot.values
        status = (
            "PENDING_REVIEW" if "human_review" in snapshot.next else values.get("status", "RUNNING")
        )
        assessment = values.get("assessment") or {}
        return {
            "thread_id": thread_id,
            "status": status,
            "assessment": values.get("assessment"),
            "proposals": values.get("proposals", []),
            "guardrails": values.get("guardrails"),
            "retrieved_sources": [
                {"chunk_id": r["chunk_id"], "title": r["title"], "score": r["score"]}
                for r in values.get("retrieved", [])
            ],
            "review": values.get("review"),
            "executions": values.get("executions", []),
            "trace": values.get("trace", []),
            "meta": {
                "initiator": values.get("initiator"),
                "strategy": assessment.get("strategy_used"),
                "prompt_version": assessment.get("prompt_version"),
                "degraded": assessment.get("degraded"),
                "node_latency_ms": values.get("node_latency_ms", {}),
            },
        }

    def health_metrics(self) -> dict[str, Any]:
        """Señales de salud del sistema de IA (tasas sobre el total de corridas)."""
        runs = self.counters["runs"] or 1
        reviews = (self.counters["reviews_approved"] + self.counters["reviews_rejected"]) or 1
        return {
            "counters": dict(self.counters),
            "fallback_rate": round(self.counters["degraded"] / runs, 3),
            "guardrail_block_rate": round(self.counters["status_REJECTED"] / runs, 3),
            "human_review_rate": round(self.counters["status_PENDING_REVIEW"] / runs, 3),
            "human_override_rate": round(self.counters["reviews_rejected"] / reviews, 3),
        }

    def _record_run(self, result: dict[str, Any]) -> None:
        self.counters["runs"] += 1
        self.counters[f"status_{result['status']}"] += 1
        if result["meta"]["degraded"]:
            self.counters["degraded"] += 1
        self._log_event("advice_completed", result)

    @staticmethod
    def _log_event(event: str, result: dict[str, Any]) -> None:
        # Una línea JSON por evento: parseable por CloudWatch / Datadog / Loki.
        # Sin datos personales del perfil: solo ids, métricas y decisiones.
        logger.info(
            json.dumps(
                {
                    "event": event,
                    "thread_id": result["thread_id"],
                    "status": result["status"],
                    "strategy": result["meta"]["strategy"],
                    "prompt_version": result["meta"]["prompt_version"],
                    "degraded": result["meta"]["degraded"],
                    "blocking": (result["guardrails"] or {}).get("blocking", []),
                    "review_reasons": (result["guardrails"] or {}).get("review_reasons", []),
                    "retrieved": [s["chunk_id"] for s in result["retrieved_sources"]],
                    "node_latency_ms": result["meta"]["node_latency_ms"],
                }
            )
        )
