"""Shared fixtures: representative investor profiles."""

import pytest

from src.strategy import AssetClass, Holding, PortfolioProfile, RiskTolerance


@pytest.fixture
def balanced_profile() -> PortfolioProfile:
    # 24% en efectivo: dispara propuestas de despliegue de caja
    return PortfolioProfile(
        user_id="usr-501",
        portfolio_id="port-balanced",
        total_aum=187500.0,
        cash_balance=60000.0,
        risk_tolerance=RiskTolerance.BALANCED,
        investment_horizon_years=7,
        holdings=[
            Holding(symbol="VOO", quantity=200, current_price=450.0, asset_class=AssetClass.EQUITY),
            Holding(
                symbol="BND", quantity=500, current_price=75.0, asset_class=AssetClass.FIXED_INCOME
            ),
        ],
    )


@pytest.fixture
def conservative_profile() -> PortfolioProfile:
    # Ya alineado con su banda: no requiere operaciones
    return PortfolioProfile(
        user_id="usr-502",
        portfolio_id="port-conservative",
        total_aum=100000.0,
        cash_balance=20000.0,
        risk_tolerance=RiskTolerance.CONSERVATIVE,
        investment_horizon_years=5,
        holdings=[
            Holding(
                symbol="BND", quantity=800, current_price=75.0, asset_class=AssetClass.FIXED_INCOME
            ),
            Holding(symbol="VOO", quantity=44, current_price=450.0, asset_class=AssetClass.EQUITY),
        ],
    )


@pytest.fixture
def concentrated_profile() -> PortfolioProfile:
    # 65% en una sola acción tecnológica: riesgo alto y concentración
    return PortfolioProfile(
        user_id="usr-503",
        portfolio_id="port-concentrated",
        total_aum=500000.0,
        cash_balance=50000.0,
        risk_tolerance=RiskTolerance.AGGRESSIVE,
        investment_horizon_years=8,
        holdings=[
            Holding(
                symbol="NVDA", quantity=2600, current_price=125.0, asset_class=AssetClass.EQUITY
            ),
            Holding(
                symbol="AAPL", quantity=600, current_price=225.0, asset_class=AssetClass.EQUITY
            ),
        ],
    )
