"""Unit tests for LangGraph RAG workflow in ai-service."""

from src.rag_graph import AdvisoryRAGGraph, run_advisory_pipeline
from src.strategy import (
    AssetClass,
    FineTunedModelStrategy,
    Holding,
    PortfolioProfile,
    RiskTolerance,
)


def test_rag_graph_execution():
    profile = PortfolioProfile(
        user_id="usr-501",
        portfolio_id="port-rag-01",
        total_aum=250000.0,
        cash_balance=60000.0,  # 24% cash, should trigger cash deployment proposal
        risk_tolerance=RiskTolerance.BALANCED,
        investment_horizon_years=7,
        holdings=[
            Holding(symbol="VOO", quantity=200, current_price=450.0, asset_class=AssetClass.EQUITY),
            Holding(
                symbol="BND", quantity=500, current_price=75.0, asset_class=AssetClass.FIXED_INCOME
            ),
        ],
    )

    result_state = run_advisory_pipeline(profile)

    assert result_state["status"] == "COMPLETED"
    assert len(result_state["retrieved_documents"]) >= 3
    assert "market_regime" in result_state["market_signals"]
    assert result_state["risk_assessment"] is not None
    assert "graph_steps" in result_state
    assert len(result_state["graph_steps"]) == 4

    # Verify trade proposals were generated
    proposals = result_state["trade_proposals"]
    assert len(proposals) > 0
    symbols = [p["symbol"] for p in proposals]
    assert "VOO" in symbols or "BND" in symbols


def test_rag_graph_with_slm_strategy():
    profile = PortfolioProfile(
        user_id="usr-502",
        portfolio_id="port-rag-02",
        total_aum=50000.0,
        cash_balance=5000.0,
        risk_tolerance=RiskTolerance.CONSERVATIVE,
        investment_horizon_years=3,
        holdings=[
            Holding(
                symbol="VTIP", quantity=500, current_price=50.0, asset_class=AssetClass.FIXED_INCOME
            ),
        ],
    )

    graph = AdvisoryRAGGraph(strategy=FineTunedModelStrategy())
    result_state = graph.run(profile)

    assert result_state["status"] == "COMPLETED"
    assert result_state["risk_assessment"].strategy_used == "FineTuned-SLM-QuantModel"
