# Fin-AI Advisor Monorepo

Sistema de inversiones de alta concurrencia y grado de producción que combina un motor transaccional en **Golang** con un servicio de inteligencia artificial y MLOps en **Python 3.11+**, infraestructura en la nube con **Terraform (AWS)** y pipelines de **GitHub Actions**.

---

## 🏛️ Arquitectura General

```
/fin-ai-advisor
├── docs/adr/                              # Decisiones Arquitectónicas (ADRs)
│   ├── 001-command-worker-pool-go.md      # Command Pattern & Worker Pool en Go
│   └── 002-strategy-pattern-ai-python.md  # Strategy Pattern & RAG en Python
├── portfolio-api/                         # Backend Transaccional (Go 1.22+)
│   ├── cmd/api/main.go                    # Servidor HTTP REST y Graceful Shutdown
│   ├── internal/domain/trade_command.go   # Command Pattern & Compensación Saga (Undo)
│   ├── internal/engine/worker_pool.go     # Worker Pool con Goroutines y Backpressure
│   └── go.mod
├── ai-service/                            # AI/MLOps Service (Python 3.11+)
│   ├── src/strategy.py                    # Strategy Pattern (LangChain RAG / SLM Quant)
│   ├── src/rag_graph.py                   # Orquestación de Grafo de Estados con LangGraph
│   ├── scripts/generate_finetuning_dataset.py # Generador MLOps de datasets JSONL
│   ├── tests/                             # Suite de pruebas unitarias
│   └── pyproject.toml                     # Dependencias y configuración de Ruff / Pytest
├── infra/                                 # Infraestructura como Código (Terraform AWS)
│   ├── main.tf                            # VPC Multi-AZ, RDS Postgres 16, ECR, ECS Fargate
│   └── variables.tf                       # Parámetros tipados y validados
└── .github/workflows/
    └── ci-mlops.yml                       # Pipeline CI/CD, DevSecOps y MLOps Dataset
```

---

## 🚀 Módulos y Ejecución Local

### 1. Backend Transaccional (`portfolio-api`)
- **Patrón:** Command Pattern + Worker Pool con Goroutines y Channels no bloqueantes.
- **Tolerancia a fallos:** Soporte nativo para el patrón Saga distribuido con métodos idempotentes `Execute()` y `Undo()`.
- **Protección de base de datos:** Semáforo acotado para prevenir saturación de conexiones PostgreSQL (*DB Starvation*).

```bash
cd portfolio-api

# Ejecutar pruebas unitarias y de concurrencia
go test -v -race ./...

# Iniciar servidor REST local en el puerto 8080
go run cmd/api/main.go
```

#### Endpoints HTTP principales:
- `GET /health`: Estado del servicio.
- `GET /api/v1/metrics`: Telemetría en tiempo real del Worker Pool (órdenes encoladas, ejecutadas, compensadas y rechazadas).
- `POST /api/v1/orders/buy`: Encolado no bloqueante de órdenes de compra con control de contrapresión (`HTTP 429 Too Many Requests` si el búfer se llena).

---

### 2. Servicio de Inteligencia Artificial (`ai-service`)
- **Patrón:** Strategy Pattern para conmutación en tiempo de ejecución entre:
  - `LangChainOpenAIStrategy`: RAG cualitativo y contexto macroeconómico.
  - `FineTunedModelStrategy`: Inferencia cuantitativa local ultrarrápida (<50ms) con cálculo de Value-at-Risk (VaR).
- **Orquestación:** Grafo de estados con LangGraph (`rag_graph.py`) que conecta inteligencia de mercado con propuestas de rebalanceo ejecutables en el backend de Go.
- **MLOps:** Generador de datasets para fine-tuning (`scripts/generate_finetuning_dataset.py`) exportando en formatos OpenAI Chat y Alpaca.

```bash
cd ai-service

# Linting y formateo con Ruff
uv run --with ruff ruff check .
uv run --with ruff ruff format --check .

# Ejecutar pruebas unitarias
uv run --with pytest pytest -v

# Generar dataset sintético para Fine-Tuning
uv run python scripts/generate_finetuning_dataset.py --num-samples 200 --output-dir data/finetuning --format both
```

---

### 3. Infraestructura Cloud (`infra`)
- **Proveedor:** AWS con Terraform `>= 1.5.0`.
- **Componentes:**
  - VPC aislada con subredes Públicas, Privadas y de Base de Datos distribuidas en 2 Zonas de Disponibilidad (Multi-AZ).
  - RDS PostgreSQL 16 con soporte para extensiones `pgvector` y `pgcrypto`, cifrado KMS en reposo y backups automáticos.
  - Clúster ECS Fargate con Container Insights y repositorios ECR con escaneo de vulnerabilidades en push.
  - Almacenamiento seguro de credenciales con AWS Secrets Manager.

```bash
cd infra
terraform init
terraform validate
terraform plan
```

---

### 4. CI/CD & MLOps Pipeline (`.github/workflows/ci-mlops.yml`)
1. **Go Backend CI:** Pruebas unitarias, detección de condiciones de carrera (`-race`) y cálculo de cobertura atómica.
2. **Python AI CI:** Inspección estricta de estilo y bugs con **Ruff** y validación de pruebas con **pytest**.
3. **MLOps Dataset Pipeline:** Generación automatizada de datasets para Fine-Tuning con validación estructural de integridad JSONL.
4. **Terraform DevSecOps:** Verificación de sintaxis, formato y auditoría estática de seguridad con Trivy.
