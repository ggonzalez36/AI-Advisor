"""
Guardrails applied to every AI recommendation before anything is executed.

- Blocking violations reject the recommendation outright (hallucinated sources,
  unsuitable assets, invalid allocations, unfunded trades).
- Review reasons route it to a licensed human advisor (high risk, large trades,
  degraded model path, concentration).

Rules mirror src/knowledge/suitability_and_oversight.md and investment_policy.md.
"""

from __future__ import annotations

from collections.abc import Iterable

from pydantic import BaseModel, Field

from src.rebalancing import TradeProposal, portfolio_value
from src.strategy import BROAD_INDEX_ETFS, PortfolioProfile, RiskAssessmentResult, RiskTolerance

HIGH_RISK_SCORE = 0.70
MAX_TRADE_SHARE_OF_AUM = 0.10
MAX_POSITION_SHARE_OF_AUM = 0.20
MAX_CRYPTO_SHARE = 0.05
ALLOCATION_TOLERANCE = 0.02


class GuardrailReport(BaseModel):
    blocking: list[str] = Field(default_factory=list)
    review_reasons: list[str] = Field(default_factory=list)

    @property
    def passed(self) -> bool:
        return not self.blocking


def evaluate_guardrails(
    profile: PortfolioProfile,
    assessment: RiskAssessmentResult,
    proposals: list[TradeProposal],
    retrieved_ids: Iterable[str],
) -> GuardrailReport:
    report = GuardrailReport()
    retrieved_ids = list(retrieved_ids)  # Iterated multiple times
    total = portfolio_value(profile) or 1.0
    alloc = assessment.recommended_allocation

    # 1. Groundedness: every citation must match a chunk that was actually retrieved
    unknown = sorted(set(assessment.citations) - set(retrieved_ids))
    if unknown:
        report.blocking.append(f"hallucinated citations: {unknown}")
    if not assessment.citations and not assessment.degraded:
        report.blocking.append("recommendation has no supporting citations")

    # 1b. Sufficient context: without the investment policy the model would be improvising
    if not any(rid.startswith("investment_policy#") for rid in retrieved_ids):
        report.review_reasons.append("insufficient context: investment policy not retrieved")

    # 2. Allocation validity
    allocation_sum = sum(alloc.values())
    if abs(allocation_sum - 1.0) > ALLOCATION_TOLERANCE:
        report.blocking.append(f"allocation sums to {allocation_sum:.3f}, expected 1.0")

    # 3. Suitability
    crypto = alloc.get("CRYPTO", 0.0)
    if crypto > 0 and profile.risk_tolerance in (
        RiskTolerance.CONSERVATIVE,
        RiskTolerance.BALANCED,
    ):
        report.blocking.append(
            f"crypto allocation {crypto:.0%} unsuitable for {profile.risk_tolerance}"
        )
    if crypto > MAX_CRYPTO_SHARE:
        report.blocking.append(f"crypto allocation {crypto:.0%} exceeds {MAX_CRYPTO_SHARE:.0%} cap")
    if assessment.risk_level != profile.risk_tolerance.value:
        report.blocking.append(
            f"risk level {assessment.risk_level} contradicts declared tolerance {profile.risk_tolerance}"
        )

    # 4. Funding: never buy beyond the available cash
    total_notional = sum(p.notional for p in proposals)
    if total_notional > profile.cash_balance + 0.01:
        report.blocking.append(
            f"proposals need {total_notional:,.2f} USD but only {profile.cash_balance:,.2f} available"
        )

    # 5. Human review reasons
    if assessment.risk_score >= HIGH_RISK_SCORE:
        report.review_reasons.append(f"risk score {assessment.risk_score:.2f} >= {HIGH_RISK_SCORE}")
    if assessment.degraded:
        report.review_reasons.append("produced by degraded fallback path")

    position_values = {h.symbol: h.market_value for h in profile.holdings}
    for p in proposals:
        if p.notional > MAX_TRADE_SHARE_OF_AUM * total:
            report.review_reasons.append(
                f"{p.symbol} trade {p.notional:,.0f} USD exceeds {MAX_TRADE_SHARE_OF_AUM:.0%} of AUM"
            )
        position_values[p.symbol] = position_values.get(p.symbol, 0.0) + p.notional

    for symbol, value in position_values.items():
        if symbol not in BROAD_INDEX_ETFS and value > MAX_POSITION_SHARE_OF_AUM * total:
            report.review_reasons.append(
                f"{symbol} would be {value / total:.0%} of AUM (limit {MAX_POSITION_SHARE_OF_AUM:.0%})"
            )

    return report
