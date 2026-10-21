#!/usr/bin/env python3
"""
MLOps Dataset Generation Script for Fine-Tuning Financial SLM/LLMs.
Produces production-grade JSONL datasets formatted for OpenAI Chat Fine-Tuning
and Alpaca/HuggingFace formats with train/validation splits.
"""

import argparse
import json
import os
import random
from typing import Any

SYSTEM_PROMPT = """Eres el motor de asesoría cuantitativa de 'fin-ai-advisor'.
Tu labor es evaluar el perfil de riesgo del inversor, analizar la concentración de su cartera
y formular recomendaciones de rebalanceo prudentes con cálculo de Value-at-Risk (VaR)
y justificación económica bajo normas fiduciarias estrictas."""

INVESTOR_ARCHETYPES = [
    {
        "archetype": "Jubilado Conservador",
        "tolerance": "CONSERVATIVE",
        "horizon": 3,
        "aum_range": (150000, 800000),
        "holdings_template": [
            {"symbol": "BND", "class": "FIXED_INCOME", "weight": 0.55},
            {"symbol": "VTIP", "class": "FIXED_INCOME", "weight": 0.20},
            {"symbol": "VIG", "class": "EQUITY", "weight": 0.15},
            {"symbol": "SHV", "class": "CASH_EQUIVALENT", "weight": 0.10},
        ],
        "scenario": "Preservación estricta de capital ante presiones inflacionarias y necesidad de ingresos pasivos.",
    },
    {
        "archetype": "Profesional en Media Carrera",
        "tolerance": "BALANCED",
        "horizon": 12,
        "aum_range": (50000, 350000),
        "holdings_template": [
            {"symbol": "VOO", "class": "EQUITY", "weight": 0.45},
            {"symbol": "VEA", "class": "EQUITY", "weight": 0.15},
            {"symbol": "BND", "class": "FIXED_INCOME", "weight": 0.30},
            {"symbol": "BIL", "class": "CASH_EQUIVALENT", "weight": 0.10},
        ],
        "scenario": "Crecimiento patrimonial balanceado con horizonte temporal superior a una década.",
    },
    {
        "archetype": "Inversor Joven de Alto Crecimiento",
        "tolerance": "GROWTH",
        "horizon": 25,
        "aum_range": (20000, 120000),
        "holdings_template": [
            {"symbol": "QQQ", "class": "EQUITY", "weight": 0.50},
            {"symbol": "VTI", "class": "EQUITY", "weight": 0.35},
            {"symbol": "VNQ", "class": "EQUITY", "weight": 0.10},
            {"symbol": "CASH", "class": "CASH_EQUIVALENT", "weight": 0.05},
        ],
        "scenario": "Aceptación de alta volatilidad interanual para maximizar apreciación de capital compuesto.",
    },
    {
        "archetype": "Alta Concentración Tecnológica",
        "tolerance": "AGGRESSIVE",
        "horizon": 8,
        "aum_range": (200000, 1500000),
        "holdings_template": [
            {"symbol": "NVDA", "class": "EQUITY", "weight": 0.65},
            {"symbol": "AAPL", "class": "EQUITY", "weight": 0.25},
            {"symbol": "USD", "class": "CASH_EQUIVALENT", "weight": 0.10},
        ],
        "scenario": "Riesgo de concentración crítico por sobreponderación en semiconductores.",
    },
]


def generate_single_sample(idx: int) -> dict[str, Any]:
    """Genera un ejemplo sintético pero estadísticamente realista."""
    template = random.choice(INVESTOR_ARCHETYPES)
    aum = round(random.uniform(*template["aum_range"]), -2)
    cash = round(aum * random.uniform(0.05, 0.20), 2)
    invested_aum = aum - cash

    holdings = []
    for h in template["holdings_template"]:
        alloc_value = invested_aum * h["weight"] * random.uniform(0.92, 1.08)
        price = round(random.uniform(50.0, 450.0), 2)
        qty = round(alloc_value / price, 2)
        holdings.append(
            {
                "symbol": h["symbol"],
                "asset_class": h["class"],
                "quantity": qty,
                "unit_price": price,
                "current_value": round(qty * price, 2),
            }
        )

    user_query = (
        f"Por favor evalúa mi cartera 'port-{idx:04d}'. Cuento con un patrimonio de ${aum:,.2f} "
        f"(${cash:,.2f} en liquidez). Mi tolerancia al riesgo declarada es {template['tolerance']} "
        f"con un horizonte de {template['horizon']} años. Contexto del inversor: {template['scenario']}."
    )

    risk_scores = {"CONSERVATIVE": 0.28, "BALANCED": 0.52, "GROWTH": 0.76, "AGGRESSIVE": 0.91}
    base_score = risk_scores[template["tolerance"]] + random.uniform(-0.04, 0.04)
    final_score = round(min(0.99, max(0.05, base_score)), 3)
    var_95 = round(final_score * 0.135, 4)

    assistant_response = {
        "portfolio_id": f"port-{idx:04d}",
        "risk_evaluation": {
            "score": final_score,
            "category": template["tolerance"],
            "estimated_var_95_pct": round(var_95 * 100, 2),
            "volatility_regime": "MODERATE",
        },
        "target_allocation": {
            "EQUITY": 0.20 if template["tolerance"] == "CONSERVATIVE" else 0.60,
            "FIXED_INCOME": 0.65 if template["tolerance"] == "CONSERVATIVE" else 0.30,
            "CASH_EQUIVALENT": 0.15 if template["tolerance"] == "CONSERVATIVE" else 0.10,
        },
        "recommendation": (
            f"Basado en el horizonte de {template['horizon']} años y la condición '{template['scenario']}', "
            f"se determina un VaR a 30 días de {var_95 * 100:.2f}%. Se recomienda rebalancear hacia "
            f"la asignación objetivo para mitigar riesgos asimétricos."
        ),
    }

    return {
        "system": SYSTEM_PROMPT,
        "user": user_query,
        "assistant": json.dumps(assistant_response, ensure_ascii=False, indent=2),
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
    parser = argparse.ArgumentParser(description="Generador de Datasets de Fine-Tuning para MLOps")
    parser.add_argument(
        "--num-samples", type=int, default=100, help="Número total de muestras a generar"
    )
    parser.add_argument(
        "--output-dir", type=str, default="data/finetuning", help="Directorio de salida"
    )
    parser.add_argument(
        "--format", type=str, choices=["openai", "alpaca", "both"], default="openai"
    )
    parser.add_argument("--eval-split", type=float, default=0.20, help="Proporción para validación")
    parser.add_argument("--seed", type=int, default=42, help="Semilla pseudoaleatoria")

    args = parser.parse_args()
    random.seed(args.seed)

    os.makedirs(args.output_dir, exist_ok=True)
    print(f"[MLOps] Generando {args.num_samples} muestras financieras (Seed={args.seed})...")

    raw_samples = [generate_single_sample(i + 1) for i in range(args.num_samples)]
    random.shuffle(raw_samples)

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

        print(f"[MLOps - {fmt.upper()}] Dataset listo:")
        print(f"  -> Train: {train_path} ({len(train_raw)} filas, {train_size_kb:.1f} KB)")
        print(f"  -> Val:   {val_path} ({len(val_raw)} filas, {val_size_kb:.1f} KB)")

    print("[MLOps] Generación completada con éxito. Listo para pipeline de Fine-Tuning.")


if __name__ == "__main__":
    main()
