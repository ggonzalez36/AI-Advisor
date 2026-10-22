#!/usr/bin/env python3
"""
MLOps Dataset Generation Script for Fine-Tuning Financial SLM/LLMs.
Produces JSONL datasets formatted for OpenAI Chat Fine-Tuning and Alpaca/HuggingFace
formats with train/validation splits.

Labels are produced by a teacher (the deterministic quantitative pipeline) applied to
each synthetic portfolio — knowledge distillation — so targets depend on the actual
inputs. A stats file reports duplicates and label variability for data-quality gates.
"""

import argparse
import json
import os
import random
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from src.rebalancing import propose_trades  # noqa: E402
from src.strategy import (  # noqa: E402
    AssetClass,
    Holding,
    PortfolioProfile,
    RiskTolerance,
    RuleBasedStrategy,
    compute_portfolio_metrics,
)

TEACHER = RuleBasedStrategy()

SYSTEM_PROMPT = """You are the quantitative advisory engine of 'fin-ai-advisor'.
Your job is to assess the investor's risk profile, analyze the concentration of their portfolio
and formulate prudent rebalancing recommendations with Value-at-Risk (VaR) calculations
and economic justification under strict fiduciary standards."""

INVESTOR_ARCHETYPES = [
    {
        "archetype": "Conservative Retiree",
        "tolerance": "CONSERVATIVE",
        "horizon": 3,
        "aum_range": (150000, 800000),
        "holdings_template": [
            {"symbol": "BND", "class": "FIXED_INCOME", "weight": 0.55},
            {"symbol": "VTIP", "class": "FIXED_INCOME", "weight": 0.20},
            {"symbol": "VIG", "class": "EQUITY", "weight": 0.15},
            {"symbol": "SHV", "class": "CASH_EQUIVALENT", "weight": 0.10},
        ],
        "scenario": "Strict capital preservation amid inflationary pressure and a need for passive income.",
    },
    {
        "archetype": "Mid-Career Professional",
        "tolerance": "BALANCED",
        "horizon": 12,
        "aum_range": (50000, 350000),
        "holdings_template": [
            {"symbol": "VOO", "class": "EQUITY", "weight": 0.45},
            {"symbol": "VEA", "class": "EQUITY", "weight": 0.15},
            {"symbol": "BND", "class": "FIXED_INCOME", "weight": 0.30},
            {"symbol": "BIL", "class": "CASH_EQUIVALENT", "weight": 0.10},
        ],
        "scenario": "Balanced wealth growth with a time horizon of more than a decade.",
    },
    {
        "archetype": "Young High-Growth Investor",
        "tolerance": "GROWTH",
        "horizon": 25,
        "aum_range": (20000, 120000),
        "holdings_template": [
            {"symbol": "QQQ", "class": "EQUITY", "weight": 0.50},
            {"symbol": "VTI", "class": "EQUITY", "weight": 0.35},
            {"symbol": "VNQ", "class": "EQUITY", "weight": 0.10},
            {"symbol": "CASH", "class": "CASH_EQUIVALENT", "weight": 0.05},
        ],
        "scenario": "Accepts high year-over-year volatility to maximize compounded capital appreciation.",
    },
    {
        "archetype": "High Tech Concentration",
        "tolerance": "AGGRESSIVE",
        "horizon": 8,
        "aum_range": (200000, 1500000),
        "holdings_template": [
            {"symbol": "NVDA", "class": "EQUITY", "weight": 0.65},
            {"symbol": "AAPL", "class": "EQUITY", "weight": 0.25},
            {"symbol": "USD", "class": "CASH_EQUIVALENT", "weight": 0.10},
        ],
        "scenario": "Critical concentration risk from an overweight position in semiconductors.",
    },
]


def build_profile(idx: int, template: dict[str, Any]) -> PortfolioProfile:
    """Synthetic portfolio with random variation in weights, prices and cash."""
    aum = round(random.uniform(*template["aum_range"]), -2)
    cash = round(aum * random.uniform(0.03, 0.30), 2)
    invested = aum - cash

    holdings = []
    for h in template["holdings_template"]:
        if h["class"] == "CASH_EQUIVALENT":
            cash += invested * h["weight"]
            continue
        price = round(random.uniform(50.0, 450.0), 2)
        value = invested * h["weight"] * random.uniform(0.6, 1.4)
        holdings.append(
            Holding(
                symbol=h["symbol"],
                quantity=round(value / price, 2),
                current_price=price,
                asset_class=AssetClass(h["class"]),
            )
        )

    return PortfolioProfile(
        user_id=f"synthetic-{idx:04d}",
        portfolio_id=f"port-{idx:04d}",
        total_aum=aum,
        cash_balance=round(cash, 2),
        risk_tolerance=RiskTolerance(template["tolerance"]),
        investment_horizon_years=max(1, template["horizon"] + random.randint(-2, 6)),
        holdings=holdings,
    )


def generate_single_sample(idx: int) -> dict[str, Any]:
    """Example labeled by a teacher model (distillation).

    The label comes from applying the deterministic quantitative pipeline (RuleBasedStrategy +
    rebalancing) to the generated portfolio, so it depends on the actual characteristics
    of the input (volatility, concentration, cash, horizon) rather than on a fixed table
    per archetype, which would only teach the model to memorize the archetype.
    """
    template = random.choice(INVESTOR_ARCHETYPES)
    profile = build_profile(idx, template)
    assessment = TEACHER.evaluate(profile)
    proposals = propose_trades(profile, assessment)
    metrics = compute_portfolio_metrics(profile)

    holdings_text = ", ".join(
        f"{h.symbol} ({h.asset_class.value}): {h.quantity} x ${h.current_price}"
        for h in profile.holdings
    )
    user_query = (
        f"Please assess my portfolio '{profile.portfolio_id}'. Cash: ${profile.cash_balance:,.2f}. "
        f"Holdings: {holdings_text}. My declared risk tolerance is "
        f"{profile.risk_tolerance.value} with a {profile.investment_horizon_years}-year horizon. "
        f"Investor context: {template['scenario']}"
    )

    assistant_response = {
        "portfolio_id": profile.portfolio_id,
        "risk_evaluation": {
            "score": assessment.risk_score,
            "category": assessment.risk_level,
            "volatility_annual_pct": round(metrics.volatility_annual * 100, 2),
            "estimated_var_95_1m_pct": round(assessment.estimated_var_95 * 100, 2),
            "max_single_position_pct": round(metrics.max_position_weight * 100, 1),
        },
        "target_allocation": assessment.recommended_allocation,
        "proposed_trades": [
            {
                "action": p.action,
                "symbol": p.symbol,
                "quantity": p.quantity,
                "limit_price": p.limit_price,
            }
            for p in proposals
        ],
        "recommendation": assessment.rationale,
    }

    return {
        "system": SYSTEM_PROMPT,
        "user": user_query,
        "assistant": json.dumps(assistant_response, ensure_ascii=False, indent=2),
        "_label_score": assessment.risk_score,
        "_archetype": template["archetype"],
    }


def dataset_stats(samples: list[dict[str, Any]]) -> dict[str, Any]:
    """Dataset quality checks: duplicates and label variability per archetype."""
    unique_inputs = len({s["user"] for s in samples})
    by_archetype: dict[str, list[float]] = {}
    for s in samples:
        by_archetype.setdefault(s["_archetype"], []).append(s["_label_score"])
    return {
        "samples": len(samples),
        "duplicate_inputs": len(samples) - unique_inputs,
        "label_score_spread_by_archetype": {
            name: round(max(scores) - min(scores), 3) for name, scores in by_archetype.items()
        },
    }


def format_for_openai_chat(sample: dict[str, Any]) -> dict[str, Any]:
    return {
        "messages": [
            {"role": "system", "content": sample["system"]},
            {"role": "user", "content": sample["user"]},
            {"role": "assistant", "content": sample["assistant"]},
        ]
    }


def format_for_alpaca(sample: dict[str, Any]) -> dict[str, Any]:
    return {
        "instruction": sample["system"],
        "input": sample["user"],
        "output": sample["assistant"],
    }


def main():
    parser = argparse.ArgumentParser(description="Fine-Tuning Dataset Generator for MLOps")
    parser.add_argument(
        "--num-samples", type=int, default=100, help="Total number of samples to generate"
    )
    parser.add_argument(
        "--output-dir", type=str, default="data/finetuning", help="Output directory"
    )
    parser.add_argument(
        "--format", type=str, choices=["openai", "alpaca", "both"], default="openai"
    )
    parser.add_argument(
        "--eval-split", type=float, default=0.20, help="Fraction held out for validation"
    )
    parser.add_argument("--seed", type=int, default=42, help="Pseudo-random seed")

    args = parser.parse_args()
    random.seed(args.seed)

    os.makedirs(args.output_dir, exist_ok=True)
    print(f"[MLOps] Generating {args.num_samples} financial samples (Seed={args.seed})...")

    raw_samples = [generate_single_sample(i + 1) for i in range(args.num_samples)]
    random.shuffle(raw_samples)

    stats = dataset_stats(raw_samples)
    stats_path = os.path.join(args.output_dir, "dataset_stats.json")
    with open(stats_path, "w", encoding="utf-8") as f_stats:
        json.dump(stats, f_stats, indent=2, ensure_ascii=False)
    print(f"[MLOps] Dataset quality: {stats}")

    split_idx = int(args.num_samples * (1.0 - args.eval_split))
    train_raw = raw_samples[:split_idx]
    val_raw = raw_samples[split_idx:]

    formats_to_generate = (
        ["openai"]
        if args.format == "openai"
        else ["alpaca"]
        if args.format == "alpaca"
        else ["openai", "alpaca"]
    )

    for fmt in formats_to_generate:
        formatter = format_for_openai_chat if fmt == "openai" else format_for_alpaca
        suffix = f"_{fmt}" if len(formats_to_generate) > 1 else ""

        train_path = os.path.join(args.output_dir, f"train{suffix}.jsonl")
        val_path = os.path.join(args.output_dir, f"val{suffix}.jsonl")

        with open(train_path, "w", encoding="utf-8") as f_train:
            for item in train_raw:
                f_train.write(json.dumps(formatter(item), ensure_ascii=False) + "\n")

        with open(val_path, "w", encoding="utf-8") as f_val:
            for item in val_raw:
                f_val.write(json.dumps(formatter(item), ensure_ascii=False) + "\n")

        train_size_kb = os.path.getsize(train_path) / 1024
        val_size_kb = os.path.getsize(val_path) / 1024

        print(f"[MLOps - {fmt.upper()}] Dataset ready:")
        print(f"  -> Train: {train_path} ({len(train_raw)} rows, {train_size_kb:.1f} KB)")
        print(f"  -> Val:   {val_path} ({len(val_raw)} rows, {val_size_kb:.1f} KB)")

    print("[MLOps] Generation completed successfully. Ready for the Fine-Tuning pipeline.")


if __name__ == "__main__":
    main()
