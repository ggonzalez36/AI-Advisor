# Financial AI Advisor Service (ai-service)

Microservicio de inteligencia artificial cuantitativa y RAG orquestado con LangGraph y Python 3.11+.

## Componentes
- `src/strategy.py`: Implementación del patrón Strategy para evaluación de riesgo y asignación de activos.
- `src/rag_graph.py`: Flujo RAG con LangGraph para recuperación de inteligencia de mercado y propuesta de rebalanceos.
- `scripts/generate_finetuning_dataset.py`: Generador de datasets para fine-tuning MLOps (formatos OpenAI y Alpaca).
