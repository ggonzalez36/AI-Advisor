# Patterns and References

Each design decision in this repository maps to an established pattern. Page numbers are the **printed page** of each book.

| Abbreviation | Book |
|---|---|
| **GAIDP** | *Generative AI Design Patterns*, Lakshmanan & Hapke |
| **SEC** | *The Developer's Playbook for Large Language Model Security*, Wilson |
| **OPS** | *LLMOps* |
| **LLC** | *Learning LangChain* |
| **AGT** | *Building Applications with AI Agents* |
| **HOL** | *Hands-On Large Language Models* |
| **CES** | *Crafting Engineering Strategy* |

---

## 1. AI service

| Component | Pattern / concept | Reference |
|---|---|---|
| `LLMClient.generate(..., response_model)`; Claude via `messages.parse(output_format=…)` | **Grammar / constrained output**: the model's output is restricted to a schema instead of being parsed from text | GAIDP ch. 2, Pattern 2 *Grammar*, pp. 49–50 · OPS ch. 7, *Postprocessing and Output Validation*, p. 191 |
| `retrieval.py`: section chunking, TF-IDF, citable chunk ids | **Basic RAG** with a lexical retriever; lexical retrieval handles exact codes (tickers, policy names) that embeddings miss | GAIDP ch. 3, Pattern 6 *Basic RAG*, pp. 109, 117, 122 |
| `Retriever.search_many` (multi-query + RRF), `Embedder` protocol | **Hybrid search / combining retrievers**; add complexity only when evaluation shows a gain | GAIDP Pattern 10 *Hybrid search*, p. 169 · OPS ch. 6, *Combining Dense and Sparse Retrieval*, p. 162 · HOL ch. 8, *Dense Retrieval*, p. 228 |
| `guardrails.py`: every citation must be a retrieved chunk | **Trustworthy Generation**: source-level citation tracking; enforce citations | GAIDP ch. 4, Pattern 11, pp. 178–180, 182 |
| `guardrails.py`: suitability, allocation, funding, concentration | **Guardrails** as a separate layer over model outputs and action parameters | GAIDP ch. 9, Pattern 32 *Guardrails*, pp. 442–446 |
| Insufficient-context gate (policy not retrieved → human review) | **Out-of-domain detection**: do not let the model improvise without grounding | GAIDP Pattern 11, *Out-of-domain detection*, pp. 176–178 · HOL ch. 8, *Caveats of dense retrieval*, p. 234 |
| `LLMClient` protocol + `FakeLLMClient` (simulated outages, hallucinations, injections) | **Dependency Injection**: every LLM step accepts a test double | GAIDP ch. 6, Pattern 19, pp. 297–299 |
| Quant core computes VaR / volatility; the LLM never produces numbers | Deterministic, auditable logic for regulated domains | AGT ch. 1, *Workflows and Agents*, pp. 9–10 (Table 1-2) |
| `graph.py`: fixed nodes; code decides routing | **Workflow vs. agent**; the agency vs. reliability trade-off (the LLM decides one step's output, not the next step) | LLC ch. 5, pp. 116–117 · AGT ch. 1, p. 10 |
| `human_review` with `interrupt()` + checkpointer + `Command(resume=…)` | **Human-in-the-loop** (authorize / resume) on a persisted thread | LLC ch. 8, pp. 179–183 |
| Approval before executing a rebalance | **Excessive agency / excessive autonomy**. The book's example is a finance app that rebalances portfolios autonomously; the remedy is human in the loop | SEC ch. 7, pp. 83–84 |
| `execute` node is fixed code with idempotency keys; the LLM has no tools | **Pessimistic trust boundary**: treat model output as untrusted; least privilege | SEC ch. 4, pp. 39–40 · AGT ch. 12, *Safeguards*, pp. 288–289 |
| `<doc id="…">` delimiters + "documents are data, not instructions" | **Adding prompt structure** to separate data from instructions | SEC ch. 4, pp. 36–37 |
| Structured `PortfolioProfile` input (enums + numbers, no free text) | Removes the **direct prompt injection** surface; only indirect remains | SEC ch. 4, pp. 33–34 |
| Reviewer bearer tokens, four-eyes, per-client rate limiting | HITL is only meaningful if the human is authenticated; rate limiting | SEC ch. 4, *Rate Limiting*, p. 35 · SEC ch. 7, pp. 83–84 · AGT ch. 12, pp. 288–289 |
| Circuit breaker + `degraded` flag + fallback rate metric | Graceful degradation; **feedback-signal monitoring** | OPS ch. 7, *Feedback Signal Monitoring*, p. 193 |
| Review only above thresholds (`review_reasons`) | Send low-confidence outputs to human feedback | GAIDP Pattern 11, *Human Feedback*, p. 184 |
| `PROMPT_VERSION`, per-node latency, JSON logs, `/metrics` | **Prompt regressions**; the observability pipeline (per-call metadata) | OPS ch. 7, pp. 175–176, 188–193 · GAIDP Pattern 11, *Observability*, p. 184 |
| `evals/`: golden set with adversarial cases, CI gate | RAG metrics; evaluation sets as a **living specification**; regression testing | OPS ch. 7, pp. 179–181 · AGT ch. 9, pp. 207–208 · LLC ch. 10, *Regression Testing*, p. 234 |
| Teacher-labeled fine-tuning dataset + quality gate | Automatic instruction-dataset generation; **evaluate and filter** | GAIDP ch. 5, Pattern 16 *Evol-Instruct*, pp. 258–266 · OPS ch. 4, pp. 101–103 |
| ADRs with context, decision, consequences; amended, not rewritten | Engineering strategy: diagnosis → policy → operations | CES ch. 5, pp. 33–37 |

## 2. Transactional backend

The AI books above do not cover these; they are classic distributed-systems patterns.

| Component | Pattern |
|---|---|
| `domain.Command`, `BuyOrder.Execute/Undo` | Command pattern; Saga with compensating actions |
| `orders.persistentOrder` | Decorator (adds persistence without touching the domain) |
| `WorkerPool` | Bounded worker pool, backpressure, semaphore for resource limits |
| `store.CreateOrder` + `orders.Relay` | Transactional outbox (avoids dual writes) |
| `store.ClaimOrder` | Compare-and-set / optimistic concurrency; idempotent consumer |
| `orders.idempotency_key UNIQUE` | Idempotency keys for safe client retries |
| `ledger_entries` + triggers | Append-only ledger (event-sourcing-style derived balances) |
| Integer cents | Exact money representation (no binary floating point) |

---

## 3. OWASP Top 10 for LLM Applications: coverage

The book uses the v1.1 list (SEC Table 10-1, p. 130). The 2025 equivalent is shown for reference.

| OWASP v1.1 | 2025 | Status | Controls in this repo |
|---|---|---|---|
| LLM01 Prompt Injection | LLM01 | Mitigated (defense in depth) | No free-text user input; `<doc>` delimiters + system rule; schema-constrained output; deterministic guardrails; **poisoned-document test and golden-set case** |
| LLM02 Insecure Output Handling | LLM05 | Mitigated | Pydantic ranges; orders built by code, not the model. *Gap:* `rationale` is free text; a UI must escape it. |
| LLM03 Training Data Poisoning | LLM04 | Partial | Knowledge base versioned in git with PR review; dataset quality gate. *Gap:* per-document provenance hashes. |
| LLM04 Model Denial of Service | LLM10 | Mitigated | Per-client rate limiting (429), circuit breaker, `max_tokens`, bounded `top_k`, Go backpressure |
| LLM05 Supply Chain | LLM03 | Partial | `uv.lock`, pinned model id, pinned and checksum-verified Trivy. *Gap:* dependency scanning / SBOM. |
| LLM06 Sensitive Information Disclosure | LLM02 | Mitigated | The prompt contains aggregated metrics only (no user id or names); logs contain ids and decisions, not profiles |
| LLM07 Insecure Plugin Design | (in LLM06) | Not applicable | The LLM has no tools or plugins |
| LLM08 Excessive Agency | LLM06 | Mitigated | Fixed workflow; authenticated HITL + four-eyes; idempotent execution |
| LLM09 Overreliance | LLM09 | Mostly mitigated | Computed VaR; verified citations; degraded flag; escalation. *Gap:* claim-level citation checking (LLM-as-judge, offline). |
| LLM10 Model Theft | (in LLM10) | Not applicable today | Hosted model via API |
| — | LLM07 System Prompt Leakage | Low risk | The system prompt holds no secrets and is never returned |
| — | LLM08 Vector & Embedding Weaknesses | Partial | Internal, reviewed documents only. *Gap:* per-chunk provenance. |
