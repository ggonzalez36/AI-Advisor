-- 001_init.sql — Esquema transaccional de portfolio-api.
-- Montos monetarios en centavos (INTEGER) y cantidades en acciones enteras: sin float.
-- Timestamps en milisegundos Unix (INTEGER) para comparaciones y orden correctos.

CREATE TABLE orders (
    id               TEXT    PRIMARY KEY,
    idempotency_key  TEXT    NOT NULL UNIQUE,          -- Reintentos del cliente no duplican órdenes
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

-- Consultas frecuentes: historial de órdenes por portafolio ordenado por fecha
CREATE INDEX idx_orders_portfolio_created ON orders (portfolio_id, created_at DESC);

-- Ledger contable append-only: el saldo se deriva con SUM(), nunca se sobrescribe.
-- Evita locks de escritura sobre una fila de "saldo" compartida y deja auditoría completa.
CREATE TABLE ledger_entries (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    order_id      TEXT    NOT NULL REFERENCES orders (id),
    portfolio_id  TEXT    NOT NULL,
    asset         TEXT    NOT NULL,                    -- 'USD' para efectivo, ticker para posiciones
    entry_type    TEXT    NOT NULL
                  CHECK (entry_type IN ('FUNDS_RESERVED', 'FUNDS_RELEASED', 'CASH_DEBIT', 'POSITION_CREDIT')),
    amount        INTEGER NOT NULL,                    -- Centavos si asset = 'USD', acciones en otro caso
    created_at    INTEGER NOT NULL
);

CREATE INDEX idx_ledger_portfolio_asset ON ledger_entries (portfolio_id, asset);
CREATE INDEX idx_ledger_order ON ledger_entries (order_id);

CREATE TRIGGER ledger_entries_no_update
BEFORE UPDATE ON ledger_entries
BEGIN
    SELECT RAISE(ABORT, 'ledger_entries es append-only: UPDATE no permitido');
END;

CREATE TRIGGER ledger_entries_no_delete
BEFORE DELETE ON ledger_entries
BEGIN
    SELECT RAISE(ABORT, 'ledger_entries es append-only: DELETE no permitido');
END;

-- Transactional Outbox: el evento se escribe en la MISMA transacción que la orden.
-- Si el proceso cae antes de despachar al worker pool, el relay lo recupera.
CREATE TABLE outbox (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    aggregate_id  TEXT    NOT NULL REFERENCES orders (id),
    event_type    TEXT    NOT NULL,
    payload       TEXT    NOT NULL CHECK (json_valid(payload)),
    created_at    INTEGER NOT NULL,
    published_at  INTEGER                              -- NULL = pendiente de despacho
);

-- Índice parcial: el relay solo escanea eventos pendientes, no el histórico completo
CREATE INDEX idx_outbox_pending ON outbox (created_at) WHERE published_at IS NULL;
