"""
Strategy Pattern implementation for Portfolio Risk Evaluation.
Complies with ADR 002 and Refactoring.Guru guidelines:
https://refactoring.guru/design-patterns/strategy
"""

import time
from abc import ABC, abstractmethod
from datetime import UTC, datetime
from enum import StrEnum
from typing import Any

from pydantic import BaseModel, Field


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
    confidence: float = Field(ge=0.0, le=1.0)
    estimated_var_95: float = Field(description="Value at Risk (VaR) estimado al 95% a 1 mes")
    execution_time_ms: float
    timestamp: datetime = Field(default_factory=lambda: datetime.now(UTC))


class RiskEvaluationStrategy(ABC):
    """
    Interfaz abstracta de Estrategia para evaluar riesgo de carteras.
    Define el contrato que todas las implementaciones de IA deben cumplir.
    """

    @abstractmethod
    def evaluate(self, profile: PortfolioProfile) -> RiskAssessmentResult:
        """
        Ejecuta la evaluación de riesgo sobre el perfil del portafolio.
        """
        pass

    @property
    @abstractmethod
    def strategy_name(self) -> str:
        """Nombre identificador de la estrategia."""
        pass


class LangChainOpenAIStrategy(RiskEvaluationStrategy):
    """
    Estrategia RAG orquestada con LangChain / LLM externo.
    Prioriza explicabilidad cualitativa, análisis de sentimiento y reportes macroeconómicos.
    """

    @property
    def strategy_name(self) -> str:
        return "LangChain-RAG-OpenAI"

    def evaluate(self, profile: PortfolioProfile) -> RiskAssessmentResult:
        start_time = time.perf_counter()

        # Simulación de recuperación de contexto vectorial (SEC 10-K, tasas FED)
        equity_ratio = 0.0
        if profile.total_aum > 0:
            total_equity = sum(
                h.market_value for h in profile.holdings if h.asset_class == AssetClass.EQUITY
            )
            equity_ratio = total_equity / profile.total_aum

        # Asignación de scoring RAG contextualizado
        base_scores = {
            RiskTolerance.CONSERVATIVE: 0.25,
            RiskTolerance.BALANCED: 0.50,
            RiskTolerance.GROWTH: 0.72,
            RiskTolerance.AGGRESSIVE: 0.88,
        }
        score = base_scores.get(profile.risk_tolerance, 0.50)
        # Ajuste dinámico según concentración de renta variable
        if equity_ratio > 0.7:
            score = min(1.0, score + 0.08)

        elapsed_ms = (time.perf_counter() - start_time) * 1000 + 42.0  # Latencia RAG típica

        allocations = {
            RiskTolerance.CONSERVATIVE: {
                "FIXED_INCOME": 0.60,
                "EQUITY": 0.20,
                "CASH_EQUIVALENT": 0.20,
            },
            RiskTolerance.BALANCED: {"FIXED_INCOME": 0.35, "EQUITY": 0.50, "CASH_EQUIVALENT": 0.15},
            RiskTolerance.GROWTH: {"FIXED_INCOME": 0.15, "EQUITY": 0.75, "CASH_EQUIVALENT": 0.10},
            RiskTolerance.AGGRESSIVE: {
                "FIXED_INCOME": 0.05,
                "EQUITY": 0.85,
                "CRYPTO": 0.05,
                "CASH_EQUIVALENT": 0.05,
            },
        }[profile.risk_tolerance]

        rationale = (
            f"[RAG Qualitative Analysis] Portafolio '{profile.portfolio_id}' con horizonte de "
            f"{profile.investment_horizon_years} años. Análisis macroeconómico sugiere mantener "
            f"exposición moderada ante volatilidad de tasas de interés. Exposición actual en "
            f"renta variable: {equity_ratio:.1%}."
        )

        return RiskAssessmentResult(
            risk_score=round(score, 3),
            risk_level=profile.risk_tolerance.value,
            recommended_allocation=allocations,
            rationale=rationale,
            strategy_used=self.strategy_name,
            confidence=0.92,
            estimated_var_95=round(score * 0.14, 4),
            execution_time_ms=round(elapsed_ms, 2),
        )


class FineTunedModelStrategy(RiskEvaluationStrategy):
    """
    Estrategia de inferencia local con SLM/Transformer especializado en finanzas.
    Prioriza ultra-baja latencia (<50ms), soberanía de datos y cálculo determinista de VaR.
    """

    @property
    def strategy_name(self) -> str:
        return "FineTuned-SLM-QuantModel"

    def evaluate(self, profile: PortfolioProfile) -> RiskAssessmentResult:
        start_time = time.perf_counter()

        # Inferencia matemática determinista simulada de modelo fine-tuned
        weights_sum = sum(h.market_value for h in profile.holdings) or 1.0
        weighted_volatility = (
            sum(
                (0.25 if h.asset_class == AssetClass.EQUITY else 0.06)
                * (h.market_value / weights_sum)
                for h in profile.holdings
            )
            or 0.12
        )

        # VaR paramétrico al 95% (1.645 * volatilidad ponderada)
        var_95 = 1.645 * weighted_volatility * (profile.investment_horizon_years**-0.2)
        normalized_score = min(1.0, max(0.05, var_95 * 2.5))

        elapsed_ms = (time.perf_counter() - start_time) * 1000 + 12.0  # Inferencia local veloz

        recommended = {
            "EQUITY": round(max(0.1, 1.0 - (normalized_score * 0.9)), 2),
            "FIXED_INCOME": round(normalized_score * 0.7, 2),
            "CASH_EQUIVALENT": round(
                max(
                    0.05, 1.0 - (max(0.1, 1.0 - (normalized_score * 0.9)) + normalized_score * 0.7)
                ),
                2,
            ),
        }

        rationale = (
            f"[SLM Quant Inference] Inferencia directa completada en {elapsed_ms:.1f}ms. "
            f"Volatilidad ponderada calculada: {weighted_volatility:.2%}. "
            f"VaR 95% a 30 días proyectado en {var_95:.2%}."
        )

        return RiskAssessmentResult(
            risk_score=round(normalized_score, 3),
            risk_level=profile.risk_tolerance.value,
            recommended_allocation=recommended,
            rationale=rationale,
            strategy_used=self.strategy_name,
            confidence=0.96,
            estimated_var_95=round(var_95, 4),
            execution_time_ms=round(elapsed_ms, 2),
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

    def evaluate_risk(self, profile: PortfolioProfile) -> RiskAssessmentResult:
        """
        Ejecuta la evaluación delegando en la estrategia configurada,
        registrando telemetría y métricas de desempeño.
        """
        result = self._strategy.evaluate(profile)

        self._history.append(
            {
                "portfolio_id": profile.portfolio_id,
                "strategy": self._strategy.strategy_name,
                "risk_score": result.risk_score,
                "execution_time_ms": result.execution_time_ms,
                "timestamp": result.timestamp.isoformat(),
            }
        )

        return result

    def get_telemetry_history(self) -> list[dict[str, Any]]:
        """Retorna histórico de ejecuciones para auditoría MLOps."""
        return list(self._history)
