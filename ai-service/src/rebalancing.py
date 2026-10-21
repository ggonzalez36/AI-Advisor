"""
Deterministic rebalancing: turns a target allocation into concrete BUY orders whose
shape matches the portfolio-api contract (POST /api/v1/orders/buy: integer quantity,
decimal-string price).
"""

from __future__ import annotations

import math
from decimal import ROUND_HALF_UP, Decimal

from pydantic import BaseModel, Field

from src.strategy import AssetClass, PortfolioProfile, RiskAssessmentResult

MIN_TRADE_USD = 1000.0  # investment_policy.md: trades menores se omiten

# Instrumento preferido por clase de activo (ETFs indexados) y precio de referencia
DEFAULT_INSTRUMENTS: dict[str, tuple[str, float]] = {
    AssetClass.EQUITY.value: ("VOO", 450.00),
    AssetClass.FIXED_INCOME.value: ("BND", 72.50),
    AssetClass.COMMODITY.value: ("GLD", 190.00),
    AssetClass.CRYPTO.value: ("IBIT", 35.00),
}


class TradeProposal(BaseModel):
    action: str = "BUY"
    symbol: str
    asset_class: str
    quantity: int = Field(gt=0)
    limit_price: str  # Decimal en texto, igual que la API de Go
    notional: float
    rationale: str


def portfolio_value(profile: PortfolioProfile) -> float:
    return sum(h.market_value for h in profile.holdings) + profile.cash_balance


def _price_for(profile: PortfolioProfile, symbol: str, default: float) -> float:
    for h in profile.holdings:
        if h.symbol == symbol:
            return h.current_price
    return default


def propose_trades(
    profile: PortfolioProfile, assessment: RiskAssessmentResult
) -> list[TradeProposal]:
    """Compras hacia la asignación objetivo, financiadas solo con efectivo disponible por
    encima de la reserva de liquidez objetivo (nunca apalancamiento)."""
    total = portfolio_value(profile)
    target = assessment.recommended_allocation

    current_by_class: dict[str, float] = {}
    for h in profile.holdings:
        current_by_class[h.asset_class.value] = (
            current_by_class.get(h.asset_class.value, 0.0) + h.market_value
        )

    cash_reserve = target.get(AssetClass.CASH_EQUIVALENT.value, 0.0) * total
    budget = max(0.0, profile.cash_balance - cash_reserve)

    gaps = sorted(
        (
            (cls, weight * total - current_by_class.get(cls, 0.0))
            for cls, weight in target.items()
            if cls in DEFAULT_INSTRUMENTS
        ),
        key=lambda item: item[1],
        reverse=True,
    )

    proposals: list[TradeProposal] = []
    for asset_class, gap in gaps:
        if gap < MIN_TRADE_USD or budget < MIN_TRADE_USD:
            continue
        symbol, default_price = DEFAULT_INSTRUMENTS[asset_class]
        price = _price_for(profile, symbol, default_price)
        quantity = math.floor(min(gap, budget) / price)
        notional = quantity * price
        if quantity <= 0 or notional < MIN_TRADE_USD:
            continue

        budget -= notional
        proposals.append(
            TradeProposal(
                symbol=symbol,
                asset_class=asset_class,
                quantity=quantity,
                limit_price=str(Decimal(str(price)).quantize(Decimal("0.01"), ROUND_HALF_UP)),
                notional=round(notional, 2),
                rationale=(
                    f"{asset_class} underweight by {gap:,.0f} USD vs target "
                    f"{target[asset_class]:.0%}; buy broad ETF {symbol}."
                ),
            )
        )
    return proposals
