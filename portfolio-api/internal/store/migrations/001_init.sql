-- 001_init.sql — Transactional schema for portfolio-api.
-- Monetary amounts in cents (INTEGER) and quantities in whole shares: no floats.
-- Timestamps in Unix milliseconds (INTEGER) for correct comparisons and ordering.

CREATE TABLE orders (
    id               TEXT    PRIMARY KEY,
    idempotency_key  TEXT    NOT NULL UNIQUE,          -- Client retries do not duplicate orders
    portfolio_id     TEXT    NOT NULL,
    symbol           TEXT    NOT NULL,
    side             TEXT    NOT NULL CHECK (side IN ('BUY', 'SELL')),
    quantity         INTEGER NOT NULL CHECK (quantity > 0),
    price_cents      INTEGER NOT NULL CHECK (price_cents > 0),
    status           TEXT    NOT NULL DEFAULT 'PENDING'
                     CHECK (status IN ('PENDING', 'EXECUTING', 'EXECUTED', 'FAILED', 'COMPENSATED')),
    failure_reason   TEXT,
    created_at       INTEGER NOT NULL,
    updated_at       INTEGER NOT NULL
);

-- Frequent queries: order history per portfolio sorted by date
CREATE INDEX idx_orders_portfolio_created ON orders (portfolio_id, created_at DESC);

-- Append-only accounting ledger: balances are derived with SUM(), never overwritten.
-- Avoids write locks on a shared "balance" row and leaves a complete audit trail.
CREATE TABLE ledger_entries (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id      TEXT    NOT NULL REFERENCES orders (id),
    portfolio_id  TEXT    NOT NULL,
    asset         TEXT    NOT NULL,                    -- 'USD' for cash, ticker for positions
    entry_type    TEXT    NOT NULL
                  CHECK (entry_type IN ('FUNDS_RESERVED', 'FUNDS_RELEASED', 'CASH_DEBIT', 'POSITION_CREDIT')),
    amount        INTEGER NOT NULL,                    -- Cents if asset = 'USD', shares otherwise
    created_at    INTEGER NOT NULL
);

CREATE INDEX idx_ledger_portfolio_asset ON ledger_entries (portfolio_id, asset);
CREATE INDEX idx_ledger_order ON ledger_entries (order_id);

CREATE TRIGGER ledger_entries_no_update
BEFORE UPDATE ON ledger_entries
BEGIN
    SELECT RAISE(ABORT, 'ledger_entries is append-only: UPDATE not allowed');
END;

CREATE TRIGGER ledger_entries_no_delete
BEFORE DELETE ON ledger_entries
BEGIN
    SELECT RAISE(ABORT, 'ledger_entries is append-only: DELETE not allowed');
END;

-- Transactional Outbox: the event is written in the SAME transaction as the order.
-- If the process crashes before dispatching to the worker pool, the relay recovers it.
CREATE TABLE outbox (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    aggregate_id  TEXT    NOT NULL REFERENCES orders (id),
    event_type    TEXT    NOT NULL,
    payload       TEXT    NOT NULL CHECK (json_valid(payload)),
    created_at    INTEGER NOT NULL,
    published_at  INTEGER                              -- NULL = pending dispatch
);

-- Partial index: the relay only scans pending events, not the full history
CREATE INDEX idx_outbox_pending ON outbox (created_at) WHERE published_at IS NULL;
