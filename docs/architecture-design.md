# Diseño de Arquitectura — Fin-AI Advisor

Este documento reúne los diagramas de arquitectura del monorepo. Cada diagrama va acompañado de una tabla de **estado de implementación** que distingue lo que existe hoy en el código de lo que forma parte de la arquitectura objetivo (roadmap).

| Leyenda | Significado |
|---|---|
| ✅ Implementado | Existe en el código y tiene pruebas |
| 🟡 Simulado | Existe la interfaz/clase, pero la lógica es un stub determinista (sin llamadas reales a LLM, BD o red) |
| ⬜ Objetivo | Parte de la arquitectura objetivo; aún no implementado |

Decisiones relacionadas: [ADR 001](adr/001-command-worker-pool-go.md) · [ADR 002](adr/002-strategy-pattern-ai-python.md)

---

## 1. Arquitectura General y Flujo de Transacciones

```mermaid
graph TD
    Client([Cliente / Web App]) --> API[API Gateway / Ingress]

    subgraph Go_Backend ["Portfolio API (Golang)"]
        Handler[HTTP Handler]
        Channel[[Go Channel en Memoria]]

        subgraph Worker_Pool ["Worker Pool (Control de Concurrencia)"]
            W1(Worker 1)
            W2(Worker 2)
            WN(Worker N)
        end
    end

    subgraph Database ["PostgreSQL"]
        Outbox[(Outbox / Estado PENDING)]
        Ledger[(Ledger Table)]
    end

    subgraph Python_AI ["AI Service (Python)"]
        AI_API[Router IA]
        Context{"Advisor Context<br/>(Strategy Pattern)"}
        Strategy(("Risk Evaluation<br/>Strategy"))
        S_OpenAI[OpenAI / LangChain]
        S_SageMaker[SageMaker / Fine-Tuned]
        S_Rule[Rule-Based Logic]
    end

    API --> Handler

    %% Patrón Outbox para durabilidad
    Handler -->|"1) Registro síncrono"| Outbox

    %% Patrón Command y Worker Pool
    Handler -->|"2) Encola Command"| Channel
    Channel --> W1
    Channel --> W2
    Channel --> WN

    %% Prevención de write-locks
    W1 -->|"3) Append-only insert"| Ledger
    W2 -->|"3) Append-only insert"| Ledger
    WN -.-> Ledger

    W1 -->|"4) Solicitud de evaluación"| AI_API
    AI_API --> Context
    Context -->|Inyecta estrategia| Strategy

    Strategy -.->|RAG| S_OpenAI
    Strategy -.->|Modelo local| S_SageMaker
    Strategy -.->|Fallback| S_Rule

    %% Estilos
    classDef go fill:#00ADD8,stroke:#005d73,stroke-width:2px,color:white;
    classDef python fill:#FFD43B,stroke:#306998,stroke-width:2px,color:black;
    classDef db fill:#336791,stroke:#234a68,stroke-width:2px,color:white;

    class Handler,Channel,W1,W2,WN go;
    class AI_API,Context,Strategy,S_OpenAI,S_SageMaker,S_Rule python;
    class Outbox,Ledger db;
```

| Componente | Estado | Ubicación |
|---|---|---|
| HTTP Handler (`POST /api/v1/orders/buy`, `/metrics`, `/health`) | ✅ | [`cmd/api/main.go`](../portfolio-api/cmd/api/main.go) |
| Go Channel con búfer + backpressure (HTTP 429) | ✅ | [`internal/engine/worker_pool.go`](../portfolio-api/internal/engine/worker_pool.go) |
| Worker Pool + semáforo de conexiones BD | ✅ | [`internal/engine/worker_pool.go`](../portfolio-api/internal/engine/worker_pool.go) |
| API Gateway / ALB | ⬜ | No provisionado en [`infra/main.tf`](../infra/main.tf) |
| Outbox (estado PENDING persistido) | ⬜ | La orden vive solo en memoria |
| Ledger append-only en PostgreSQL | ⬜ | La persistencia se simula con `time.Sleep` |
| Llamada Worker → AI Service | ⬜ | No existe cliente HTTP entre servicios |
| Router IA (API HTTP del servicio Python) | ⬜ | `ai-service` no expone endpoints |
| Advisor Context + Strategy | ✅ | [`ai-service/src/strategy.py`](../ai-service/src/strategy.py) |
| Estrategia OpenAI / LangChain (RAG) | 🟡 | `LangChainOpenAIStrategy` |
| Estrategia Fine-Tuned (SageMaker) | 🟡 | `FineTunedModelStrategy` (inferencia local simulada) |
| Estrategia Rule-Based (fallback) | ⬜ | Ver diagrama 4 |

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
        -quantity float64
        -price float64
        -status OrderStatus
        +Execute(ctx Context) error
        +Undo(ctx Context) error
        +ID() string
        +Status() OrderStatus
    }

    class SellOrder {
        <<planned>>
        -portfolioID string
        -symbol string
        -quantity float64
        +Execute(ctx Context) error
        +Undo(ctx Context) error
    }

    class WorkerPool {
        -taskQueue chan Command
        -dbConnSemaphore chan struct
        -workerCount int
        +Start(ctx Context)
        +Submit(cmd Command) error
        +SubmitWithTimeout(ctx, cmd, timeout) error
        +Shutdown(drainTimeout) error
        +Metrics() PoolMetrics
    }

    Command <|.. BuyOrder : Implementa
    Command <|.. SellOrder : Implementa
    WorkerPool o-- Command : Consume
```

| Componente | Estado | Ubicación |
|---|---|---|
| Interfaz `Command` + `BuyOrder` (máquina de estados PENDING → EXECUTED / FAILED → COMPENSATED) | ✅ | [`internal/domain/trade_command.go`](../portfolio-api/internal/domain/trade_command.go) |
| `SellOrder` | ⬜ | — |
| `WorkerPool` (Submit no bloqueante, compensación automática vía `Undo`) | ✅ | [`internal/engine/worker_pool.go`](../portfolio-api/internal/engine/worker_pool.go) |

---

## 3. Strategy Pattern: Abstracción de Modelos IA (Python)

```mermaid
classDiagram
    direction TB

    class AdvisorContext {
        -_strategy RiskEvaluationStrategy
        -_history list
        +set_strategy(strategy: RiskEvaluationStrategy)
        +evaluate_risk(profile: PortfolioProfile) RiskAssessmentResult
        +get_telemetry_history() list
    }

    class RiskEvaluationStrategy {
        <<abstract>>
        +evaluate(profile: PortfolioProfile) RiskAssessmentResult
        +strategy_name str
    }

    class LangChainOpenAIStrategy {
        +evaluate(profile: PortfolioProfile) RiskAssessmentResult
    }

    class FineTunedModelStrategy {
        +evaluate(profile: PortfolioProfile) RiskAssessmentResult
    }

    class FallbackRuleBasedStrategy {
        <<planned>>
        +evaluate(profile: PortfolioProfile) RiskAssessmentResult
    }

    AdvisorContext o-- RiskEvaluationStrategy : Delega la ejecución a
    RiskEvaluationStrategy <|-- LangChainOpenAIStrategy : Implementa
    RiskEvaluationStrategy <|-- FineTunedModelStrategy : Implementa
    RiskEvaluationStrategy <|-- FallbackRuleBasedStrategy : Implementa
```

| Componente | Estado | Ubicación |
|---|---|---|
| `RiskEvaluationStrategy` (ABC) + `AdvisorContext` con cambio en runtime y telemetría | ✅ | [`ai-service/src/strategy.py`](../ai-service/src/strategy.py) |
| `LangChainOpenAIStrategy` | 🟡 | Scoring determinista por tolerancia; no invoca LangChain ni OpenAI |
| `FineTunedModelStrategy` (destino: endpoint SageMaker) | 🟡 | VaR paramétrico calculado localmente |
| `FallbackRuleBasedStrategy` | ⬜ | — |
| Pipeline RAG de 4 nodos | 🟡 | [`ai-service/src/rag_graph.py`](../ai-service/src/rag_graph.py) — ejecución secuencial, documentos fijos |

---

## 4. Resiliencia: Circuit Breaker y Degradación Elegante

### 4.1 Flujo de peticiones

```mermaid
graph TD
    Request([Petición de Evaluación de Riesgo]) --> CB{"Circuit Breaker<br/>Middleware"}

    subgraph Estado_Cerrado ["Estado: CLOSED (Operación Normal)"]
        OAI[LangChain OpenAI Strategy]
        Response([Respuesta Exitosa])
        ErrorCounter[Aumenta Contador de Fallos]
    end

    subgraph Estado_Abierto ["Estado: OPEN (Fallo Rápido)"]
        OpenState(("Cambia a estado<br/>OPEN"))
        Fallback[Fallback Rule-Based Strategy]
        FallbackResponse([Respuesta Degradada pero Rápida])
    end

    HalfOpen(("Estado: HALF-OPEN<br/>Prueba de Tráfico"))

    CB -- Petición permitida --> OAI
    OAI -- 200 OK --> Response
    OAI -- 500 / Timeout --> ErrorCounter
    ErrorCounter -. Si fallos > umbral .-> OpenState

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
    CLOSED --> OPEN: Fallos consecutivos > umbral
    OPEN --> OPEN: Petición → Fallback Rule-Based
    OPEN --> HALF_OPEN: Expira timeout (30s)
    HALF_OPEN --> CLOSED: Petición de prueba exitosa
    HALF_OPEN --> OPEN: Petición de prueba falla
```

| Componente | Estado | Ubicación |
|---|---|---|
| Circuit Breaker middleware | ⬜ | — |
| Fallback Rule-Based | ⬜ | — |

Versión en inglés: [diagrams/circuit_breaker_en.md](diagrams/circuit_breaker_en.md)
