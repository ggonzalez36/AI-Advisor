# Diagrams — Fin-AI Advisor

Every architecture diagram of the monorepo in one place. Each section says what is implemented today and what belongs to the target architecture.

| Legend | Meaning |
|---|---|
| ✅ Implemented | Exists in the code and is covered by tests |
| 🟡 Simulated | The real contract exists, but the logic is a deterministic stub |
| ⬜ Target | Part of the target architecture; not implemented yet |

| # | Diagram | Type |
|---|---|---|
| 1 | [Component diagram](#1-component-diagram) | System overview · Go packages · Python strategy classes |
| 2 | [Infrastructure diagram](#2-infrastructure-diagram) | AWS network and services · Terraform modules · infra test layers |
| 3 | [Database diagram](#3-database-diagram) | Relational ER model + order state machine |
| 4 | [Vector database](#4-vector-database) | Embeddings index used by RAG (today and target) |
| 5 | [LangChain / LangGraph](#5-langchain--langgraph) | Workflow graph + request lifecycle with HITL |
| 6 | [RAG retrieval](#6-rag-retrieval) | Multi-query retrieval + Reciprocal Rank Fusion |
| 7 | [Guardrails](#7-guardrails) | Block vs. escalate + trust boundary |
| 8 | [Resilience](#8-resilience-circuit-breaker) | Circuit breaker flow and state machine |
| 9 | [End-to-end flow and CI/CD](#9-end-to-end-flow-and-cicd) | Sequence across services + pipeline gates |

Design rationale: [ADR 001](../adr/001-command-worker-pool-go.md) · [ADR 002](../adr/002-strategy-pattern-ai-python.md) · [ADR 003](../adr/003-persistence-outbox-sqlite.md) · [ADR 004](../adr/004-ai-advisory-guardrails-hitl-evals.md)

---

## 1. Component diagram

### 1.1 System overview

The AI **proposes**; it never executes directly. Orders go through guardrails and, when required, human approval before reaching the transactional backend.

```mermaid
%%{init: {"theme": "forest"}}%%
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

### 1.2 Go backend packages (clean layering)

```mermaid
%%{init: {"theme": "forest"}}%%
flowchart TD
    MAIN["cmd/api<br/>wiring + graceful shutdown"] --> HTTP
    MAIN --> ORD
    MAIN --> ENG
    MAIN --> STORE

    HTTP["internal/httpapi<br/>handlers · DTOs · error mapping"] --> ORD
    HTTP -->|read-only queries| STORE
    ORD["internal/orders<br/>use case · persistence Decorator · outbox Relay"] --> DOM
    ORD -->|Repository port| STORE
    ORD -->|Dispatcher port| ENG
    ENG["internal/engine<br/>worker pool · backpressure · semaphore"] --> DOM
    STORE["internal/store<br/>SQLite · migrations · SQL"]
    DOM["internal/domain<br/>Command · BuyOrder · money (no I/O)"]

    classDef pure fill:#d4edda,stroke:#28a745,color:#155724;
    classDef infra fill:#e2e3f3,stroke:#4b4f9c,color:#1f2150;
    class DOM pure;
    class STORE,ENG infra;
```

### 1.3 Command pattern (Go)

```mermaid
%%{init: {"theme": "forest"}}%%
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

### 1.4 Strategy pattern (Python)

```mermaid
%%{init: {"theme": "forest"}}%%
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
| FastAPI router, LangGraph graph, guardrails, reviewer auth | ✅ | [`ai-service/src/`](../../ai-service/src/) |
| HTTP handler, worker pool, outbox + relay, append-only ledger, CAS claim | ✅ | [`portfolio-api/internal/`](../../portfolio-api/internal/) |
| `LLMRagStrategy` (Claude, schema-validated) · `RuleBasedStrategy` | ✅ | [`strategy.py`](../../ai-service/src/strategy.py), [`llm.py`](../../ai-service/src/llm.py) |
| `FineTunedModelStrategy` | 🟡 | Real contract, simulated inference |
| `SellOrder` · persistent checkpointer (Postgres/Redis) · API Gateway / ALB | ⬜ | Roadmap |

---

## 2. Infrastructure diagram

Terraform on AWS, split into reusable modules and tested in four layers up to a real `apply` against LocalStack. **Not applied to a real AWS account.** Details, tests and known gaps: [infra/README.md](../../infra/README.md).

### 2.1 Network and services

```mermaid
%%{init: {"theme": "forest"}}%%
flowchart TB
    Internet((Internet))

    subgraph VPC ["VPC 10.0.0.0/16 · 2 Availability Zones"]
        subgraph Public ["Public subnets (10.0.1.0/24, 10.0.2.0/24)"]
            IGW[Internet Gateway]
            NAT["NAT Gateway + EIP<br/>(one per AZ in prod)"]
            ALB["ALB · /api/* and /v1/* only"]
        end
        subgraph Private ["Private subnets (10.0.10.0/24, 10.0.20.0/24)"]
            GO[ECS Fargate<br/>portfolio-api :8080]
            AI[ECS Fargate<br/>ai-service :8000]
        end
        subgraph Data ["Database subnets (10.0.30.0/24, 10.0.40.0/24) · no internet route"]
            RDS[(RDS PostgreSQL 16<br/>encrypted · Multi-AZ in prod)]
        end
    end

    ECR[(ECR repos<br/>immutable tags · scan on push)]
    SM[Secrets Manager]
    CW[CloudWatch Logs + Alarms]
    SNS[SNS alarm topic<br/>KMS CMK]
    LLM[[LLM provider API]]

    Internet --> IGW --> ALB -->|/api/*| GO
    ALB -->|/v1/*| AI
    AI -->|Cloud Map :8080| GO
    AI -->|HTTPS 443 via NAT| NAT --> LLM
    GO & AI -.->|5432| RDS
    GO & AI -.-> SM
    GO & AI -.-> CW --> SNS
    ECR -.->|images| GO & AI
```

| Security group | Inbound | Outbound |
|---|---|---|
| `alb-sg` | 80 and 443 from the internet | 8080 and 8000 to `ecs-sg` only |
| `ecs-sg` | 8080 and 8000 from `alb-sg`; 8080 from itself (ai-service → portfolio-api) | 5432 to `rds-sg`; 8080 to itself; **443 to the internet** (LLM API, AWS APIs) |
| `rds-sg` | 5432 **only from `ecs-sg`** | none |

### 2.2 Terraform modules

```mermaid
%%{init: {"theme": "forest"}}%%
flowchart LR
    subgraph Roots
        AWS["infra/<br/>AWS environment"]
        LS["infra/localstack/<br/>LocalStack environment"]
    end
    subgraph Modules ["infra/modules/"]
        NET[network<br/>VPC · subnets · NAT · routes · flow logs]
        SEC[security<br/>ALB → ECS → RDS security groups]
        SECRETS[app-secrets<br/>AI service secret]
        DB[database<br/>RDS PostgreSQL 16 + credentials]
        REG[registry<br/>ECR repositories]
        EDGE[edge<br/>ALB · routing · alarms]
        COMP[compute<br/>ECS Fargate · IAM · Cloud Map · autoscaling]
        STATE[state-backend<br/>S3 + DynamoDB + KMS]
    end
    AWS --> NET & SEC & SECRETS & DB & REG & EDGE & COMP
    LS --> NET & SEC & SECRETS & STATE
```

### 2.3 How the infrastructure is tested

```mermaid
%%{init: {"theme": "forest"}}%%
flowchart LR
    A["fmt + validate<br/>syntax"] --> B["TFLint + AWS ruleset<br/>invalid types, unused code"]
    B --> C["terraform test<br/>23 tests, mocked AWS"]
    C --> D["Trivy<br/>0 CRITICAL · 0 HIGH"]
    D --> E["LocalStack<br/>apply → verify → drift → destroy"]
```

---

## 3. Database diagram

### 3.1 Relational model (portfolio-api)

Schema: [`migrations/001_init.sql`](../../portfolio-api/internal/store/migrations/001_init.sql). SQLite today; PostgreSQL in production (only the `store` package changes).

```mermaid
%%{init: {"theme": "forest"}}%%
erDiagram
    ORDERS ||--o{ LEDGER_ENTRIES : "produces"
    ORDERS ||--|| OUTBOX : "announced by"
    ORDERS {
        text id PK
        text idempotency_key UK "client retries return the same order"
        text portfolio_id
        text symbol
        text side "CHECK BUY or SELL"
        integer quantity "CHECK > 0, whole shares"
        integer price_cents "CHECK > 0, no float"
        text status "CHECK in state machine"
        integer created_at "unix ms"
    }
    LEDGER_ENTRIES {
        integer id PK
        text order_id FK
        text portfolio_id
        text asset "USD or ticker"
        text entry_type "DEBIT, CREDIT, RESERVED, RELEASED"
        integer amount "cents or shares; signed"
    }
    OUTBOX {
        integer id PK
        text aggregate_id FK
        text event_type
        text payload "CHECK json_valid"
        integer published_at "NULL = pending"
    }
```

| SQL technique | Where | Why |
|---|---|---|
| `UNIQUE`, `CHECK`, `FOREIGN KEY` | all tables | Invariants enforced by the database, not only by code |
| Triggers that `RAISE(ABORT)` on `UPDATE`/`DELETE` | `ledger_entries` | Append-only audit trail |
| Partial index `WHERE published_at IS NULL` | `outbox` | The relay scans only pending events |
| Compare-and-set `UPDATE … WHERE status='PENDING'` | `ClaimOrder` | At-most-once execution without long locks |
| `SUM(amount) … GROUP BY asset` | positions | Balances derived from the ledger, never stored |

### 3.2 Order lifecycle

```mermaid
%%{init: {"theme": "forest"}}%%
stateDiagram-v2
    [*] --> PENDING: POST /orders/buy<br/>(order + outbox event in one tx)
    PENDING --> EXECUTING: worker claims it<br/>UPDATE … WHERE status='PENDING'
    EXECUTING --> EXECUTED: settled<br/>ledger: CASH_DEBIT + POSITION_CREDIT
    EXECUTING --> FAILED: broker step failed<br/>ledger: FUNDS_RESERVED
    FAILED --> COMPENSATED: Undo (idempotent)<br/>ledger: FUNDS_RELEASED
    EXECUTED --> [*]
    COMPENSATED --> [*]
```

---

## 4. Vector database

### 4.1 Today: in-memory vector index ✅

[`retrieval.py`](../../ai-service/src/retrieval.py) builds the index at startup from the Markdown knowledge base. Vectors are sparse TF-IDF, L2-normalized, so the dot product is cosine similarity. This keeps CI and evals deterministic and needs no infrastructure.

```mermaid
%%{init: {"theme": "forest"}}%%
flowchart LR
    subgraph Ingest ["Indexing (at startup)"]
        KB[(src/knowledge/*.md)] --> CH["chunk_markdown()<br/>one chunk per '##' section<br/>id = doc#section-slug"]
        CH --> FIT["Embedder.fit(corpus)<br/>TfidfEmbedder: IDF table"]
        FIT --> EMB["Embedder.embed(chunk)<br/>sparse vector, L2-normalized"]
        EMB --> IDX[("Retriever._vectors<br/>in-memory list")]
    end

    subgraph Query ["Query time"]
        Q[sub-query] --> QE["Embedder.embed(query)"]
        QE --> SIM["cosine = dot product<br/>over every chunk"]
        IDX --> SIM
        SIM --> TOPK["top-k with score ≥ min_score<br/>RetrievedChunk(chunk, score)"]
    end
```

### 4.2 Target: PostgreSQL + pgvector ⬜

The `Embedder` protocol is the swap point: a dense embedder and a pgvector-backed retriever can replace TF-IDF without touching the graph. RDS PostgreSQL 16 is already provisioned in Terraform; the extension would be enabled with `CREATE EXTENSION vector`. The swap should happen only when the golden set shows a recall gain.

```mermaid
%%{init: {"theme": "forest"}}%%
flowchart LR
    KB[(Knowledge docs)] --> CH[Chunker<br/>same citable ids]
    CH --> DE["Dense Embedder<br/>(implements Embedder protocol)"]
    DE --> PG[("RDS PostgreSQL 16<br/>pgvector · HNSW index")]
    Q[sub-query] --> DE2[Dense Embedder] --> ANN["ORDER BY embedding &lt;=&gt; :q<br/>LIMIT k"]
    PG --> ANN
    ANN --> HY["Hybrid: dense + keyword<br/>fused with RRF"]
    HY --> TOPK[top-k chunks → LLM]
```

```mermaid
%%{init: {"theme": "forest"}}%%
erDiagram
    KNOWLEDGE_CHUNKS {
        text chunk_id PK "doc#section-slug, used in citations"
        text doc_id
        text title
        text content
        vector embedding "vector(d), HNSW cosine index"
        text embedder_version "re-embed when the model changes"
    }
```

| Item | Status |
|---|---|
| `Embedder` protocol, `TfidfEmbedder`, in-memory `Retriever` with `search` / `search_many` (RRF) | ✅ |
| RDS PostgreSQL 16 in Terraform | ✅ (not applied) |
| Dense embeddings, `knowledge_chunks` table, pgvector HNSW index, hybrid search | ⬜ |

---

## 5. LangChain / LangGraph

The AI service uses **LangGraph** (`StateGraph`, `interrupt`, `Command`, `MemorySaver`) on top of **langchain-core** (`RunnableConfig`). It is a fixed workflow, not an autonomous agent: the LLM decides the content of one step, the code decides the control flow.

### 5.1 Workflow graph

Generated from the compiled graph (`graph.get_graph().draw_mermaid()`). Dotted arrows are conditional edges.

```mermaid
%%{init: {"theme": "forest"}}%%
graph TD;
	__start__([start]):::first
	retrieve(retrieve)
	assess(assess)
	propose(propose)
	guardrails(guardrails)
	human_review(human_review)
	execute(execute)
	reject(reject)
	__end__([end]):::last
	__start__ --> retrieve;
	retrieve --> assess;
	assess --> propose;
	propose --> guardrails;
	guardrails -.->|clean| execute;
	guardrails -.->|needs review| human_review;
	guardrails -.->|blocking violation| reject;
	human_review -.->|approved| execute;
	human_review -.->|rejected| reject;
	execute --> __end__;
	reject --> __end__;
	classDef default fill:#f2f0ff,line-height:1.2
	classDef first fill-opacity:0
	classDef last fill:#bfb6fc
```

| Node | What it does |
|---|---|
| `retrieve` | One sub-query per concern, fused with Reciprocal Rank Fusion |
| `assess` | Active Strategy: LLM RAG behind a circuit breaker, rule-based fallback |
| `propose` | Target allocation → BUY orders funded only by available cash |
| `guardrails` | Blocking rules and human-review triggers |
| `human_review` | `interrupt()`; the checkpointer persists state until a reviewer responds |
| `execute` | Calls `portfolio-api` with `Idempotency-Key = <thread>:<i>:<symbol>` |
| `reject` | Terminal state; nothing is executed |

### 5.2 Request lifecycle with human approval

```mermaid
%%{init: {"theme": "forest"}}%%
sequenceDiagram
    autonumber
    actor Client as Advisor app
    participant API as FastAPI
    participant G as LangGraph
    participant R as Retriever
    participant S as Strategy (LLM + breaker)
    participant CP as Checkpointer
    actor Rev as Licensed reviewer
    participant Go as portfolio-api (Go)

    Client->>API: POST /v1/advice (X-Client-Id)
    API->>API: rate limit per client
    API->>G: invoke(profile, initiator)
    G->>R: multi-query retrieval + RRF
    R-->>G: top chunks (citable ids)
    G->>S: evaluate(profile, chunks)
    S-->>G: structured opinion + computed VaR
    G->>G: propose orders, then guardrails
    G->>CP: interrupt() at human_review (state saved)
    API-->>Client: 201 PENDING_REVIEW + proposals + reasons
    Rev->>API: POST /v1/advice/{id}/review (Bearer token)
    API->>API: authenticate, then four-eyes check
    API->>G: Command(resume=approved)
    G->>Go: POST /orders/buy (Idempotency-Key)
    Go-->>G: 202 Accepted (order id)
    API-->>Rev: 200 EXECUTED + executions
```

### 5.3 "The LLM explains, the code computes"

```mermaid
%%{init: {"theme": "forest"}}%%
flowchart TD
    P[PortfolioProfile<br/>enums + numbers only] --> Q[Quant core<br/>volatility · VaR √t · concentration]
    P --> RAG[Retrieved chunks<br/>wrapped in &lt;doc&gt; tags]
    Q --> PROMPT[Prompt]
    RAG --> PROMPT
    PROMPT --> LLM[LLM<br/>structured output]
    LLM --> V{Pydantic<br/>schema valid?}
    V -- no --> F[LLMError → counts as<br/>circuit-breaker failure]
    V -- yes --> O[Opinion: risk level, allocation,<br/>rationale, citations]
    Q --> RES[RiskAssessmentResult]
    O --> RES
    RES -. VaR and volatility come<br/>from code, never the model .-> RES
```

---

## 6. RAG retrieval

```mermaid
%%{init: {"theme": "forest"}}%%
flowchart TD
    KB[(src/knowledge/*.md)] --> CH["Chunk by '##' section<br/>id = doc#section-slug"]
    CH --> IDX[TF-IDF vectors<br/>Embedder protocol]
    PROFILE[Profile] --> QS[One sub-query per concern]
    QS --> S1[search q1] & S2[search q2] & S3[search qN]
    IDX --> S1 & S2 & S3
    S1 & S2 & S3 --> RRF["Reciprocal Rank Fusion<br/>score = Σ 1/(60 + rank)"]
    RRF --> TOP[Top-k chunks]
    TOP --> LLM[LLM must cite chunk ids]
    LLM --> GR{Every citation in the<br/>retrieved set?}
    GR -- no --> REJ[Rejected:<br/>hallucinated source]
    GR -- yes --> OK[Continue]
```

Multi-query + RRF exists because a single concatenated query buried the crypto policy in 7th place; the offline evals caught it.

---

## 7. Guardrails

### 7.1 Block vs. escalate

```mermaid
%%{init: {"theme": "forest"}}%%
flowchart TD
    IN[Assessment + proposals] --> B1{Citations all retrieved?}
    B1 -- no --> BLOCK[REJECT]
    B1 -- yes --> B2{Allocation sums to 1?}
    B2 -- no --> BLOCK
    B2 -- yes --> B3{Crypto suitable?<br/>none for CONSERVATIVE/BALANCED, ≤ 5%}
    B3 -- no --> BLOCK
    B3 -- yes --> B4{Risk level matches<br/>declared tolerance?}
    B4 -- no --> BLOCK
    B4 -- yes --> B5{Orders funded by cash?}
    B5 -- no --> BLOCK
    B5 -- yes --> R{Any review trigger?<br/>risk ≥ 0.70 · trade > 10% AUM ·<br/>position > 20% · degraded ·<br/>policy not retrieved}
    R -- yes --> HR[HUMAN REVIEW]
    R -- no --> EX[EXECUTE]
```

Blocking rules protect against **wrong** answers; review triggers protect against **risky** ones. Code: [`guardrails.py`](../../ai-service/src/guardrails.py).

### 7.2 Trust boundary

```mermaid
%%{init: {"theme": "forest"}}%%
flowchart TD
    subgraph Untrusted
        KB[Knowledge base docs]
        LLM[LLM output]
    end
    subgraph Controls
        SCH[Pydantic schema]
        GRD[Deterministic guardrails]
        HITL[Authenticated reviewer<br/>+ four-eyes]
    end
    subgraph Trusted
        EXE[Execute node · fixed code]
        GO[Go API · idempotent]
    end
    KB --> LLM --> SCH --> GRD --> HITL --> EXE --> GO
```

---

## 8. Resilience (circuit breaker)

### 8.1 Request flow

```mermaid
%%{init: {"theme": "forest"}}%%
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

### 8.2 State machine

```mermaid
%%{init: {"theme": "forest"}}%%
stateDiagram-v2
    [*] --> CLOSED
    CLOSED --> CLOSED: Success (reset counter)
    CLOSED --> OPEN: Failures >= threshold
    OPEN --> OPEN: Request → rule-based fallback
    OPEN --> HALF_OPEN: Timeout expires (30s)
    HALF_OPEN --> CLOSED: Probe request succeeds
    HALF_OPEN --> OPEN: Probe request fails
```

---

## 9. End-to-end flow and CI/CD

### 9.1 End-to-end flow

```mermaid
%%{init: {"theme": "forest"}}%%
sequenceDiagram
    autonumber
    actor A as Advisor app
    participant AI as AI service (FastAPI + LangGraph)
    actor R as Licensed reviewer
    participant GO as portfolio-api (Go)
    participant DB as SQLite / PostgreSQL
    participant W as Worker pool

    A->>AI: POST /v1/advice (portfolio)
    AI->>AI: retrieve policy docs (multi-query RAG)
    AI->>AI: compute risk (quant core) + LLM opinion (structured, cited)
    AI->>AI: propose BUY orders, then guardrails
    alt blocking violation (hallucination, unsuitable, unfunded)
        AI-->>A: REJECTED (nothing executed)
    else needs review (large trade, high risk, degraded)
        AI-->>A: PENDING_REVIEW
        R->>AI: POST /review (bearer token, four-eyes)
        AI->>GO: POST /orders/buy (Idempotency-Key)
    else clean
        AI->>GO: POST /orders/buy (Idempotency-Key)
    end
    GO->>DB: one tx: order PENDING + outbox event
    GO-->>AI: 202 Accepted
    GO->>W: dispatch (a relay re-dispatches if this is lost)
    W->>DB: CAS claim → saga → append-only ledger entries
```

### 9.2 CI/CD pipeline

```mermaid
%%{init: {"theme": "forest"}}%%
flowchart LR
    PUSH([push / PR]) --> S1

    subgraph S1 ["Stage 1 · fast feedback (parallel)"]
        direction TB
        SEC["Secrets scan<br/>gitleaks · full history"]
        GO["Go backend<br/>vet · test -race · coverage · govulncheck"]
        PY["Python AI<br/>ruff · pytest · offline evals · pip-audit"]
        TF["Terraform static<br/>fmt · validate · TFLint · terraform test · Trivy"]
        HD["Dockerfile lint<br/>hadolint"]
    end

    subgraph S2 ["Stage 2 · integration"]
        direction TB
        DS["MLOps dataset<br/>generate · JSONL · quality gate"]
        IMG["Containers ×2<br/>build · /health smoke test · non-root ·<br/>Trivy image gate · SBOM"]
        LS["Infra on LocalStack<br/>apply · verify via AWS API ·<br/>drift check · destroy"]
    end

    PY --> DS
    GO & PY & HD --> IMG
    TF --> LS
    S2 --> SUM(["Pipeline summary<br/>gate table · fail if any gate failed"])
```

Every gate can fail the build: secrets in history, tests and the race detector, vulnerable dependencies the code reaches, evals below threshold, dataset quality, Terraform tests, CRITICAL misconfigurations, fixable CRITICAL CVEs in the images, a container that does not start healthy, and infrastructure that fails to apply, verify or tear down cleanly. Third-party binaries are pinned and SHA-256 verified through one composite action.
