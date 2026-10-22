"""
FastAPI service ("Router IA" in the architecture diagram).

    POST /v1/advice                       -> run the advisory graph (rate limited per client)
    GET  /v1/advice/{thread_id}           -> current state of a run (+ observability meta)
    POST /v1/advice/{thread_id}/review    -> authenticated human approval / rejection
    GET  /metrics                         -> AI health signals (fallback, block, override rates)
    GET  /health                          -> liveness + circuit breaker state

Security controls (Developer's Playbook for LLM Security, ch. 4 and 7):
- Reviewers authenticate with a bearer token; the reviewer identity comes from the token,
  never from the request body.
- Four-eyes: the client that requested an advice cannot approve it.
- Per-client rate limiting on the expensive LLM endpoint.

Run locally (loopback only):
    REVIEWER_TOKENS="dev-token-alice=alice" uv run uvicorn src.api:app --host 127.0.0.1 --port 8000
OpenAPI docs: http://127.0.0.1:8000/docs
"""

import hmac
import os
import threading
import time
from collections import defaultdict, deque
from typing import Annotated, Any

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel

from src.graph import (
    AdvisoryService,
    FourEyesViolationError,
    PortfolioApiExecutor,
    ReviewNotPendingError,
)
from src.llm import llm_from_env
from src.resilience import CircuitBreaker, ResilientRiskStrategy
from src.strategy import LLMRagStrategy, PortfolioProfile, RuleBasedStrategy


class ReviewRequest(BaseModel):
    approved: bool
    comment: str = ""


class SlidingWindowRateLimiter:
    """Límite de N peticiones por ventana deslizante, por cliente (memoria de un solo nodo;
    con varias réplicas se movería a Redis o al API Gateway)."""

    def __init__(self, max_requests: int, window_s: float) -> None:
        self._max = max_requests
        self._window = window_s
        self._hits: dict[str, deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def check(self, client_id: str) -> float | None:
        """Retorna None si se permite, o los segundos a esperar si se excedió el límite."""
        now = time.monotonic()
        with self._lock:
            hits = self._hits[client_id]
            while hits and now - hits[0] >= self._window:
                hits.popleft()
            if len(hits) >= self._max:
                return self._window - (now - hits[0])
            hits.append(now)
            return None


def parse_reviewer_tokens(raw: str | None) -> dict[str, str]:
    """ "token1=alice,token2=bob" -> {"token1": "alice", "token2": "bob"}"""
    pairs = (item.split("=", 1) for item in (raw or "").split(",") if "=" in item)
    return {token.strip(): name.strip() for token, name in pairs if token.strip()}


def build_default_service() -> AdvisoryService:
    strategy = ResilientRiskStrategy(
        primary=LLMRagStrategy(llm_from_env()),
        fallback=RuleBasedStrategy(),
        breaker=CircuitBreaker(failure_threshold=3, reset_timeout_s=30),
    )
    portfolio_api = os.getenv("PORTFOLIO_API_URL")  # p. ej. http://127.0.0.1:8080
    executor = PortfolioApiExecutor(portfolio_api) if portfolio_api else None
    return AdvisoryService(strategy, executor=executor)


def create_app(
    service: AdvisoryService | None = None,
    reviewer_tokens: dict[str, str] | None = None,
    rate_limiter: SlidingWindowRateLimiter | None = None,
) -> FastAPI:
    svc = service or build_default_service()
    tokens = (
        reviewer_tokens
        if reviewer_tokens is not None
        else parse_reviewer_tokens(os.getenv("REVIEWER_TOKENS"))
    )
    limiter = rate_limiter or SlidingWindowRateLimiter(max_requests=30, window_s=60)

    app = FastAPI(
        title="Fin-AI Advisor — AI Service",
        version="0.3.0",
        description="RAG + LangGraph portfolio advisory with guardrails and human-in-the-loop.",
    )

    def client_id(x_client_id: Annotated[str, Header()] = "anonymous") -> str:
        # En producción la identidad vendría del API Gateway / JWT (claim `sub`)
        return x_client_id

    def authenticated_reviewer(authorization: Annotated[str | None, Header()] = None) -> str:
        scheme, _, token = (authorization or "").partition(" ")
        if scheme.lower() == "bearer" and token:
            for known, reviewer in tokens.items():
                if hmac.compare_digest(token, known):  # Comparación en tiempo constante
                    return reviewer
        raise HTTPException(
            status_code=401,
            detail="reviewer authentication required",
            headers={"WWW-Authenticate": "Bearer"},
        )

    @app.get("/health")
    def health() -> dict[str, Any]:
        breaker = getattr(svc.strategy, "breaker", None)
        return {
            "status": "UP",
            "strategy": svc.strategy.strategy_name,
            "circuit_breaker": breaker.state.value if breaker else "N/A",
        }

    @app.get("/metrics")
    def metrics() -> dict[str, Any]:
        return svc.health_metrics()

    @app.post("/v1/advice", status_code=201)
    def create_advice(
        profile: PortfolioProfile, client: Annotated[str, Depends(client_id)]
    ) -> dict[str, Any]:
        retry_after = limiter.check(client)
        if retry_after is not None:
            raise HTTPException(
                status_code=429,
                detail="rate limit exceeded",
                headers={"Retry-After": str(max(1, round(retry_after)))},
            )
        return svc.start(profile, initiator=client)

    @app.get("/v1/advice/{thread_id}")
    def get_advice(thread_id: str) -> dict[str, Any]:
        try:
            return svc.get(thread_id)
        except KeyError:
            raise HTTPException(status_code=404, detail="advice not found") from None

    @app.post("/v1/advice/{thread_id}/review")
    def review_advice(
        thread_id: str,
        body: ReviewRequest,
        reviewer: Annotated[str, Depends(authenticated_reviewer)],
    ) -> dict[str, Any]:
        try:
            return svc.review(thread_id, body.approved, reviewer, body.comment)
        except KeyError:
            raise HTTPException(status_code=404, detail="advice not found") from None
        except FourEyesViolationError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from None
        except ReviewNotPendingError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from None

    return app


app = create_app()
