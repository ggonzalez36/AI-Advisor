"""Guardrails: blocking violations vs. human-review triggers."""

from src.guardrails import evaluate_guardrails
from src.rebalancing import TradeProposal, propose_trades
from src.strategy import RuleBasedStrategy

RETRIEVED = ["investment_policy#strategic-allocation-bands-by-risk-tolerance"]


def assessment_for(profile, **overrides):
    base = RuleBasedStrategy().evaluate(profile)
    return base.model_copy(update={"citations": RETRIEVED, **overrides})


def test_clean_recommendation_passes(conservative_profile):
    a = assessment_for(conservative_profile)
    report = evaluate_guardrails(
        conservative_profile, a, propose_trades(conservative_profile, a), RETRIEVED
    )
    assert report.passed and not report.review_reasons


def test_hallucinated_citation_is_blocked(conservative_profile):
    a = assessment_for(conservative_profile, citations=["made_up_doc#secret"])
    report = evaluate_guardrails(conservative_profile, a, [], RETRIEVED)
    assert not report.passed
    assert "hallucinated" in report.blocking[0]


def test_crypto_for_conservative_is_blocked(conservative_profile):
    a = assessment_for(
        conservative_profile,
        recommended_allocation={
            "EQUITY": 0.2,
            "FIXED_INCOME": 0.55,
            "CASH_EQUIVALENT": 0.2,
            "CRYPTO": 0.05,
        },
    )
    report = evaluate_guardrails(conservative_profile, a, [], RETRIEVED)
    assert any("unsuitable" in b for b in report.blocking)


def test_allocation_must_sum_to_one(conservative_profile):
    a = assessment_for(
        conservative_profile, recommended_allocation={"EQUITY": 0.5, "FIXED_INCOME": 0.2}
    )
    report = evaluate_guardrails(conservative_profile, a, [], RETRIEVED)
    assert any("sums to" in b for b in report.blocking)


def test_unfunded_trades_are_blocked(conservative_profile):
    a = assessment_for(conservative_profile)
    huge = TradeProposal(
        symbol="VOO",
        asset_class="EQUITY",
        quantity=1000,
        limit_price="450.00",
        notional=450_000,
        rationale="x",
    )
    report = evaluate_guardrails(conservative_profile, a, [huge], RETRIEVED)
    assert any("available" in b for b in report.blocking)


def test_high_risk_and_degraded_require_review(concentrated_profile):
    a = assessment_for(concentrated_profile, risk_score=0.9, degraded=True)
    report = evaluate_guardrails(concentrated_profile, a, [], RETRIEVED)
    assert report.passed
    joined = " | ".join(report.review_reasons)
    assert "risk score" in joined and "degraded" in joined and "NVDA" in joined


def test_rebalancing_never_spends_more_than_cash(balanced_profile):
    a = assessment_for(balanced_profile)
    proposals = propose_trades(balanced_profile, a)
    assert proposals
    assert sum(p.notional for p in proposals) <= balanced_profile.cash_balance
    assert all(p.quantity > 0 and p.limit_price.count(".") == 1 for p in proposals)


def test_missing_policy_context_requires_review(conservative_profile):
    # Insufficient-context gate: without the investment policy the model would improvise
    others = ["macro_rates_outlook#policy-rates"]
    a = assessment_for(conservative_profile, citations=others)
    report = evaluate_guardrails(conservative_profile, a, [], others)
    assert report.passed
    assert any("insufficient context" in r for r in report.review_reasons)
