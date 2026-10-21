# ADR 004: Asesoría con IA — Workflow LangGraph, Guardrails, Human-in-the-Loop y Evaluación Offline

## Estado
Aprobado

## Fecha
2026-10-21

## Contexto
El servicio de IA genera recomendaciones de rebalanceo que terminan convertidas en órdenes reales. En un dominio regulado (asesoría financiera) esto plantea riesgos que un prototipo "LLM + prompt" no cubre:

1. **Alucinaciones:** el modelo puede inventar fuentes o cifras.
2. **Suitability:** una recomendación técnicamente coherente puede ser inadecuada para el perfil del cliente (p. ej. cripto para un perfil conservador).
3. **Agencia excesiva:** un LLM no debe poder mover dinero por sí solo.
4. **Disponibilidad:** el proveedor del LLM puede degradarse o fallar.
5. **Regresiones silenciosas:** un cambio de prompt, modelo o retriever puede empeorar la calidad sin que ningún test unitario falle.

## Decisión

### 1. Workflow determinista, no agente autónomo
La orquestación es un `StateGraph` de LangGraph con nodos y aristas explícitos (`retrieve → assess → propose → guardrails → {reject | human_review | execute}`). El LLM participa en **un solo nodo** (evaluación) y no decide el flujo. Un agente autónomo con herramientas no se justifica: los pasos son conocidos de antemano y el costo de un error es alto.

### 2. "El LLM explica, el código calcula"
La volatilidad, el VaR (paramétrico, escalado con √t) y la concentración se calculan en un núcleo cuantitativo determinista. El LLM recibe esas cifras como contexto y devuelve una opinión **estructurada** (`LLMRiskOpinion`, validada con Pydantic; con Claude se usa `messages.parse` con `output_format`). Cualquier salida que no cumpla el esquema cuenta como fallo.

### 3. RAG con citas verificables
La base de conocimiento se divide en chunks con un `chunk_id` estable. La recuperación usa **multi-query + Reciprocal Rank Fusion**: una sub-consulta por cada preocupación del perfil, porque concatenarlas diluía la señal (defecto detectado por los evals). El modelo debe citar `chunk_id`s, y los guardrails verifican que cada cita haya sido efectivamente recuperada (*groundedness*).

### 4. Guardrails en dos niveles
- **Bloqueantes** (la recomendación se rechaza): citas alucinadas, asignación que no suma 1, cripto para perfiles no aptos o por encima del 5%, nivel de riesgo que contradice la tolerancia declarada, compras sin fondos.
- **Revisión humana** (se pausa el grafo): risk score ≥ 0.70, operación > 10% del AUM, concentración > 20% en un valor individual, resultado degradado.

### 5. Human-in-the-loop con `interrupt()`
El nodo `human_review` pausa el grafo y persiste el estado en el checkpointer. Un asesor aprueba o rechaza vía `POST /v1/advice/{id}/review`, y el grafo se reanuda con `Command(resume=...)`. Hoy el checkpointer es `MemorySaver`; el estado es JSON puro, así que migrar a un checkpointer en Postgres no requiere cambios de modelo.

### 6. Resiliencia
`ResilientRiskStrategy` (Decorator) envuelve la estrategia LLM con un circuit breaker (CLOSED → OPEN → HALF_OPEN). Con el circuito abierto se responde con la estrategia rule-based. El resultado queda marcado como `degraded`, lo que obliga a revisión humana: la disponibilidad nunca se compra a costa del control.

### 7. Ejecución idempotente entre servicios
El nodo `execute` envía las órdenes a `portfolio-api` con `Idempotency-Key = <thread_id>:<i>:<symbol>`. Si el grafo se reintenta o se reanuda dos veces, el backend devuelve la orden original en lugar de duplicarla (ver [ADR 003](003-persistence-outbox-sqlite.md)).

### 8. Evaluación offline como quality gate
Un golden set con casos normales y **adversariales** (citas alucinadas, recomendación no apta, caída del proveedor) corre en CI. Mide *route accuracy*, *retrieval recall*, *groundedness*, *policy compliance*, *guardrail catch rate* y latencia p95, y el pipeline falla si alguna métrica baja de su umbral. Por defecto usa un LLM fake determinista (costo cero, reproducible); con `LLM_PROVIDER=anthropic` evalúa el modelo real.

### 9. Dataset de fine-tuning destilado
Las etiquetas del dataset sintético provienen de aplicar el pipeline cuantitativo (modelo maestro) a cada cartera generada, en lugar de una tabla fija por arquetipo, que solo enseñaría a memorizar el arquetipo. Un quality gate en CI exige cero duplicados y variabilidad de etiquetas dentro de cada arquetipo.

## Consecuencias

### Positivas (+)
- Cada riesgo del contexto tiene un control verificable y un caso en el golden set que lo demuestra.
- Los tests y evals corren sin red ni costo; cambiar de proveedor de LLM solo requiere implementar `LLMClient`.
- Los defectos de calidad se detectan antes del merge, no en producción. La primera ejecución de los evals encontró dos bugs reales: dilución de la consulta y ETFs amplios contados como concentración.

### Negativas / Mitigaciones (-)
- **El fake LLM no mide la calidad del modelo real:** mide el sistema alrededor del modelo. *Mitigación:* el mismo harness corre con Claude bajo demanda (con costo) antes de cambiar de modelo o de prompt.
- **TF-IDF no captura sinónimos:** *Mitigación:* la interfaz `Embedder` permite usar embeddings densos y pgvector en producción, validados con el mismo golden set.
- **Golden set pequeño (8 casos):** suficiente como gate de regresión, no como medida estadística. *Mitigación:* ampliarlo con casos reales anonimizados y con revisiones humanas como etiquetas.
- **`MemorySaver` pierde las revisiones pendientes al reiniciar:** *Mitigación:* checkpointer persistente (Postgres) antes de producción.
