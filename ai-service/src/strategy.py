"""
Strategy Pattern implementation for Portfolio Risk Evaluation.
Complies with ADR 002 and Refactoring.Guru guidelines:
https://refactoring.guru/design-patterns/strategy

All strategies share a deterministic quantitative core (`compute_portfolio_metrics`)
so that numbers such as VaR never come from an LLM: the model reasons and explains,
the math is computed.
"""

from __future__ import annotations

import math
import time
from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import UTC, datetime
from enum import StrEnum
from typing import Any

from pydantic import BaseModel, Field

from src.llm import LLMClient
from src.retrieval import RetrievedChunk


class RiskTolerance(StrEnum):
    CONSERVATIVE = "CONSERVATIVE"
    BALANCED = "BALANCED"
    GROWTH = "GROWTH"
    AGGRESSIVE = "AGGRESSIVE"


class AssetClass(StrEnum):
    EQUITY = "EQUITY"
    FIXED_INCOME = "FIXED_INCOME"
    COMMODITY = "COMMODITY"
    CASH_EQUIVALENT = "CASH_EQUIVALENT"
    CRYPTO = "CRYPTO"


class Holding(BaseModel):
    symbol: str
    quantity: float = Field(gt=0, description="Cantidad de activos mantenidos")
    current_price: float = Field(gt=0, description="Precio de mercado actual")
    asset_class: AssetClass = AssetClass.EQUITY

    @property
    def market_value(self) -> float:
        return self.quantity * self.current_price


class PortfolioProfile(BaseModel):
    user_id: str
    portfolio_id: str
    total_aum: float = Field(ge=0, description="Activos bajo gestión (AUM)")
    cash_balance: float = Field(ge=0, description="Saldo líquido disponible")
    risk_tolerance: RiskTolerance = RiskTolerance.BALANCED
    investment_horizon_years: int = Field(default=5, ge=1, le=50)
    holdings: list[Holding] = Field(default_factory=list)
    macro_constraints: dict[str, Any] = Field(default_factory=dict)


class RiskAssessmentResult(BaseModel):
    risk_score: float = Field(
        ge=0.0, le=1.0, description="Puntaje de riesgo normalizado (0.0 a 1.0)"
    )
    risk_level: str
    recommended_allocation: dict[str, float] = Field(
        description="Porcentaje asignado por clase de activo (suma ~ 1.0)"
    )
    rationale: str
    strategy_used: str
    estimated_var_95: float = Field(description="Value at Risk paramétrico al 95% a 1 mes")
    volatility_annual: float
    citations: list[str] = Field(default_factory=list, description="IDs de chunks RAG citados")
    degraded: bool = Field(default=False, description="True si se usó el camino de fallback")
    execution_time_ms: float
    timestamp: datetime = Field(default_factory=lambda: datetime.now(UTC))


# --- Quantitative core -------------------------------------------------------------

# Supuestos de mercado anuales (simplificados) por clase de activo
ANNUAL_VOLATILITY: dict[AssetClass, float] = {
    AssetClass.EQUITY: 0.18,
    AssetClass.FIXED_INCOME: 0.06,
    AssetClass.COMMODITY: 0.15,
    AssetClass.CASH_EQUIVALENT: 0.005,
    AssetClass.CRYPTO: 0.65,
}
PAIRWISE_CORRELATION = (
    0.3  # Correlación constante entre clases riesgosas (el efectivo no correlaciona)
)
Z_95 = 1.645

# Bandas de la política de inversión (src/knowledge/investment_policy.md)
POLICY_ALLOCATIONS: dict[RiskTolerance, dict[str, float]] = {
    RiskTolerance.CONSERVATIVE: {"EQUITY": 0.20, "FIXED_INCOME": 0.60, "CASH_EQUIVALENT": 0.20},
    RiskTolerance.BALANCED: {"EQUITY": 0.50, "FIXED_INCOME": 0.35, "CASH_EQUIVALENT": 0.15},
    RiskTolerance.GROWTH: {"EQUITY": 0.75, "FIXED_INCOME": 0.15, "CASH_EQUIVALENT": 0.10},
    RiskTolerance.AGGRESSIVE: {
        "EQUITY": 0.85,
        "FIXED_INCOME": 0.05,
        "CASH_EQUIVALENT": 0.05,
        "CRYPTO": 0.05,
    },
}

# ETFs indexados amplios: ya diversificados, no cuentan como concentración en un solo valor
BROAD_INDEX_ETFS = frozenset({"VOO", "VTI", "BND", "VEA", "AGG"})


@dataclass(frozen=True)
class PortfolioMetrics:
    weights: dict[str, float]  # Peso por clase de activo, incluye el efectivo
    volatility_annual: float
    var_95_1m: float  # Pérdida potencial al 95% en 1 mes, como fracción del AUM
    max_position_weight: float  # Mayor posición en un valor individual (excluye ETFs amplios)
    equity_ratio: float

    def as_dict(self) -> dict[str, Any]:
        return {
            "weights": self.weights,
            "volatility_annual": round(self.volatility_annual, 4),
            "var_95_1m": round(self.var_95_1m, 4),
            "max_position_weight": round(self.max_position_weight, 4),
            "equity_ratio": round(self.equity_ratio, 4),
        }


def compute_portfolio_metrics(profile: PortfolioProfile) -> PortfolioMetrics:
    """Volatilidad de cartera con correlación constante y VaR paramétrico (normal).

    VaR_1m = z_95 * sigma_anual * sqrt(1/12): el riesgo escala con la raíz del tiempo.
    Limitación conocida: la normal subestima colas gruesas; en producción se complementa
    con VaR histórico o Monte Carlo.
    """
    values: dict[AssetClass, float] = {}
    for h in profile.holdings:
        values[h.asset_class] = values.get(h.asset_class, 0.0) + h.market_value
    values[AssetClass.CASH_EQUIVALENT] = (
        values.get(AssetClass.CASH_EQUIVALENT, 0.0) + profile.cash_balance
    )

    total = sum(values.values()) or 1.0
    weights = {cls: v / total for cls, v in values.items()}

    variance = 0.0
    classes = list(weights)
    for i, a in enumerate(classes):
        sa = weights[a] * ANNUAL_VOLATILITY[a]
        variance += sa * sa
        for b in classes[i + 1 :]:
            if AssetClass.CASH_EQUIVALENT in (a, b):
                continue
            variance += 2 * sa * weights[b] * ANNUAL_VOLATILITY[b] * PAIRWISE_CORRELATION
    vol = math.sqrt(variance)

    largest = max(
        (h.market_value for h in profile.holdings if h.symbol not in BROAD_INDEX_ETFS),
        default=0.0,
    )
    return PortfolioMetrics(
        weights={cls.value: round(w, 4) for cls, w in weights.items()},
        volatility_annual=vol,
        var_95_1m=Z_95 * vol * math.sqrt(1 / 12),
        max_position_weight=largest / total,
        equity_ratio=weights.get(AssetClass.EQUITY, 0.0),
    )


def policy_allocation(profile: PortfolioProfile) -> dict[str, float]:
    """Banda de la política ajustada por horizonte (glide path)."""
    alloc = dict(POLICY_ALLOCATIONS[profile.risk_tolerance])
    if profile.investment_horizon_years > 15:
        shift = min(0.10, alloc.get("FIXED_INCOME", 0.0))
        alloc["EQUITY"] += shift
        alloc["FIXED_INCOME"] -= shift
    elif profile.investment_horizon_years < 3:
        shift = min(0.10, alloc["EQUITY"])
        alloc["EQUITY"] -= shift
        alloc["CASH_EQUIVALENT"] += shift
    return {k: round(v, 4) for k, v in alloc.items() if v > 0}


def score_from_metrics(metrics: PortfolioMetrics) -> float:
    """Puntaje 0-1: volatilidad relativa a una cartera 100% renta variable agresiva (~30%)
    más una penalización por concentración por encima del límite del 20%."""
    concentration_penalty = max(0.0, metrics.max_position_weight - 0.20)
    return round(min(1.0, metrics.volatility_annual / 0.30 + concentration_penalty), 3)


# --- Strategies ----------------------------------------------------------------------


class RiskEvaluationStrategy(ABC):
    """
    Interfaz abstracta de Estrategia para evaluar riesgo de carteras.
    Define el contrato que todas las implementaciones de IA deben cumplir.
    """

    @abstractmethod
    def evaluate(
        self, profile: PortfolioProfile, context: list[RetrievedChunk] | None = None
    ) -> RiskAssessmentResult:
        """Ejecuta la evaluación de riesgo; `context` son los chunks recuperados por RAG."""

    @property
    @abstractmethod
    def strategy_name(self) -> str:
        """Nombre identificador de la estrategia."""


class RuleBasedStrategy(RiskEvaluationStrategy):
    """Estrategia determinista sin dependencias externas: fallback siempre disponible."""

    @property
    def strategy_name(self) -> str:
        return "RuleBased-Policy"

    def evaluate(
        self, profile: PortfolioProfile, context: list[RetrievedChunk] | None = None
    ) -> RiskAssessmentResult:
        start = time.perf_counter()
        metrics = compute_portfolio_metrics(profile)
        return RiskAssessmentResult(
            risk_score=score_from_metrics(metrics),
            risk_level=profile.risk_tolerance.value,
            recommended_allocation=policy_allocation(profile),
            rationale=(
                f"[Rule-based] Policy band for {profile.risk_tolerance.value} with "
                f"{profile.investment_horizon_years}y horizon. Volatility "
                f"{metrics.volatility_annual:.1%}, VaR95 1m {metrics.var_95_1m:.2%}."
            ),
            strategy_used=self.strategy_name,
            estimated_var_95=round(metrics.var_95_1m, 4),
            volatility_annual=round(metrics.volatility_annual, 4),
            citations=[c.chunk_id for c in (context or []) if c.doc_id == "investment_policy"][:1],
            execution_time_ms=round((time.perf_counter() - start) * 1000, 2),
        )


class FineTunedModelStrategy(RiskEvaluationStrategy):
    """
    Representa la inferencia de un SLM financiero fine-tuned (p. ej. endpoint SageMaker).
    En este repo la inferencia se simula con el núcleo cuantitativo para mantener los
    tests deterministas; el contrato (entrada/salida) es el mismo que tendría el endpoint.
    """

    @property
    def strategy_name(self) -> str:
        return "FineTuned-SLM-QuantModel"

    def evaluate(
        self,
        profile: PortfolioProfile,
        context: list[RetrievedChunk] | None = None,  # noqa: ARG002 - contrato de la interfaz
    ) -> RiskAssessmentResult:
        start = time.perf_counter()
        metrics = compute_portfolio_metrics(profile)
        score = score_from_metrics(metrics)

        # El "modelo" reduce renta variable cuando el riesgo medido supera la tolerancia declarada
        alloc = policy_allocation(profile)
        tolerance_cap = {"CONSERVATIVE": 0.35, "BALANCED": 0.55, "GROWTH": 0.8, "AGGRESSIVE": 1.0}
        if score > tolerance_cap[profile.risk_tolerance.value] and "EQUITY" in alloc:
            shift = min(0.05, alloc["EQUITY"])
            alloc["EQUITY"] = round(alloc["EQUITY"] - shift, 4)
            alloc["FIXED_INCOME"] = round(alloc.get("FIXED_INCOME", 0.0) + shift, 4)

        return RiskAssessmentResult(
            risk_score=score,
            risk_level=profile.risk_tolerance.value,
            recommended_allocation=alloc,
            rationale=(
                f"[SLM Quant Inference] Volatilidad anual {metrics.volatility_annual:.2%}, "
                f"VaR 95% a 1 mes {metrics.var_95_1m:.2%}, posición máxima "
                f"{metrics.max_position_weight:.1%} del AUM."
            ),
            strategy_used=self.strategy_name,
            estimated_var_95=round(metrics.var_95_1m, 4),
            volatility_annual=round(metrics.volatility_annual, 4),
            execution_time_ms=round((time.perf_counter() - start) * 1000, 2),
        )


class LLMRiskOpinion(BaseModel):
    """Esquema de salida estructurada que el LLM debe cumplir (validado con Pydantic)."""

    risk_level: RiskTolerance
    risk_score: float = Field(ge=0.0, le=1.0)
    equity: float = Field(ge=0.0, le=1.0)
    fixed_income: float = Field(ge=0.0, le=1.0)
    cash_equivalent: float = Field(ge=0.0, le=1.0)
    commodity: float = Field(ge=0.0, le=1.0)
    crypto: float = Field(ge=0.0, le=1.0)
    rationale: str = Field(min_length=20)
    citations: list[str] = Field(description="chunk_id de los documentos usados")

    def allocation(self) -> dict[str, float]:
        raw = {
            "EQUITY": self.equity,
            "FIXED_INCOME": self.fixed_income,
            "CASH_EQUIVALENT": self.cash_equivalent,
            "COMMODITY": self.commodity,
            "CRYPTO": self.crypto,
        }
        return {k: round(v, 4) for k, v in raw.items() if v > 0}


SYSTEM_PROMPT = """You are the risk-assessment engine of a regulated investment advisory platform.
Assess the portfolio using ONLY the provided metrics and internal documents.
Rules:
- Recommend an allocation (fractions that sum to 1.0) consistent with the client's declared risk tolerance and the investment policy.
- Never recommend crypto for CONSERVATIVE or BALANCED clients.
- Cite the chunk_id of every document you rely on; cite nothing that is not in the provided documents.
- Do not compute VaR or volatility yourself: they are provided."""


class LLMRagStrategy(RiskEvaluationStrategy):
    """
    Estrategia RAG: el LLM razona sobre métricas calculadas + documentos recuperados y
    devuelve una opinión estructurada con citas. Las cifras de riesgo (VaR, volatilidad)
    provienen del núcleo cuantitativo, nunca del modelo.
    """

    def __init__(self, llm: LLMClient) -> None:
        self._llm = llm

    @property
    def strategy_name(self) -> str:
        return f"LLM-RAG[{self._llm.name}]"

    def evaluate(
        self, profile: PortfolioProfile, context: list[RetrievedChunk] | None = None
    ) -> RiskAssessmentResult:
        start = time.perf_counter()
        metrics = compute_portfolio_metrics(profile)
        chunks = context or []
        policy = policy_allocation(profile)

        documents = "\n\n".join(f'<doc id="{c.chunk_id}">\n{c.chunk.text}\n</doc>' for c in chunks)
        user = (
            f"Client risk tolerance: {profile.risk_tolerance.value}\n"
            f"Investment horizon: {profile.investment_horizon_years} years\n"
            f"Portfolio metrics: {metrics.as_dict()}\n"
            f"Policy reference allocation: {policy}\n\n"
            f"Internal documents:\n{documents}"
        )
        opinion = self._llm.generate(
            system=SYSTEM_PROMPT,
            user=user,
            response_model=LLMRiskOpinion,
            context={
                "risk_tolerance": profile.risk_tolerance.value,
                "metrics": metrics.as_dict(),
                "policy_allocation": policy,
                "retrieved_ids": [c.chunk_id for c in chunks],
            },
        )

        return RiskAssessmentResult(
            risk_score=opinion.risk_score,
            risk_level=opinion.risk_level.value,
            recommended_allocation=opinion.allocation(),
            rationale=f"[RAG] {opinion.rationale}",
            strategy_used=self.strategy_name,
            estimated_var_95=round(metrics.var_95_1m, 4),
            volatility_annual=round(metrics.volatility_annual, 4),
            citations=opinion.citations,
            execution_time_ms=round((time.perf_counter() - start) * 1000, 2),
        )


class AdvisorContext:
    """
    Contexto que orquesta la estrategia activa según el patrón Strategy.
    Permite el intercambio de estrategias en tiempo de ejecución (Runtime Interchangeability).
    """

    def __init__(self, strategy: RiskEvaluationStrategy):
        self._strategy: RiskEvaluationStrategy = strategy
        self._history: list[dict[str, Any]] = []

    @property
    def current_strategy(self) -> RiskEvaluationStrategy:
        return self._strategy

    def set_strategy(self, strategy: RiskEvaluationStrategy) -> None:
        """Conmuta dinámicamente la estrategia activa."""
        self._strategy = strategy

    def evaluate_risk(
        self, profile: PortfolioProfile, context: list[RetrievedChunk] | None = None
    ) -> RiskAssessmentResult:
        """Delega en la estrategia configurada y registra telemetría para auditoría MLOps."""
        result = self._strategy.evaluate(profile, context)
        self._history.append(
            {
                "portfolio_id": profile.portfolio_id,
                "strategy": result.strategy_used,
                "risk_score": result.risk_score,
                "degraded": result.degraded,
                "execution_time_ms": result.execution_time_ms,
                "timestamp": result.timestamp.isoformat(),
            }
        )
        return result

    def get_telemetry_history(self) -> list[dict[str, Any]]:
        """Retorna histórico de ejecuciones para auditoría MLOps."""
        return list(self._history)
