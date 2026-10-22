# Architecture Design — Fin-AI Advisor

This document collects the monorepo's architecture diagrams. Each diagram comes with an **implementation status** table that separates what exists in the code today from what belongs to the target architecture (roadmap).

| Legend | Meaning |
|---|---|
| ✅ Implemented | Exists in the code and is covered by tests |
| 🟡 Simulated | The interface/class with the real contract exists, but the logic is a deterministic stub |
| ⬜ Target | Part of the target architecture; not implemented yet |

Related decisions: [ADR 001](adr/001-command-worker-pool-go.md) · [ADR 002](adr/002-strategy-pattern-ai-python.md) · [ADR 003](adr/003-persistence-outbox-sqlite.md) · [ADR 004](adr/004-ai-advisory-guardrails-hitl-evals.md)

---

## 1. System Overview and Transaction Flow

The AI **proposes**; it never executes directly. Orders go through guardrails and, when required, human approval before reaching the transactional backend, which processes them durably and idempotently. LLM latency or availability never blocks the order execution path.

```mermaid
graph TD
    Client([Client / Advisor]) --> AI_API

    subgraph Python_AI ["AI Service (Python · FastAPI + LangGraph)"]
        AI_API[AI Router<br/>POST /v1/advice]
        Retrieve["Retrieve<br/>(multi-query RAG + RRF)"]
        Assess{"Advisor Context<br/>(Strategy + Circuit Breaker)"}
        S_LLM[LLM RAG<br/>Claude · structured output]
        S_SLM[Fine-Tuned SLM]
        S_Rule[Rule-Based<br/>fallback]
        Propose[Rebalancing<br/>BUY proposals]
        Guard{Guardrails}
        HITL[[Human Review<br/>interrupt + checkpointer]]
        Exec[Execute]
        Reject([Rejected])
    end

    subgraph Go_Backend ["Portfolio API (Golang)"]
        Handler["HTTP Handler<br/>Idempotency-Key"]
        Channel[[Buffered Go channel]]
        Relay[Outbox Relay]
        subgraph Worker_Pool ["Worker Pool"]
            W1(Worker 1)
            WN(Worker N)
        end
    end

    subgraph Database ["SQLite → PostgreSQL in prod"]
        Orders[(orders)]
        Outbox[(outbox)]
        Ledger[(append-only ledger)]
    end

    AI_API --> Retrieve --> Assess
    Assess -->|primary| S_LLM
    Assess -.->|alternative| S_SLM
    Assess -.->|circuit open| S_Rule
    Assess --> Propose --> Guard
    Guard -->|blocking violation| Reject
    Guard -->|needs review| HITL
    Guard -->|clean| Exec
    HITL -->|approved| Exec
    HITL -->|rejected| Reject

    Exec -->|"POST /orders/buy<br/>Idempotency-Key = thread:i:symbol"| Handler
    Handler -->|"1) tx: order + event"| Orders
    Handler --> Outbox
    Handler -->|"2) fast dispatch"| Channel
    Relay -->|re-dispatch| Channel
    Outbox -.-> Relay
    Channel --> W1
    Channel --> WN
    W1 -->|"3) CAS claim + entries"| Ledger
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

| Component | Status | Location |
|---|---|---|
| AI Router (FastAPI: advice, authenticated review, metrics, health) | ✅ | [`ai-service/src/api.py`](../ai-service/src/api.py) |
| LangGraph graph with conditional routing and human-in-the-loop | ✅ | [`ai-service/src/graph.py`](../ai-service/src/graph.py) |
| Multi-query RAG with Reciprocal Rank Fusion and per-chunk citations | ✅ | [`ai-service/src/retrieval.py`](../ai-service/src/retrieval.py). Deterministic TF-IDF; dense embeddings + pgvector in production |
| Guardrails (groundedness, suitability, funding, review triggers, insufficient context) | ✅ | [`ai-service/src/guardrails.py`](../ai-service/src/guardrails.py) |
| Reviewer authentication, four-eyes, rate limiting | ✅ | [`ai-service/src/api.py`](../ai-service/src/api.py) |
| Idempotent AI → Go execution | ✅ | `PortfolioApiExecutor` in [`graph.py`](../ai-service/src/graph.py) (DryRun by default) |
| HTTP Handler (`POST /orders/buy` with `Idempotency-Key`, `GET /orders/{id}`, `GET /portfolios/{id}/positions`) | ✅ | [`internal/httpapi/handler.go`](../portfolio-api/internal/httpapi/handler.go) |
| Buffered Go channel + backpressure (HTTP 429) | ✅ | [`internal/engine/worker_pool.go`](../portfolio-api/internal/engine/worker_pool.go) |
| Transactional outbox + recovery relay | ✅ | [`internal/store`](../portfolio-api/internal/store/store.go), [`internal/orders/relay.go`](../portfolio-api/internal/orders/relay.go) ([ADR 003](adr/003-persistence-outbox-sqlite.md)) |
| Append-only ledger (triggers block UPDATE/DELETE) | ✅ | [`migrations/001_init.sql`](../portfolio-api/internal/store/migrations/001_init.sql) |
| Compare-and-set claim (at-most-once execution) | ✅ | `store.ClaimOrder` + decorator [`orders/persistent_order.go`](../portfolio-api/internal/orders/persistent_order.go) |
| Persistent checkpointer (Postgres/Redis) for long-running reviews | ⬜ | `MemorySaver` today; state is already JSON-serializable |
| API Gateway / ALB | ⬜ | Not provisioned in [`infra/main.tf`](../infra/main.tf) |

---

## 2. Command Pattern: Order Encapsulation (Golang)

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

    Command <|.. BuyOrder : implements
    Command <|.. persistentOrder : implements
    Command <|.. SellOrder : implements
    persistentOrder o-- BuyOrder : wraps
    WorkerPool o-- Command : consumes
```

| Component | Status | Location |
|---|---|---|
| `Command` interface + `BuyOrder` (two-step saga: reserve → settle; idempotent `Undo`) | ✅ | [`internal/domain/trade_command.go`](../portfolio-api/internal/domain/trade_command.go) |
| Persistence decorator (CAS claim, ledger, compensation) | ✅ | [`internal/orders/persistent_order.go`](../portfolio-api/internal/orders/persistent_order.go) |
| `WorkerPool` (non-blocking submit, lossless graceful drain, duplicate-delivery discard) | ✅ | [`internal/engine/worker_pool.go`](../portfolio-api/internal/engine/worker_pool.go) |
| `SellOrder` | ⬜ | — |

---

## 3. Strategy Pattern: AI Model Abstraction (Python)

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

    AdvisorContext o-- RiskEvaluationStrategy : delegates to
    RiskEvaluationStrategy <|-- LLMRagStrategy
    RiskEvaluationStrategy <|-- FineTunedModelStrategy
    RiskEvaluationStrategy <|-- RuleBasedStrategy
    RiskEvaluationStrategy <|-- ResilientRiskStrategy
    ResilientRiskStrategy o-- RiskEvaluationStrategy : primary / fallback
    LLMRagStrategy o-- LLMClient : FakeLLMClient · AnthropicLLMClient
```

| Component | Status | Location |
|---|---|---|
| `RiskEvaluationStrategy` + `AdvisorContext` (runtime switching, telemetry) | ✅ | [`ai-service/src/strategy.py`](../ai-service/src/strategy.py) |
| Quant core (correlation-aware volatility, parametric VaR with √t scaling) | ✅ | `compute_portfolio_metrics`: numbers are computed by code, never by the LLM |
| `LLMRagStrategy` with schema-validated output (Pydantic) and prompt versioning | ✅ | Claude (`claude-opus-5-5`, `messages.parse`) with `LLM_PROVIDER=anthropic`; deterministic fake in CI |
| `RuleBasedStrategy` (fallback) | ✅ | Always available, no external dependencies |
| `FineTunedModelStrategy` | 🟡 | Real contract; simulated inference. Distilled dataset in [`scripts/generate_finetuning_dataset.py`](../ai-service/scripts/generate_finetuning_dataset.py) |

---

## 4. Resilience: Circuit Breaker and Graceful Degradation

### 4.1 Request flow

```mermaid
graph TD
    Request([Risk Evaluation Request]) --> CB{"Circuit Breaker<br/>Middleware"}

    subgraph Closed_State ["State: CLOSED (Normal Operation)"]
        OAI[LLM RAG Strategy]
        Response([Successful Response])
        ErrorCounter[Increment Failure Counter]
    end

    subgraph Open_State ["State: OPEN (Fail Fast)"]
        OpenState(("Switch to<br/>OPEN state"))
        Fallback[Rule-Based Strategy]
        FallbackResponse(["Degraded response<br/>→ human review"])
    end

    HalfOpen(("State: HALF-OPEN<br/>Probe Traffic"))

    CB -- Request allowed --> OAI
    OAI -- 200 OK --> Response
    OAI -- 500 / timeout / invalid output --> ErrorCounter
    ErrorCounter -. failures >= threshold .-> OpenState

    OpenState -. Activates .-> CB
    CB -- Intercepts request --> Fallback
    Fallback --> FallbackResponse

    OpenState -. After 30s .-> HalfOpen
    HalfOpen -. Probe succeeds: back to CLOSED .-> OAI
    HalfOpen -. Probe fails: stay OPEN .-> OpenState

    classDef closed fill:#d4edda,stroke:#28a745,color:#155724;
    classDef open fill:#f8d7da,stroke:#dc3545,color:#721c24;
    classDef warning fill:#fff3cd,stroke:#ffc107,color:#856404;

    class OAI,Response closed;
    class OpenState,Fallback,FallbackResponse open;
    class HalfOpen warning;
```

### 4.2 State machine

```mermaid
stateDiagram-v2
    [*] --> CLOSED
    CLOSED --> CLOSED: Success (reset counter)
    CLOSED --> OPEN: Failures >= threshold
    OPEN --> OPEN: Request → rule-based fallback
    OPEN --> HALF_OPEN: Timeout expires (30s)
    HALF_OPEN --> CLOSED: Probe request succeeds
    HALF_OPEN --> OPEN: Probe request fails
```

| Component | Status | Location |
|---|---|---|
| Circuit breaker (CLOSED / OPEN / HALF_OPEN, injectable clock for tests) | ✅ | [`ai-service/src/resilience.py`](../ai-service/src/resilience.py) |
| Rule-based fallback flagged `degraded` → mandatory human review | ✅ | `ResilientRiskStrategy` + rule in [`guardrails.py`](../ai-service/src/guardrails.py) |

---

## 5. Offline Evaluation (AI Quality Gate)

| Metric | What it measures | CI threshold |
|---|---|---|
| `route_accuracy` | The graph reaches the expected state (execute / review / reject) | 1.00 |
| `retrieval_recall` | Required documents are present in the retrieved context | ≥ 0.90 |
| `groundedness` | Every citation belongs to a retrieved chunk | 1.00 |
| `policy_compliance` | No forbidden asset class in the recommendation | 1.00 |
| `guardrail_catch_rate` | Adversarial cases (hallucination, unsuitable advice, outage, prompt injection) are neutralized | 1.00 |

Golden set: [`ai-service/evals/golden_set.json`](../ai-service/evals/golden_set.json). Runner: [`ai-service/evals/run_evals.py`](../ai-service/evals/run_evals.py). Details: [`ai-service/evals/README.md`](../ai-service/evals/README.md).

Standalone circuit breaker diagram: [diagrams/circuit_breaker_en.md](diagrams/circuit_breaker_en.md)
