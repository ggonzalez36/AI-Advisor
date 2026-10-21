# Fin-AI Advisor

A production-grade, high-concurrency financial investment monorepo combining a transactional core written in **Golang** with an AI & MLOps service in **Python 3.11+** (LangGraph, RAG, and SLM Fine-Tuning), cloud infrastructure on AWS using **Terraform**, and an enterprise **GitHub Actions** CI/CD/DevSecOps pipeline.

---

## 🏛️ Monorepo Architecture

```text
/fin-ai-advisor
├── docs/
│   ├── architecture-design.md             # Architecture diagrams (Mermaid) + implementation status
│   ├── adr/                               # Architecture Decision Records (ADRs)
│   │   ├── 001-command-worker-pool-go.md  # ADR 001: Command Pattern & Worker Pool in Go
│   │   ├── adr_001_en.md                  # ADR 001 (English)
│   │   ├── 002-strategy-pattern-ai-python.md # ADR 002: Strategy Pattern & RAG in Python
│   │   └── 003-persistence-outbox-sqlite.md # ADR 003: Outbox, Append-only Ledger & SQLite
│   └── diagrams/                          # Standalone diagrams (Circuit Breaker, EN)
├── portfolio-api/                         # Transactional Backend (Go 1.22+)
│   ├── cmd/api/main.go                    # REST HTTP Server, Telemetry & Graceful Shutdown
│   ├── internal/domain/trade_command.go   # Command Pattern & Saga Compensation (Execute / Undo)
│   ├── internal/domain/trade_command_test.go # Domain Unit & Saga Compensation Tests
│   ├── internal/engine/worker_pool.go     # Concurrent Worker Pool with Backpressure & DB Semaphore
│   ├── internal/engine/worker_pool_test.go # High Concurrency, Drain & Backpressure Tests
│   ├── internal/store/                    # SQLite persistence: migrations, outbox, ledger, idempotency
│   ├── internal/orders/                   # Use case service, persistence Decorator, outbox Relay
│   ├── internal/httpapi/                  # REST handlers, DTOs and error mapping
│   └── go.mod
├── ai-service/                            # AI/MLOps Service (Python 3.11+)
│   ├── src/strategy.py                    # Strategy Pattern (LangChain RAG / SLM Quant Models)
│   ├── src/rag_graph.py                   # Stateful LangGraph Workflow for Portfolio Rebalancing
│   ├── scripts/generate_finetuning_dataset.py # MLOps Synthetic Dataset Generator (OpenAI & Alpaca)
│   ├── tests/                             # Pytest Unit Test Suite
│   │   ├── test_strategy.py
│   │   └── test_rag_graph.py
│   ├── pyproject.toml                     # Python Package, Ruff Linter & Pytest Config
│   └── README.md                          # AI Service Documentation
├── infra/                                 # Infrastructure as Code (Terraform AWS)
│   ├── main.tf                            # Multi-AZ VPC, RDS PostgreSQL 16 (pgvector), ECR, ECS
│   └── variables.tf                       # Strongly-typed variables with input validation
├── .github/workflows/
│   └── ci-mlops.yml                       # GitHub Actions CI/CD, DevSecOps, Lint & MLOps
├── .gitignore
└── README.md                              # Root Monorepo Documentation
```

> 📐 **Architecture diagrams:** see [docs/architecture-design.md](docs/architecture-design.md) for the system overview, Command Pattern, Strategy Pattern and Circuit Breaker diagrams, each with an implementation-status table.

---

## 🚀 Services & Local Development

### 1. Transactional Backend (`portfolio-api` - Go)

The Go backend handles high-throughput financial orders with strict consistency and non-blocking backpressure:
- **Command Pattern ([Refactoring.Guru: Command](https://refactoring.guru/design-patterns/command)):**
  - Encapsulates trade operations behind the canonical `Command` interface with `Execute(ctx)` and `Undo(ctx)`.
  - Enables distributed **Saga Pattern compensation** (rollback) if execution fails downstream in the brokerage ledger.
- **Worker Pool Engine:**
  - Employs a fixed pool of $N$ worker goroutines consuming from a buffered channel using non-blocking `select`/`default` semantics.
  - Automatically triggers **backpressure** (`HTTP 429 Too Many Requests`) when the queue reaches capacity, protecting system stability.
  - Controls maximum concurrent PostgreSQL transactions via an internal channel semaphore (`dbConnSemaphore`), eliminating **database connection starvation**.
  - Provides thread-safe, atomic operational metrics (`atomic.Uint64`).

```bash
cd portfolio-api

# Run unit tests and concurrency race detection
go test -v -race ./...

# Start the REST API server locally (port 8080)
go run ./cmd/api            # Escucha en 127.0.0.1:8080 (HOST=0.0.0.0 solo dentro de contenedores)
```

- **Durable persistence ([ADR 003](docs/adr/003-persistence-outbox-sqlite.md)):** SQLite (pure Go, no cgo) with a **transactional outbox** + relay (no lost orders on crash), **Idempotency-Key** support (safe client retries), an **append-only ledger** enforced by triggers, and money stored as **integer cents**.

#### Key HTTP Endpoints:
- `GET /health`: Service + database health check.
- `GET /api/v1/metrics`: Real-time Worker Pool telemetry (submitted, executed, compensated, rejected, duplicate deliveries).
- `POST /api/v1/orders/buy`: Accepts an order asynchronously. `202` new order · `200` idempotent replay · `400` invalid · `429` backlog exceeded (`Retry-After`).
- `GET /api/v1/orders/{id}`: Order status plus its ledger entries.
- `GET /api/v1/portfolios/{id}/positions`: Positions derived from the ledger (`SUM ... GROUP BY`).

```bash
curl -i -X POST localhost:8080/api/v1/orders/buy \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: demo-1' \
  -d '{"portfolio_id":"port-demo","symbol":"NVDA","quantity":5,"price":"120.25"}'
```

---

### 2. AI & MLOps Service (`ai-service` - Python 3.11+)

The AI service delivers portfolio risk evaluation and automated rebalancing recommendations:
- **Strategy Pattern ([Refactoring.Guru: Strategy](https://refactoring.guru/design-patterns/strategy)):**
  - `RiskEvaluationStrategy(ABC)` defines the common interface for interchangeable risk assessment engines.
  - `LangChainOpenAIStrategy`: RAG-augmented analysis integrating macroeconomic indicators (FED rates, SEC 10-K filings) with high explainability.
  - `FineTunedModelStrategy`: Specialized financial transformer/SLM inference providing deterministic Value-at-Risk (VaR at 95%) with sub-50ms latency.
  - `AdvisorContext`: Orchestrates runtime strategy switching and maintains execution telemetry.
- **Stateful RAG with LangGraph:**
  - `rag_graph.py` implements a 4-stage directed state graph (`retrieve_market_intelligence` -> `extract_financial_signals` -> `evaluate_portfolio_strategy` -> `generate_trade_recommendations`).
  - Emits concrete `TradeProposal` recommendations (e.g., `BUY VOO`, `BUY BND`) directly compatible with the Go transactional backend.
- **MLOps Fine-Tuning Dataset Generator:**
  - `scripts/generate_finetuning_dataset.py` creates synthetic financial datasets formatted for both **OpenAI Chat Fine-Tuning** (`messages`) and **Alpaca/HuggingFace** (`instruction`, `input`, `output`).
  - Generates realistic investor archetypes with automatic 80/20 train/validation splits.

```bash
cd ai-service

# Lint and check code formatting with Ruff
uv run --with ruff ruff check .
uv run --with ruff ruff format --check .

# Run the test suite
uv run --with pytest pytest -v

# Generate 200 synthetic fine-tuning samples
uv run python scripts/generate_finetuning_dataset.py --num-samples 200 --output-dir data/finetuning --format both
```

---

### 3. Cloud Infrastructure (`infra` - Terraform AWS)

The infrastructure layer provisions an enterprise-grade AWS environment with multi-tier isolation:
- **Networking:** Multi-AZ VPC spanning 2 Availability Zones with dedicated Public (ALB/NAT), Private (ECS Fargate), and Database subnets.
- **Database:** Amazon RDS PostgreSQL 16 with gp3 storage, KMS encryption at rest, 14-day automated backup retention, Performance Insights, and `pgvector`/`pgcrypto` parameter group configuration.
- **Security:** AWS Secrets Manager for encrypted database credentials; least-privilege security groups separating ingress, application compute, and database tiers.
- **Containers & Registry:** Amazon ECR repositories for `portfolio-api` and `ai-service` with image scan-on-push enabled; Amazon ECS Fargate cluster with Container Insights and CloudWatch logging.

```bash
cd infra
terraform fmt -check
terraform init -backend=false
terraform validate
```

---

### 4. CI/CD & DevSecOps Pipeline (`.github/workflows/ci-mlops.yml`)

The GitHub Actions workflow enforces quality, security, and reproducibility on every pull request and push to `main`:
1. **`go-backend-ci`:** Module verification, `go vet`, and unit/concurrency tests with `-race` detection and code coverage reporting.
2. **`python-ai-ci`:** Fast linting and format enforcement via **Ruff**, followed by the **Pytest** test suite.
3. **`mlops-dataset-validation`:** Automated execution of the dataset generation pipeline, cryptographic/structural JSONL schema validation, and artifact archival.
4. **`terraform-devsecops`:** Format validation (`terraform fmt -check`), syntax validation (`terraform validate`), and static security auditing with **Trivy**.
