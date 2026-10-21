"""
FastAPI service ("Router IA" in the architecture diagram).

    POST /v1/advice                       -> run the advisory graph for a portfolio
    GET  /v1/advice/{thread_id}           -> current state of a run
    POST /v1/advice/{thread_id}/review    -> human approval / rejection (resumes the graph)
    GET  /health                          -> liveness + circuit breaker state

Run locally (loopback only):  uv run uvicorn src.api:app --host 127.0.0.1 --port 8000
OpenAPI docs: http://127.0.0.1:8000/docs
"""

from __future__ import annotations

import os
from typing import Any

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

from src.graph import AdvisoryService, PortfolioApiExecutor, ReviewNotPendingError
from src.llm import llm_from_env
from src.resilience import CircuitBreaker, ResilientRiskStrategy
from src.strategy import LLMRagStrategy, PortfolioProfile, RuleBasedStrategy


class ReviewRequest(BaseModel):
    approved: bool
    reviewer: str = Field(min_length=1, description="Licensed advisor identifier")
    comment: str = ""


def build_default_service() -> AdvisoryService:
    strategy = ResilientRiskStrategy(
        primary=LLMRagStrategy(llm_from_env()),
        fallback=RuleBasedStrategy(),
        breaker=CircuitBreaker(failure_threshold=3, reset_timeout_s=30),
    )
    portfolio_api = os.getenv("PORTFOLIO_API_URL")  # p. ej. http://127.0.0.1:8080
    executor = PortfolioApiExecutor(portfolio_api) if portfolio_api else None
    return AdvisoryService(strategy, executor=executor)


def create_app(service: AdvisoryService | None = None) -> FastAPI:
    svc = service or build_default_service()
    app = FastAPI(
        title="Fin-AI Advisor — AI Service",
        version="0.2.0",
        description="RAG + LangGraph portfolio advisory with guardrails and human-in-the-loop.",
    )

    @app.get("/health")
    def health() -> dict[str, Any]:
        breaker = getattr(svc.strategy, "breaker", None)
        return {
            "status": "UP",
            "strategy": svc.strategy.strategy_name,
            "circuit_breaker": breaker.state.value if breaker else "N/A",
        }

    @app.post("/v1/advice", status_code=201)
    def create_advice(profile: PortfolioProfile) -> dict[str, Any]:
        return svc.start(profile)

    @app.get("/v1/advice/{thread_id}")
    def get_advice(thread_id: str) -> dict[str, Any]:
        try:
            return svc.get(thread_id)
        except KeyError:
            raise HTTPException(status_code=404, detail="advice not found") from None

    @app.post("/v1/advice/{thread_id}/review")
    def review_advice(thread_id: str, body: ReviewRequest) -> dict[str, Any]:
        try:
            return svc.review(thread_id, body.approved, body.reviewer, body.comment)
        except KeyError:
            raise HTTPException(status_code=404, detail="advice not found") from None
        except ReviewNotPendingError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from None

    return app


app = create_app()
