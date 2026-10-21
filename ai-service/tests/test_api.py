"""HTTP contract of the AI service (FastAPI TestClient, no network)."""

import pytest
from fastapi.testclient import TestClient

from src.api import create_app
from src.graph import AdvisoryService
from src.llm import FakeLLMClient
from src.resilience import ResilientRiskStrategy
from src.strategy import LLMRagStrategy, RuleBasedStrategy


@pytest.fixture
def client() -> TestClient:
    svc = AdvisoryService(
        ResilientRiskStrategy(LLMRagStrategy(FakeLLMClient()), RuleBasedStrategy())
    )
    return TestClient(create_app(svc))


def test_health_reports_breaker_state(client):
    body = client.get("/health").json()
    assert body["status"] == "UP"
    assert body["circuit_breaker"] == "CLOSED"


def test_advice_review_flow(client, balanced_profile):
    created = client.post("/v1/advice", json=balanced_profile.model_dump(mode="json"))
    assert created.status_code == 201
    thread_id = created.json()["thread_id"]
    assert created.json()["status"] == "PENDING_REVIEW"

    assert client.get(f"/v1/advice/{thread_id}").json()["status"] == "PENDING_REVIEW"

    reviewed = client.post(
        f"/v1/advice/{thread_id}/review", json={"approved": True, "reviewer": "adv-1"}
    )
    assert reviewed.status_code == 200
    assert reviewed.json()["status"] == "EXECUTED"

    again = client.post(
        f"/v1/advice/{thread_id}/review", json={"approved": True, "reviewer": "adv-1"}
    )
    assert again.status_code == 409


def test_validation_errors_return_422(client):
    resp = client.post(
        "/v1/advice", json={"user_id": "u", "portfolio_id": "p", "total_aum": -1, "cash_balance": 0}
    )
    assert resp.status_code == 422


def test_unknown_advice_returns_404(client):
    assert client.get("/v1/advice/adv_nope").status_code == 404
    assert (
        client.post(
            "/v1/advice/adv_nope/review", json={"approved": True, "reviewer": "x"}
        ).status_code
        == 404
    )
