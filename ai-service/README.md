# Financial AI Advisor Service (ai-service)

Quantitative AI microservice and RAG orchestration using LangGraph, Python 3.11+, and MLOps.

## Architecture & Components
- `src/strategy.py`: Strategy Pattern implementation for dynamic risk evaluation and asset allocation across LLM RAG and quantized local SLMs.
- `src/rag_graph.py`: LangGraph stateful workflow orchestrating macroeconomic intelligence retrieval, financial signal extraction, and trade rebalancing recommendations.
- `scripts/generate_finetuning_dataset.py`: MLOps synthetic dataset generation utility exporting to OpenAI Chat JSONL and Alpaca/HuggingFace formats.
- `tests/`: Automated unit and integration test suite using Pytest.

## Getting Started
```bash
# Check code style with Ruff
uv run --with ruff ruff check .
uv run --with ruff ruff format --check .

# Run test suite
uv run --with pytest pytest -v

# Generate fine-tuning datasets
uv run python scripts/generate_finetuning_dataset.py --num-samples 100 --output-dir data/finetuning --format both
```
