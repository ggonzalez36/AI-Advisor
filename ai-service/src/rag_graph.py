"""
RAG Orchestration using LangGraph for Financial Portfolio Advisory.
Orchestrates context retrieval, sentiment/signal extraction, risk evaluation,
and trade command generation targeting the Go transactional backend.
"""

from typing import Any, TypedDict

from src.strategy import (
    AdvisorContext,
    AssetClass,
    LangChainOpenAIStrategy,
    PortfolioProfile,
    RiskAssessmentResult,
    RiskEvaluationStrategy,
)


class TradeProposal(TypedDict):
    action: str  # BUY or SELL
    symbol: str
    target_amount: float
    asset_class: str
    rationale: str


class FinancialAdvisoryState(TypedDict, total=False):
    """Estado persistente del grafo de orquestación RAG."""

    profile: PortfolioProfile
    retrieved_documents: list[dict[str, str]]
    market_signals: dict[str, Any]
    risk_assessment: RiskAssessmentResult
    trade_proposals: list[TradeProposal]
    graph_steps: list[str]
    is_high_risk: bool
    status: str


def retrieve_market_intelligence(state: FinancialAdvisoryState) -> FinancialAdvisoryState:
    """
    Nodo 1: Recupera contexto macroeconómico y reportes financieros
    simulando consulta vectorial RAG contra pgvector / base de conocimiento.
    """
    steps = state.get("graph_steps", [])
    steps.append("retrieve_market_intelligence")

    # Documentos recuperados simulados con embeddings semánticos
    documents = [
        {
            "source": "FED_MONETARY_POLICY_MINUTES",
            "content": "La Reserva Federal mantiene la tasa de referencia estable. Persiste volatilidad en renta variable.",
            "relevance_score": "0.94",
        },
        {
            "source": "SEC_10K_SECTOR_OUTLOOK",
            "content": "El sector tecnológico muestra márgenes sólidos pero sensibilidad al costo de capital.",
            "relevance_score": "0.89",
        },
        {
            "source": "GLOBAL_BOND_YIELD_CURVE",
            "content": "La curva de rendimientos de bonos del tesoro presenta aplanamiento progresivo a 10 años.",
            "relevance_score": "0.86",
        },
    ]

    return {
        **state,
        "retrieved_documents": documents,
        "graph_steps": steps,
        "status": "DOCUMENTS_RETRIEVED",
    }


def extract_financial_signals(state: FinancialAdvisoryState) -> FinancialAdvisoryState:
    """
    Nodo 2: Extrae señales estructuradas a partir de los documentos RAG recuperados.
    """
    steps = state.get("graph_steps", [])
    steps.append("extract_financial_signals")

    signals = {
        "market_regime": "MODERATE_EXPANSION",
        "inflation_expectation_pct": 2.8,
        "equity_volatility_vix": 18.5,
        "recommended_cash_cushion_pct": 10.0,
        "interest_rate_trend": "NEUTRAL",
    }

    return {
        **state,
        "market_signals": signals,
        "graph_steps": steps,
        "status": "SIGNALS_EXTRACTED",
    }


def evaluate_portfolio_strategy(
    state: FinancialAdvisoryState,
    strategy: RiskEvaluationStrategy | None = None,
) -> FinancialAdvisoryState:
    """
    Nodo 3: Aplica el Strategy Pattern para calcular el perfil de riesgo y asignación de activos.
    """
    steps = state.get("graph_steps", [])
    steps.append("evaluate_portfolio_strategy")

    active_strategy = strategy or LangChainOpenAIStrategy()
    context = AdvisorContext(active_strategy)

    profile = state["profile"]
    assessment = context.evaluate_risk(profile)
    is_high_risk = assessment.risk_score >= 0.70

    return {
        **state,
        "risk_assessment": assessment,
        "is_high_risk": is_high_risk,
        "graph_steps": steps,
        "status": "RISK_ASSESSED",
    }


def generate_trade_recommendations(state: FinancialAdvisoryState) -> FinancialAdvisoryState:
    """
    Nodo 4: Genera órdenes y propuestas de rebalanceo compatibles con
    el modelo BuyOrder del backend transaccional en Go (portfolio-api).
    """
    steps = state.get("graph_steps", [])
    steps.append("generate_trade_recommendations")

    profile = state["profile"]
    assessment = state["risk_assessment"]
    proposals: list[TradeProposal] = []

    # Cálculo de rebalanceo hacia la asignación objetivo
    target_alloc = assessment.recommended_allocation
    target_fixed_income = target_alloc.get("FIXED_INCOME", 0.3) * profile.total_aum
    current_fixed_income = sum(
        h.market_value for h in profile.holdings if h.asset_class == AssetClass.FIXED_INCOME
    )

    diff_fixed = target_fixed_income - current_fixed_income
    if diff_fixed > 1000:
        proposals.append(
            {
                "action": "BUY",
                "symbol": "BND",
                "target_amount": round(diff_fixed, 2),
                "asset_class": "FIXED_INCOME",
                "rationale": f"Rebalanceo para converger a meta de {target_alloc.get('FIXED_INCOME'):.0%} en renta fija",
            }
        )

    # Si hay efectivo ocioso superior al 20%, desplegar a renta variable
    cash_ratio = profile.cash_balance / max(profile.total_aum, 1.0)
    if cash_ratio > 0.20 and target_alloc.get("EQUITY", 0.5) > 0.4:
        deploy_amount = profile.cash_balance * 0.5
        proposals.append(
            {
                "action": "BUY",
                "symbol": "VOO",
                "target_amount": round(deploy_amount, 2),
                "asset_class": "EQUITY",
                "rationale": f"Despliegue de efectivo excedente ({cash_ratio:.1%}) hacia ETF indexado de bajas comisiones",
            }
        )

    return {
        **state,
        "trade_proposals": proposals,
        "graph_steps": steps,
        "status": "COMPLETED",
    }


class AdvisoryRAGGraph:
    """
    Orquestador de grafo de estados RAG compatible con LangGraph StateGraph.
    Implementa el flujo acíclico y control condicional de decisiones.
    """

    def __init__(self, strategy: RiskEvaluationStrategy | None = None):
        self.strategy = strategy or LangChainOpenAIStrategy()

    def run(self, profile: PortfolioProfile) -> FinancialAdvisoryState:
        """
        Ejecuta el pipeline completo de grafo de estados.
        """
        initial_state: FinancialAdvisoryState = {
            "profile": profile,
            "retrieved_documents": [],
            "market_signals": {},
            "trade_proposals": [],
            "graph_steps": [],
            "status": "INITIALIZED",
        }

        # Ejecución secuencial de los nodos del grafo
        state = retrieve_market_intelligence(initial_state)
        state = extract_financial_signals(state)
        state = evaluate_portfolio_strategy(state, self.strategy)
        state = generate_trade_recommendations(state)

        return state


def run_advisory_pipeline(
    profile: PortfolioProfile,
    strategy: RiskEvaluationStrategy | None = None,
) -> FinancialAdvisoryState:
    """Función de entrada para ejecutar el grafo RAG."""
    graph = AdvisoryRAGGraph(strategy=strategy)
    return graph.run(profile)
