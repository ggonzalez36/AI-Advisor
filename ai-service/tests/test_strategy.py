"""Unit tests for the Strategy Pattern and the quantitative core."""

import math

import pytest
from pydantic import ValidationError

from src.llm import FakeLLMClient, LLMError
from src.retrieval import Retriever
from src.strategy import (
    AdvisorContext,
    AssetClass,
    FineTunedModelStrategy,
    Holding,
    LLMRagStrategy,
    PortfolioProfile,
    RiskTolerance,
    RuleBasedStrategy,
    compute_portfolio_metrics,
    policy_allocation,
)


def test_var_scales_with_square_root_of_time():
    profile = PortfolioProfile(
        user_id="u",
        portfolio_id="p",
        total_aum=100_000,
        cash_balance=0,
        holdings=[
            Holding(symbol="VOO", quantity=100, current_price=1000, asset_class=AssetClass.EQUITY)
        ],
    )
    metrics = compute_portfolio_metrics(profile)

    assert metrics.volatility_annual == pytest.approx(0.18)  # 100% renta variable
    assert metrics.var_95_1m == pytest.approx(1.645 * 0.18 * math.sqrt(1 / 12))


def test_diversification_lowers_volatility(balanced_profile, concentrated_profile):
    assert (
        compute_portfolio_metrics(balanced_profile).volatility_annual
        < compute_portfolio_metrics(concentrated_profile).volatility_annual
    )


def test_policy_glide_path_by_horizon(balanced_profile):
    long = balanced_profile.model_copy(update={"investment_horizon_years": 25})
    short = balanced_profile.model_copy(update={"investment_horizon_years": 2})

    assert policy_allocation(long)["EQUITY"] == pytest.approx(0.60)
    assert policy_allocation(short)["EQUITY"] == pytest.approx(0.40)
    for alloc in (policy_allocation(long), policy_allocation(short)):
        assert sum(alloc.values()) == pytest.approx(1.0)


@pytest.mark.parametrize("strategy_cls", [RuleBasedStrategy, FineTunedModelStrategy])
def test_deterministic_strategies_produce_valid_allocations(strategy_cls, concentrated_profile):
    result = strategy_cls().evaluate(concentrated_profile)

    assert 0.0 <= result.risk_score <= 1.0
    assert result.risk_level == "AGGRESSIVE"
    assert sum(result.recommended_allocation.values()) == pytest.approx(1.0, abs=0.01)
    assert result.estimated_var_95 > 0


def test_llm_rag_strategy_cites_retrieved_documents(balanced_profile):
    retriever = Retriever.from_knowledge_base()
    chunks = retriever.search("balanced risk tolerance allocation bands suitability")
    result = LLMRagStrategy(FakeLLMClient()).evaluate(balanced_profile, chunks)

    assert result.strategy_used == "LLM-RAG[fake-llm]"
    assert result.citations
    assert set(result.citations) <= {c.chunk_id for c in chunks}
    # El VaR proviene del núcleo cuantitativo, no del modelo
    assert result.estimated_var_95 == round(
        compute_portfolio_metrics(balanced_profile).var_95_1m, 4
    )


def test_llm_rag_strategy_propagates_invalid_output(balanced_profile):
    broken = FakeLLMClient(responder=lambda _ctx: {"risk_level": "BALANCED", "risk_score": 7})
    with pytest.raises(LLMError, match="invalid structured output"):
        LLMRagStrategy(broken).evaluate(balanced_profile, [])


def test_advisor_context_runtime_switch(balanced_profile):
    context = AdvisorContext(RuleBasedStrategy())
    context.evaluate_risk(balanced_profile)

    context.set_strategy(FineTunedModelStrategy())
    context.evaluate_risk(balanced_profile)

    history = context.get_telemetry_history()
    assert [h["strategy"] for h in history] == ["RuleBased-Policy", "FineTuned-SLM-QuantModel"]


def test_holding_validation():
    with pytest.raises(ValidationError):
        Holding(symbol="INVALID", quantity=-5, current_price=100.0)
    with pytest.raises(ValidationError):
        Holding(symbol="INVALID", quantity=10, current_price=0.0)


def test_profile_rejects_unknown_tolerance():
    with pytest.raises(ValidationError):
        PortfolioProfile(
            user_id="u", portfolio_id="p", total_aum=1, cash_balance=1, risk_tolerance="YOLO"
        )
    assert RiskTolerance("GROWTH") is RiskTolerance.GROWTH


def test_broad_index_etfs_do_not_count_as_concentration():
    # Regresión: VTI al 80% se trataba como una sola acción y disparaba riesgo 1.0
    profile = PortfolioProfile(
        user_id="u",
        portfolio_id="p",
        total_aum=100_000,
        cash_balance=10_000,
        holdings=[
            Holding(symbol="VTI", quantity=300, current_price=280, asset_class=AssetClass.EQUITY),
            Holding(symbol="NVDA", quantity=40, current_price=125, asset_class=AssetClass.EQUITY),
        ],
    )
    metrics = compute_portfolio_metrics(profile)
    assert metrics.max_position_weight == pytest.approx(5_000 / 99_000)
