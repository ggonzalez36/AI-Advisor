"""HTTP contract of the AI service (FastAPI TestClient, no network)."""

import pytest
from fastapi.testclient import TestClient

from src.api import SlidingWindowRateLimiter, create_app, parse_reviewer_tokens
from src.graph import AdvisoryService
from src.llm import FakeLLMClient
from src.resilience import ResilientRiskStrategy
from src.strategy import LLMRagStrategy, RuleBasedStrategy

ALICE = {"Authorization": "Bearer token-alice"}


def make_client(limiter=None) -> TestClient:
    svc = AdvisoryService(
        ResilientRiskStrategy(LLMRagStrategy(FakeLLMClient()), RuleBasedStrategy())
    )
    app = create_app(svc, reviewer_tokens={"token-alice": "alice"}, rate_limiter=limiter)
    return TestClient(app)


@pytest.fixture
def client() -> TestClient:
    return make_client()


def start_advice(client, profile, client_id="advisor-app"):
    resp = client.post(
        "/v1/advice", json=profile.model_dump(mode="json"), headers={"X-Client-Id": client_id}
    )
    assert resp.status_code == 201
    return resp.json()


def test_health_reports_breaker_state(client):
    body = client.get("/health").json()
    assert body["status"] == "UP"
    assert body["circuit_breaker"] == "CLOSED"


def test_advice_review_flow(client, balanced_profile):
    created = start_advice(client, balanced_profile)
    thread_id = created["thread_id"]
    assert created["status"] == "PENDING_REVIEW"
    assert created["meta"]["initiator"] == "advisor-app"
    assert created["meta"]["prompt_version"]
    assert set(created["meta"]["node_latency_ms"]) >= {"retrieve", "assess", "guardrails"}

    assert client.get(f"/v1/advice/{thread_id}").json()["status"] == "PENDING_REVIEW"

    reviewed = client.post(f"/v1/advice/{thread_id}/review", json={"approved": True}, headers=ALICE)
    assert reviewed.status_code == 200
    assert reviewed.json()["status"] == "EXECUTED"
    assert reviewed.json()["review"]["reviewer"] == "alice"  # Identidad del token, no del body

    again = client.post(f"/v1/advice/{thread_id}/review", json={"approved": True}, headers=ALICE)
    assert again.status_code == 409


def test_review_requires_valid_token(client, balanced_profile):
    thread_id = start_advice(client, balanced_profile)["thread_id"]
    url = f"/v1/advice/{thread_id}/review"

    assert client.post(url, json={"approved": True}).status_code == 401
    bad = client.post(url, json={"approved": True}, headers={"Authorization": "Bearer nope"})
    assert bad.status_code == 401


def test_four_eyes_initiator_cannot_approve(client, balanced_profile):
    thread_id = start_advice(client, balanced_profile, client_id="alice")["thread_id"]
    resp = client.post(f"/v1/advice/{thread_id}/review", json={"approved": True}, headers=ALICE)
    assert resp.status_code == 403


def test_rate_limit_returns_429_with_retry_after(balanced_profile):
    client = make_client(SlidingWindowRateLimiter(max_requests=2, window_s=60))
    for _ in range(2):
        start_advice(client, balanced_profile, client_id="noisy")

    resp = client.post(
        "/v1/advice",
        json=balanced_profile.model_dump(mode="json"),
        headers={"X-Client-Id": "noisy"},
    )
    assert resp.status_code == 429
    assert int(resp.headers["Retry-After"]) > 0
    # Otro cliente no se ve afectado
    start_advice(client, balanced_profile, client_id="other")


def test_metrics_report_health_signals(client, balanced_profile, conservative_profile):
    thread_id = start_advice(client, balanced_profile)["thread_id"]
    start_advice(client, conservative_profile)
    client.post(f"/v1/advice/{thread_id}/review", json={"approved": False}, headers=ALICE)

    body = client.get("/metrics").json()
    assert body["counters"]["runs"] == 2
    assert body["human_review_rate"] == 0.5
    assert body["human_override_rate"] == 1.0
    assert body["fallback_rate"] == 0.0


def test_validation_errors_return_422(client):
    resp = client.post(
        "/v1/advice", json={"user_id": "u", "portfolio_id": "p", "total_aum": -1, "cash_balance": 0}
    )
    assert resp.status_code == 422


def test_unknown_advice_returns_404(client):
    assert client.get("/v1/advice/adv_nope").status_code == 404
    resp = client.post("/v1/advice/adv_nope/review", json={"approved": True}, headers=ALICE)
    assert resp.status_code == 404


def test_parse_reviewer_tokens():
    assert parse_reviewer_tokens("t1=alice, t2=bob,broken") == {"t1": "alice", "t2": "bob"}
    assert parse_reviewer_tokens(None) == {}
