"""Unit tests for Strategy Pattern implementation in ai-service."""

import pytest
from pydantic import ValidationError

from src.strategy import (
    AdvisorContext,
    AssetClass,
    FineTunedModelStrategy,
    Holding,
    LangChainOpenAIStrategy,
    PortfolioProfile,
    RiskTolerance,
)


@pytest.fixture
def sample_profile() -> PortfolioProfile:
    return PortfolioProfile(
        user_id="usr-101",
        portfolio_id="port-001",
        total_aum=100000.0,
        cash_balance=15000.0,
        risk_tolerance=RiskTolerance.GROWTH,
        investment_horizon_years=10,
        holdings=[
            Holding(symbol="VOO", quantity=100, current_price=450.0, asset_class=AssetClass.EQUITY),
            Holding(
                symbol="BND", quantity=200, current_price=75.0, asset_class=AssetClass.FIXED_INCOME
            ),
            Holding(
                symbol="AAPL", quantity=100, current_price=180.0, asset_class=AssetClass.EQUITY
            ),
        ],
    )


def test_langchain_openai_strategy(sample_profile: PortfolioProfile):
    strategy = LangChainOpenAIStrategy()
    result = strategy.evaluate(sample_profile)

    assert result.strategy_used == "LangChain-RAG-OpenAI"
    assert 0.0 <= result.risk_score <= 1.0
    assert result.risk_level == "GROWTH"
    assert result.confidence > 0.8
    assert "EQUITY" in result.recommended_allocation
    assert sum(result.recommended_allocation.values()) == pytest.approx(1.0, 0.01)
    assert len(result.rationale) > 20


def test_fine_tuned_model_strategy(sample_profile: PortfolioProfile):
    strategy = FineTunedModelStrategy()
    result = strategy.evaluate(sample_profile)

    assert result.strategy_used == "FineTuned-SLM-QuantModel"
    assert 0.0 <= result.risk_score <= 1.0
    assert result.estimated_var_95 > 0.0
    assert result.execution_time_ms < 100.0
    assert sum(result.recommended_allocation.values()) == pytest.approx(1.0, 0.05)


def test_advisor_context_runtime_switch(sample_profile: PortfolioProfile):
    rag_strat = LangChainOpenAIStrategy()
    slm_strat = FineTunedModelStrategy()

    context = AdvisorContext(rag_strat)
    assert context.current_strategy.strategy_name == "LangChain-RAG-OpenAI"

    res1 = context.evaluate_risk(sample_profile)
    assert res1.strategy_used == "LangChain-RAG-OpenAI"

    # Runtime strategy switch (Strategy Pattern)
    context.set_strategy(slm_strat)
    assert context.current_strategy.strategy_name == "FineTuned-SLM-QuantModel"

    res2 = context.evaluate_risk(sample_profile)
    assert res2.strategy_used == "FineTuned-SLM-QuantModel"

    # Telemetry inspection
    history = context.get_telemetry_history()
    assert len(history) == 2
    assert history[0]["strategy"] == "LangChain-RAG-OpenAI"
    assert history[1]["strategy"] == "FineTuned-SLM-QuantModel"


def test_holding_validation():
    with pytest.raises(ValidationError):
        Holding(symbol="INVALID", quantity=-5, current_price=100.0)

    with pytest.raises(ValidationError):
        Holding(symbol="INVALID", quantity=10, current_price=0.0)
