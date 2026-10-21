# ADR 002: Implementación de Strategy Pattern para Evaluación de Riesgo en el Servicio AI

## Estado
Aprobado

## Fecha
2026-10-21

## Contexto del Negocio y Técnico
El servicio de inteligencia artificial (`ai-service`) de `fin-ai-advisor` es responsable de evaluar perfiles de inversión, tolerancias al riesgo y adecuación de carteras financieras ante cambios macroeconómicos y regulatorios.

Los requisitos funcionales y no funcionales imponen:
1. **Modelos Heterogéneos según Caso de Uso:**
   - Para clientes con portafolios complejos y necesidades cualitativas explicables: Se requiere un flujo RAG (*Retrieval-Augmented Generation*) orquestado con LangChain y OpenAI / Anthropic que consulte reportes de mercado (10-K, noticias, tasas de bancos centrales).
   - Para evaluación en tiempo real de alta frecuencia o entornos con restricciones de privacidad de datos (on-premise / VPC air-gapped): Se requiere un modelo Transformer dedicado y ajustado (*Fine-Tuned Small Language Model* / SLM, como LLaMA-3 o Mistral cuantizado) con latencia predecible (<50ms).
2. **Intercambiabilidad en Tiempo de Ejecución (Runtime Flexibility):** El motor asesor debe poder conmutar de estrategia dinámicamente según la clasificación de la cuenta, SLA del usuario, disponibilidad de cuota de API externa o modo de contingencia (*fallback*).
3. **Mantenibilidad y Principio Open/Closed:** Incorporar nuevos proveedores o arquitecturas de IA no debe alterar la lógica de negocio del asesor de carteras.

## Decisión Arquitectónica
Adoptamos el **Strategy Pattern** en Python 3.11+, siguiendo las directrices de [Refactoring.Guru: Strategy Pattern](https://refactoring.guru/design-patterns/strategy).

### 1. Interfaz de Estrategia (`ai-service/src/strategy.py`)
- Clase base abstracta `RiskEvaluationStrategy` que define el contrato:
  ```python
  class RiskEvaluationStrategy(ABC):
      @abstractmethod
      def evaluate(self, profile: PortfolioProfile) -> RiskAssessmentResult:
          pass
  ```
- Tipado estricto con `Pydantic` / `dataclasses` para entradas (`PortfolioProfile`) y salidas (`RiskAssessmentResult`), garantizando validación de esquemas en tiempo de ejecución.

### 2. Estrategias Concretas
- `LangChainOpenAIStrategy`:
  - Simula la recuperación aumentada de contexto financiero (RAG) consultando bases de conocimiento vectoriales (pgvector / FAISS).
  - Produce análisis cualitativos ricos, justificaciones regulatorias y scoring de riesgo con alta explicabilidad.
- `FineTunedModelStrategy`:
  - Simula la inferencia sobre un modelo financiero local/dedicado entrenado para clasificación de riesgo y Value-at-Risk (VaR).
  - Prioriza velocidad de inferencia determinista y soberanía de datos sin llamadas externas.

### 3. Contexto (`AdvisorContext`)
- Mantiene una referencia a la estrategia activa.
- Permite inyectar la estrategia en el constructor o sustituirla dinámicamente mediante `set_strategy()`.
- Proporciona telemetría unificada (tiempo de inferencia, métricas de confianza, estrategia utilizada).

### 4. Orquestación RAG con LangGraph (`ai-service/src/rag_graph.py`)
- Complementa la estrategia RAG mediante un grafo de estados cíclico/acíclico (`StateGraph`), orquestando la recuperación de documentos, análisis de sentimiento de mercado y síntesis de recomendación.

## Consecuencias y Compensaciones (Trade-offs)

### Positivas (+)
- **Principio Abierto/Cerrado (OCP):** Es trivial añadir `ClaudeBedrockStrategy` o `DeepSeekLocalStrategy` sin modificar `AdvisorContext`.
- **Aislamiento de Pruebas (Testability):** Permite inyectar estrategias simuladas (*mock strategies*) en pruebas unitarias de CI/CD sin incurrir en costos de tokens ni latencia externa.
- **Resiliencia Operativa:** Si la API externa de OpenAI experimenta degradación, el sistema conmuta automáticamente a la estrategia de modelo fine-tuned local (*circuit breaker* / *graceful degradation*).

### Negativas / Mitigaciones (-)
- **Normalización de Salidas:** Modelos distintos pueden generar distribuciones de puntuación dispares. *Mitigación:* Se implementa un esquema estricto `RiskAssessmentResult` con normalización de escala (0.0 a 1.0) y calibración estadística.

## Referencias
- Refactoring Guru: Strategy Design Pattern (<https://refactoring.guru/design-patterns/strategy>)
- LangGraph Documentation: Stateful Multi-Actor Applications with LLMs
- PEP 544 – Protocols: Structural subtyping (static duck typing)
