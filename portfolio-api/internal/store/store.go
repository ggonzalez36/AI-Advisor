// Package store implementa la persistencia transaccional de portfolio-api sobre SQLite.
// Todo el acceso SQL vive aquí, de modo que migrar a PostgreSQL solo afecta este paquete (ADR 003).
package store

import (
	"context"
	"database/sql"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"strings"
	"time"

	_ "modernc.org/sqlite" // Driver SQLite en Go puro (sin cgo)
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

var ErrNotFound = errors.New("registro no encontrado")

// Estados persistidos de una orden. EXECUTING existe solo en BD: marca que un worker
// reclamó la orden y evita que una entrega duplicada la ejecute dos veces.
const (
	StatusPending     = "PENDING"
	StatusExecuting   = "EXECUTING"
	StatusExecuted    = "EXECUTED"
	StatusFailed      = "FAILED"
	StatusCompensated = "COMPENSATED"
)

type Order struct {
	ID             string    `json:"id"`
	IdempotencyKey string    `json:"idempotency_key"`
	PortfolioID    string    `json:"portfolio_id"`
	Symbol         string    `json:"symbol"`
	Side           string    `json:"side"`
	Quantity       int64     `json:"quantity"`
	PriceCents     int64     `json:"price_cents"`
	Status         string    `json:"status"`
	FailureReason  string    `json:"failure_reason,omitempty"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

type LedgerEntry struct {
	ID          int64     `json:"id"`
	OrderID     string    `json:"order_id"`
	PortfolioID string    `json:"portfolio_id"`
	Asset       string    `json:"asset"`
	EntryType   string    `json:"entry_type"`
	Amount      int64     `json:"amount"`
	CreatedAt   time.Time `json:"created_at"`
}

type Position struct {
	Asset  string `json:"asset"`
	Amount int64  `json:"amount"`
}

type Store struct {
	db  *sql.DB
	now func() time.Time
}

// Open abre (o crea) la base SQLite en path y aplica las migraciones pendientes.
func Open(ctx context.Context, path string) (*Store, error) {
	// WAL permite lecturas concurrentes con un escritor; busy_timeout evita "database is locked"
	// inmediato bajo contención; _txlock=immediate toma el lock de escritura al iniciar la
	// transacción y evita deadlocks por escalamiento de lectura a escritura.
	dsn := fmt.Sprintf("file:%s?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)"+
		"&_pragma=foreign_keys(1)&_pragma=synchronous(NORMAL)&_txlock=immediate", path)

	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("abriendo sqlite: %w", err)
	}
	// SQLite admite un solo escritor: más conexiones solo generan contención de locks.
	db.SetMaxOpenConns(4)

	s := &Store{db: db, now: func() time.Time { return time.Now().UTC() }}
	if err := s.migrate(ctx); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) Ping(ctx context.Context) error { return s.db.PingContext(ctx) }

// migrate aplica en orden los archivos migrations/NNN_*.sql que aún no figuran en schema_migrations.
func (s *Store) migrate(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version TEXT PRIMARY KEY, applied_at INTEGER NOT NULL)`); err != nil {
		return fmt.Errorf("creando schema_migrations: %w", err)
	}

	names, err := fs.Glob(migrationsFS, "migrations/*.sql")
	if err != nil {
		return err
	}
	sort.Strings(names)

	for _, name := range names {
		version := strings.TrimSuffix(strings.TrimPrefix(name, "migrations/"), ".sql")

		var exists int
		if err := s.db.QueryRowContext(ctx,
			`SELECT COUNT(*) FROM schema_migrations WHERE version = ?`, version).Scan(&exists); err != nil {
			return err
		}
		if exists > 0 {
			continue
		}

		ddl, err := migrationsFS.ReadFile(name)
		if err != nil {
			return err
		}
		err = s.inTx(ctx, func(tx *sql.Tx) error {
			if _, err := tx.ExecContext(ctx, string(ddl)); err != nil {
				return fmt.Errorf("migración %s: %w", version, err)
			}
			_, err := tx.ExecContext(ctx,
				`INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)`, version, s.ms())
			return err
		})
		if err != nil {
			return err
		}
	}
	return nil
}

// CreateOrder inserta la orden en estado PENDING junto con su evento de outbox en una
// única transacción. Si la idempotency key ya existe, retorna la orden original y created=false.
func (s *Store) CreateOrder(ctx context.Context, o Order) (Order, bool, error) {
	var result Order
	created := false

	err := s.inTx(ctx, func(tx *sql.Tx) error {
		existing, err := scanOrder(tx.QueryRowContext(ctx,
			selectOrder+` WHERE idempotency_key = ?`, o.IdempotencyKey))
		if err == nil {
			result = existing
			return nil
		}
		if !errors.Is(err, ErrNotFound) {
			return err
		}

		now := s.ms()
		if _, err := tx.ExecContext(ctx, `INSERT INTO orders
			(id, idempotency_key, portfolio_id, symbol, side, quantity, price_cents, status, created_at, updated_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, 'PENDING', ?, ?)`,
			o.ID, o.IdempotencyKey, o.PortfolioID, o.Symbol, o.Side, o.Quantity, o.PriceCents, now, now); err != nil {
			return fmt.Errorf("insertando orden: %w", err)
		}

		payload, _ := json.Marshal(map[string]any{
			"order_id": o.ID, "portfolio_id": o.PortfolioID, "symbol": o.Symbol,
			"side": o.Side, "quantity": o.Quantity, "price_cents": o.PriceCents,
		})
		if _, err := tx.ExecContext(ctx, `INSERT INTO outbox (aggregate_id, event_type, payload, created_at)
			VALUES (?, 'OrderAccepted', ?, ?)`, o.ID, string(payload), now); err != nil {
			return fmt.Errorf("insertando outbox: %w", err)
		}

		result, err = scanOrder(tx.QueryRowContext(ctx, selectOrder+` WHERE id = ?`, o.ID))
		created = err == nil
		return err
	})
	return result, created, err
}

// ClaimOrder transiciona PENDING -> EXECUTING con compare-and-set y marca el evento del
// outbox como publicado. Retorna false si otro worker ya la reclamó (entrega duplicada).
func (s *Store) ClaimOrder(ctx context.Context, orderID string) (bool, error) {
	claimed := false
	err := s.inTx(ctx, func(tx *sql.Tx) error {
		now := s.ms()
		res, err := tx.ExecContext(ctx, `UPDATE orders SET status = 'EXECUTING', updated_at = ?
			WHERE id = ? AND status = 'PENDING'`, now, orderID)
		if err != nil {
			return err
		}
		if n, _ := res.RowsAffected(); n != 1 {
			return nil
		}
		claimed = true
		_, err = tx.ExecContext(ctx, `UPDATE outbox SET published_at = ?
			WHERE aggregate_id = ? AND published_at IS NULL`, now, orderID)
		return err
	})
	return claimed, err
}

// MarkExecuted registra la liquidación: débito de efectivo y crédito de la posición.
func (s *Store) MarkExecuted(ctx context.Context, o Order) error {
	return s.inTx(ctx, func(tx *sql.Tx) error {
		total := o.Quantity * o.PriceCents
		if err := s.appendLedger(ctx, tx, o, "USD", "CASH_DEBIT", -total); err != nil {
			return err
		}
		if err := s.appendLedger(ctx, tx, o, o.Symbol, "POSITION_CREDIT", o.Quantity); err != nil {
			return err
		}
		return s.setStatus(ctx, tx, o.ID, StatusExecuted, "")
	})
}

// MarkFailed registra el fallo. Si el primer paso de la Saga retuvo fondos, deja
// constancia en el ledger para que la compensación posterior lo revierta.
func (s *Store) MarkFailed(ctx context.Context, o Order, reason string, fundsReserved bool) error {
	return s.inTx(ctx, func(tx *sql.Tx) error {
		if fundsReserved {
			if err := s.appendLedger(ctx, tx, o, "USD", "FUNDS_RESERVED", -o.Quantity*o.PriceCents); err != nil {
				return err
			}
		}
		return s.setStatus(ctx, tx, o.ID, StatusFailed, reason)
	})
}

// MarkCompensated libera los fondos retenidos. Es idempotente: solo actúa sobre órdenes FAILED.
func (s *Store) MarkCompensated(ctx context.Context, o Order) error {
	return s.inTx(ctx, func(tx *sql.Tx) error {
		var status string
		if err := tx.QueryRowContext(ctx, `SELECT status FROM orders WHERE id = ?`, o.ID).Scan(&status); err != nil {
			return err
		}
		if status != StatusFailed {
			return nil
		}
		if err := s.appendLedger(ctx, tx, o, "USD", "FUNDS_RELEASED", o.Quantity*o.PriceCents); err != nil {
			return err
		}
		return s.setStatus(ctx, tx, o.ID, StatusCompensated, "")
	})
}

func (s *Store) GetOrder(ctx context.Context, id string) (Order, error) {
	return scanOrder(s.db.QueryRowContext(ctx, selectOrder+` WHERE id = ?`, id))
}

func (s *Store) LedgerForOrder(ctx context.Context, orderID string) ([]LedgerEntry, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id, order_id, portfolio_id, asset, entry_type, amount, created_at
		FROM ledger_entries WHERE order_id = ? ORDER BY id`, orderID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	entries := []LedgerEntry{}
	for rows.Next() {
		var e LedgerEntry
		var created int64
		if err := rows.Scan(&e.ID, &e.OrderID, &e.PortfolioID, &e.Asset, &e.EntryType, &e.Amount, &created); err != nil {
			return nil, err
		}
		e.CreatedAt = time.UnixMilli(created).UTC()
		entries = append(entries, e)
	}
	return entries, rows.Err()
}

// Positions deriva el estado del portafolio agregando el ledger (event sourcing ligero).
func (s *Store) Positions(ctx context.Context, portfolioID string) ([]Position, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT asset, SUM(amount) AS total
		FROM ledger_entries
		WHERE portfolio_id = ?
		GROUP BY asset
		HAVING total <> 0
		ORDER BY asset`, portfolioID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	positions := []Position{}
	for rows.Next() {
		var p Position
		if err := rows.Scan(&p.Asset, &p.Amount); err != nil {
			return nil, err
		}
		positions = append(positions, p)
	}
	return positions, rows.Err()
}

// UndispatchedOrders retorna órdenes PENDING cuyo evento de outbox sigue sin publicar
// desde antes de olderThan: candidatas a re-despacho por el relay.
func (s *Store) UndispatchedOrders(ctx context.Context, olderThan time.Time, limit int) ([]Order, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT o.id, o.idempotency_key, o.portfolio_id, o.symbol, o.side,
			o.quantity, o.price_cents, o.status, COALESCE(o.failure_reason, ''), o.created_at, o.updated_at
		FROM outbox x
		JOIN orders o ON o.id = x.aggregate_id
		WHERE x.published_at IS NULL AND x.created_at <= ? AND o.status = 'PENDING'
		ORDER BY x.id
		LIMIT ?`, olderThan.UnixMilli(), limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	orders := []Order{}
	for rows.Next() {
		o, err := scanOrder(rows)
		if err != nil {
			return nil, err
		}
		orders = append(orders, o)
	}
	return orders, rows.Err()
}

// CountUndispatched mide el backlog del outbox; se usa para aplicar backpressure en la ingesta.
func (s *Store) CountUndispatched(ctx context.Context) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM outbox WHERE published_at IS NULL`).Scan(&n)
	return n, err
}

const selectOrder = `SELECT id, idempotency_key, portfolio_id, symbol, side, quantity, price_cents,
	status, COALESCE(failure_reason, ''), created_at, updated_at FROM orders`

type rowScanner interface {
	Scan(dest ...any) error
}

func scanOrder(r rowScanner) (Order, error) {
	var o Order
	var created, updated int64
	err := r.Scan(&o.ID, &o.IdempotencyKey, &o.PortfolioID, &o.Symbol, &o.Side, &o.Quantity,
		&o.PriceCents, &o.Status, &o.FailureReason, &created, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return Order{}, ErrNotFound
	}
	if err != nil {
		return Order{}, err
	}
	o.CreatedAt = time.UnixMilli(created).UTC()
	o.UpdatedAt = time.UnixMilli(updated).UTC()
	return o, nil
}

func (s *Store) appendLedger(ctx context.Context, tx *sql.Tx, o Order, asset, entryType string, amount int64) error {
	_, err := tx.ExecContext(ctx, `INSERT INTO ledger_entries
		(order_id, portfolio_id, asset, entry_type, amount, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		o.ID, o.PortfolioID, asset, entryType, amount, s.ms())
	return err
}

func (s *Store) setStatus(ctx context.Context, tx *sql.Tx, id, status, reason string) error {
	_, err := tx.ExecContext(ctx, `UPDATE orders SET status = ?, failure_reason = NULLIF(?, ''), updated_at = ?
		WHERE id = ?`, status, reason, s.ms(), id)
	return err
}

func (s *Store) inTx(ctx context.Context, fn func(*sql.Tx) error) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	if err := fn(tx); err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}

func (s *Store) ms() int64 { return s.now().UnixMilli() }
