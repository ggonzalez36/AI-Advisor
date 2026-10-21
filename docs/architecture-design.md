# Diseño de Arquitectura — Fin-AI Advisor

Este documento reúne los diagramas de arquitectura del monorepo. Cada diagrama va acompañado de una tabla de **estado de implementación** que distingue lo que existe hoy en el código de lo que forma parte de la arquitectura objetivo (roadmap).

| Leyenda | Significado |
|---|---|
| ✅ Implementado | Existe en el código y tiene pruebas |
| 🟡 Simulado | Existe la interfaz/clase con el contrato real, pero la lógica es un stub determinista |
| ⬜ Objetivo | Parte de la arquitectura objetivo; aún no implementado |

Decisiones relacionadas: [ADR 001](adr/001-command-worker-pool-go.md) · [ADR 002](adr/002-strategy-pattern-ai-python.md) · [ADR 003](adr/003-persistence-outbox-sqlite.md) · [ADR 004](adr/004-ai-advisory-guardrails-hitl-evals.md)

---

## 1. Arquitectura General y Flujo de Transacciones

La IA **propone** y nunca ejecuta directamente. Las órdenes pasan por guardrails y, cuando corresponde, por aprobación humana, antes de llegar al backend transaccional. Este las procesa de forma durable e idempotente. La latencia y la disponibilidad del LLM nunca bloquean el camino de ejecución de órdenes.

```mermaid
graph TD
    Client([Cliente / Asesor]) --> AI_API

    subgraph Python_AI ["AI Service (Python · FastAPI + LangGraph)"]
        AI_API[Router IA<br/>POST /v1/advice]
        Retrieve["Retrieve<br/>(multi-query RAG + RRF)"]
        Assess{"Advisor Context<br/>(Strategy + Circuit Breaker)"}
        S_LLM[LLM RAG<br/>Claude · salida estructurada]
        S_SLM[Fine-Tuned SLM]
        S_Rule[Rule-Based<br/>fallback]
        Propose[Rebalanceo<br/>propuestas BUY]
        Guard{Guardrails}
        HITL[[Human Review<br/>interrupt + checkpointer]]
        Exec[Execute]
        Reject([Rechazada])
    end

    subgraph Go_Backend ["Portfolio API (Golang)"]
        Handler["HTTP Handler<br/>Idempotency-Key"]
        Channel[[Go Channel con búfer]]
        Relay[Outbox Relay]
        subgraph Worker_Pool ["Worker Pool"]
            W1(Worker 1)
            WN(Worker N)
        end
    end

    subgraph Database ["SQLite → PostgreSQL en prod"]
        Orders[(orders)]
        Outbox[(outbox)]
        Ledger[(ledger append-only)]
    end

    AI_API --> Retrieve --> Assess
    Assess -->|primaria| S_LLM
    Assess -.->|alternativa| S_SLM
    Assess -.->|circuito abierto| S_Rule
    Assess --> Propose --> Guard
    Guard -->|violación bloqueante| Reject
    Guard -->|requiere revisión| HITL
    Guard -->|limpio| Exec
    HITL -->|aprobada| Exec
    HITL -->|rechazada| Reject

    Exec -->|"POST /orders/buy<br/>Idempotency-Key = thread:i:symbol"| Handler
    Handler -->|"1) tx: orden + evento"| Orders
    Handler --> Outbox
    Handler -->|"2) despacho rápido"| Channel
    Relay -->|re-despacho| Channel
    Outbox -.-> Relay
    Channel --> W1
    Channel --> WN
    W1 -->|"3) claim CAS + asientos"| Ledger
    WN --> Ledger

    classDef go fill:#00ADD8,stroke:#005d73,stroke-width:2px,color:white;
    classDef python fill:#FFD43B,stroke:#306998,stroke-width:2px,color:black;
    classDef db fill:#336791,stroke:#234a68,stroke-width:2px,color:white;
    classDef human fill:#e8d5f5,stroke:#7b3fa0,stroke-width:2px,color:black;

    class Handler,Channel,Relay,W1,WN go;
    class AI_API,Retrieve,Assess,S_LLM,S_SLM,S_Rule,Propose,Guard,Exec python;
    class Orders,Outbox,Ledger db;
    class HITL human;
```

| Componente | Estado | Ubicación |
|---|---|---|
| Router IA (FastAPI: advice, review, health) | ✅ | [`ai-service/src/api.py`](../ai-service/src/api.py) |
| Grafo LangGraph con routing condicional y human-in-the-loop | ✅ | [`ai-service/src/graph.py`](../ai-service/src/graph.py) |
| RAG multi-query con Reciprocal Rank Fusion y citas por chunk | ✅ | [`ai-service/src/retrieval.py`](../ai-service/src/retrieval.py) — TF-IDF determinista; embeddings densos + pgvector en prod |
| Guardrails (groundedness, suitability, financiamiento, revisión) | ✅ | [`ai-service/src/guardrails.py`](../ai-service/src/guardrails.py) |
| Ejecución idempotente AI → Go | ✅ | `PortfolioApiExecutor` en [`graph.py`](../ai-service/src/graph.py) (DryRun por defecto) |
| HTTP Handler (`POST /orders/buy` con `Idempotency-Key`, `GET /orders/{id}`, `GET /portfolios/{id}/positions`) | ✅ | [`internal/httpapi/handler.go`](../portfolio-api/internal/httpapi/handler.go) |
| Go Channel con búfer + backpressure (HTTP 429) | ✅ | [`internal/engine/worker_pool.go`](../portfolio-api/internal/engine/worker_pool.go) |
| Outbox transaccional + relay de recuperación | ✅ | [`internal/store`](../portfolio-api/internal/store/store.go), [`internal/orders/relay.go`](../portfolio-api/internal/orders/relay.go) ([ADR 003](adr/003-persistence-outbox-sqlite.md)) |
| Ledger append-only (triggers anti UPDATE/DELETE) | ✅ | [`migrations/001_init.sql`](../portfolio-api/internal/store/migrations/001_init.sql) |
| Claim compare-and-set (ejecución at-most-once) | ✅ | `store.ClaimOrder` + decorator [`orders/persistent_order.go`](../portfolio-api/internal/orders/persistent_order.go) |
| Checkpointer persistente (Postgres/Redis) para revisiones de larga duración | ⬜ | Hoy `MemorySaver`; el estado ya es JSON-serializable |
| API Gateway / ALB | ⬜ | No provisionado en [`infra/main.tf`](../infra/main.tf) |

---

## 2. Command Pattern: Encapsulación de Órdenes (Golang)

```mermaid
classDiagram
    direction TB

    class Command {
        <<interface>>
        +Execute(ctx Context) error
        +Undo(ctx Context) error
        +ID() string
        +Status() OrderStatus
    }

    class BuyOrder {
        -id string
        -portfolioID string
        -symbol string
        -quantity int64
        -priceCents int64
        -status OrderStatus
        -fundsReserved bool
        +Execute(ctx Context) error
        +Undo(ctx Context) error
    }

    class persistentOrder {
        <<decorator>>
        -inner BuyOrder
        -repo Repository
        +Execute(ctx Context) error
        +Undo(ctx Context) error
    }

    class SellOrder {
        <<planned>>
        +Execute(ctx Context) error
        +Undo(ctx Context) error
    }

    class WorkerPool {
        -taskQueue chan Command
        -dbConnSemaphore chan struct
        -queueMu RWMutex
        +Start(ctx Context)
        +Submit(cmd Command) error
        +SubmitWithTimeout(ctx, cmd, timeout) error
        +Shutdown(drainTimeout) error
        +Metrics() PoolMetrics
    }

    Command <|.. BuyOrder : Implementa
    Command <|.. persistentOrder : Implementa
    Command <|.. SellOrder : Implementa
    persistentOrder o-- BuyOrder : Envuelve
    WorkerPool o-- Command : Consume
```

| Componente | Estado | Ubicación |
|---|---|---|
| Interfaz `Command` + `BuyOrder` (Saga de dos pasos: reserva → liquidación; `Undo` idempotente) | ✅ | [`internal/domain/trade_command.go`](../portfolio-api/internal/domain/trade_command.go) |
| Decorator de persistencia (claim CAS, ledger, compensación) | ✅ | [`internal/orders/persistent_order.go`](../portfolio-api/internal/orders/persistent_order.go) |
| `WorkerPool` (Submit no bloqueante, drenado ordenado sin pérdida, descarte de duplicados) | ✅ | [`internal/engine/worker_pool.go`](../portfolio-api/internal/engine/worker_pool.go) |
| `SellOrder` | ⬜ | — |

---

## 3. Strategy Pattern: Abstracción de Modelos IA (Python)

```mermaid
classDiagram
    direction TB

    class AdvisorContext {
        -_strategy RiskEvaluationStrategy
        +set_strategy(strategy)
        +evaluate_risk(profile, context) RiskAssessmentResult
        +get_telemetry_history() list
    }

    class RiskEvaluationStrategy {
        <<abstract>>
        +evaluate(profile, context) RiskAssessmentResult
        +strategy_name str
    }

    class LLMRagStrategy {
        -llm LLMClient
        +evaluate(profile, context) RiskAssessmentResult
    }

    class FineTunedModelStrategy {
        +evaluate(profile, context) RiskAssessmentResult
    }

    class RuleBasedStrategy {
        +evaluate(profile, context) RiskAssessmentResult
    }

    class ResilientRiskStrategy {
        <<decorator>>
        -primary RiskEvaluationStrategy
        -fallback RiskEvaluationStrategy
        -breaker CircuitBreaker
        +evaluate(profile, context) RiskAssessmentResult
    }

    class LLMClient {
        <<protocol>>
        +generate(system, user, response_model, context) BaseModel
    }

    AdvisorContext o-- RiskEvaluationStrategy : Delega en
    RiskEvaluationStrategy <|-- LLMRagStrategy
    RiskEvaluationStrategy <|-- FineTunedModelStrategy
    RiskEvaluationStrategy <|-- RuleBasedStrategy
    RiskEvaluationStrategy <|-- ResilientRiskStrategy
    ResilientRiskStrategy o-- RiskEvaluationStrategy : primaria / fallback
    LLMRagStrategy o-- LLMClient : FakeLLMClient · AnthropicLLMClient
```

| Componente | Estado | Ubicación |
|---|---|---|
| `RiskEvaluationStrategy` + `AdvisorContext` (cambio en runtime, telemetría) | ✅ | [`ai-service/src/strategy.py`](../ai-service/src/strategy.py) |
| Núcleo cuantitativo (volatilidad con correlaciones, VaR paramétrico √t) | ✅ | `compute_portfolio_metrics`: las cifras las calcula el código, nunca el LLM |
| `LLMRagStrategy` con salida estructurada validada (Pydantic) | ✅ | Claude (`claude-opus-5-5`, `messages.parse`) con `LLM_PROVIDER=anthropic`; fake determinista en CI |
| `RuleBasedStrategy` (fallback) | ✅ | Siempre disponible, sin dependencias externas |
| `FineTunedModelStrategy` | 🟡 | Contrato real; inferencia simulada. Dataset destilado en [`scripts/generate_finetuning_dataset.py`](../ai-service/scripts/generate_finetuning_dataset.py) |

---

## 4. Resiliencia: Circuit Breaker y Degradación Elegante

### 4.1 Flujo de peticiones

```mermaid
graph TD
    Request([Petición de Evaluación de Riesgo]) --> CB{"Circuit Breaker<br/>Middleware"}

    subgraph Estado_Cerrado ["Estado: CLOSED (Operación Normal)"]
        OAI[LLM RAG Strategy]
        Response([Respuesta Exitosa])
        ErrorCounter[Aumenta Contador de Fallos]
    end

    subgraph Estado_Abierto ["Estado: OPEN (Fallo Rápido)"]
        OpenState(("Cambia a estado<br/>OPEN"))
        Fallback[Rule-Based Strategy]
        FallbackResponse(["Respuesta degradada<br/>→ revisión humana"])
    end

    HalfOpen(("Estado: HALF-OPEN<br/>Prueba de Tráfico"))

    CB -- Petición permitida --> OAI
    OAI -- 200 OK --> Response
    OAI -- 500 / Timeout / salida inválida --> ErrorCounter
    ErrorCounter -. Si fallos >= umbral .-> OpenState

    OpenState -. Activa .-> CB
    CB -- Intercepta petición --> Fallback
    Fallback --> FallbackResponse

    %% Transición de recuperación
    OpenState -. Después de 30s .-> HalfOpen
    HalfOpen -. Prueba exitosa: vuelve a CLOSED .-> OAI
    HalfOpen -. Prueba falla: mantiene OPEN .-> OpenState

    classDef closed fill:#d4edda,stroke:#28a745,color:#155724;
    classDef open fill:#f8d7da,stroke:#dc3545,color:#721c24;
    classDef warning fill:#fff3cd,stroke:#ffc107,color:#856404;

    class OAI,Response closed;
    class OpenState,Fallback,FallbackResponse open;
    class HalfOpen warning;
```

### 4.2 Máquina de estados

```mermaid
stateDiagram-v2
    [*] --> CLOSED
    CLOSED --> CLOSED: Éxito (reinicia contador)
    CLOSED --> OPEN: Fallos >= umbral
    OPEN --> OPEN: Petición → Fallback Rule-Based
    OPEN --> HALF_OPEN: Expira timeout (30s)
    HALF_OPEN --> CLOSED: Petición de prueba exitosa
    HALF_OPEN --> OPEN: Petición de prueba falla
```

| Componente | Estado | Ubicación |
|---|---|---|
| Circuit Breaker (CLOSED / OPEN / HALF_OPEN, reloj inyectable para tests) | ✅ | [`ai-service/src/resilience.py`](../ai-service/src/resilience.py) |
| Fallback Rule-Based con marca `degraded` → revisión humana obligatoria | ✅ | `ResilientRiskStrategy` + regla en [`guardrails.py`](../ai-service/src/guardrails.py) |

---

## 5. Evaluación Offline (Quality Gate de IA)

| Métrica | Qué mide | Umbral en CI |
|---|---|---|
| `route_accuracy` | El grafo llega al estado esperado (ejecutar / revisar / rechazar) | 1.00 |
| `retrieval_recall` | Documentos requeridos presentes en el contexto recuperado | ≥ 0.90 |
| `groundedness` | Todas las citas corresponden a chunks recuperados | 1.00 |
| `policy_compliance` | Ninguna clase de activo prohibida en la recomendación | 1.00 |
| `guardrail_catch_rate` | Casos adversariales (alucinación, recomendación no apta, caída) neutralizados | 1.00 |

Golden set: [`ai-service/evals/golden_set.json`](../ai-service/evals/golden_set.json). Runner: [`ai-service/evals/run_evals.py`](../ai-service/evals/run_evals.py).

Versión en inglés del circuit breaker: [diagrams/circuit_breaker_en.md](diagrams/circuit_breaker_en.md)
