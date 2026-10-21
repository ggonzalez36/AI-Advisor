# ADR 001: Implementation of Command Pattern and Worker Pool for Transactional Processing in Go

## Status
Approved

## Date
2026-10-21

## Business and Technical Context
The transactional backend of `fin-ai-advisor` (`portfolio-api`) must process massive streams of buy and sell orders (`BuyOrder`, `SellOrder`) with low latency and high concurrency. In high‑volatility market scenarios, thousands of clients submit orders simultaneously.

## Architectural Decision
We adopt the **Command Pattern** combined with a **Worker Pool** managed by Goroutines and Channels in Go, following the design principles of [Refactoring.Guru: Command Pattern](https://refactoring.guru/design-patterns/command).

### 1. Command Pattern (`internal/domain/trade_command.go`)
- Defines a canonical `Command` interface with `Execute`, `Undo`, `ID`, and `Status` methods.
- Each order (e.g., `BuyOrder`) encapsulates all required parameters (ID, PortfolioID, Symbol, Quantity, Price, Timestamp) and its own state machine (`PENDING`, `EXECUTED`, `COMPENSATED`, `FAILED`).
- `Execute(ctx)` performs the state transition and capital debit.
- `Undo(ctx)` performs compensation (refund and position reversal), enabling a Saga‑style compensation without external frameworks.

### 2. Concurrent Worker Pool (`internal/engine/worker_pool.go`)
- Fixed‑size pool of N workers (goroutines) pulls commands from a buffered channel.
- Non‑blocking ingestion (`select` with `default`) or bounded timeouts apply back‑pressure when the channel is full, returning `HTTP 429 Too Many Requests` or routing excess commands to a dead‑letter queue.
- Workers are orchestrated with `context.Context` and `sync.WaitGroup`, ensuring graceful shutdown without loss of in‑flight orders or race conditions.

## Trade‑offs
### Positive (+)
- **Resource Protection:** The number of concurrent PostgreSQL transactions is limited by the worker pool size, preventing connection starvation.
- **Fault Tolerance & Reversibility:** Uniform `Undo()` enables automatic compensation on failures.
- **Auditability & Telemetry:** Each command carries a unique identifier for end‑to‑end tracing, facilitating structured logs and latency metrics.

### Negative (–)
- **Buffer Memory:** Commands queued in the channel consume volatile memory. *Mitigation:* Set a fixed channel capacity and reject/forward excess load.
- **Compensation Complexity:** `Undo()` must be idempotent across repeated network failures. *Mitigation:* Implement atomic state checks within `Undo()`.

## References
- Refactoring Guru: Command Design Pattern (https://refactoring.guru/design-patterns/command)
- Go Concurrency Patterns: Worker Pools (https://go.dev/blog/pipelines)
- Saga Pattern for Distributed Transactions
