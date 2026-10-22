package domain

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"
)

// Canonical errors of the transactional domain
var (
	ErrInvalidQuantity = errors.New("order quantity must be strictly greater than zero")
	ErrInvalidPrice    = errors.New("order unit price must be strictly greater than zero")
	ErrOrderCancelled  = errors.New("order was cancelled due to timeout or context")
	ErrAlreadyExecuted = errors.New("order has already been executed")
	ErrExecutionFailed = errors.New("simulated transactional failure during broker settlement")
	// ErrNothingToCompensate indicates the order produced no side effects (e.g. validation failed)
	// and therefore there is no prior step to revert.
	ErrNothingToCompensate = errors.New("order has no prior side effects to compensate")
)

// OrderStatus defines the lifecycle of a financial order
type OrderStatus string

const (
	StatusPending     OrderStatus = "PENDING"
	StatusExecuted    OrderStatus = "EXECUTED"
	StatusCompensated OrderStatus = "COMPENSATED"
	StatusFailed      OrderStatus = "FAILED"
)

// Command defines the Command Pattern interface with support for
// transactional compensation (Saga pattern) as described by Refactoring Guru.
type Command interface {
	Execute(ctx context.Context) error
	Undo(ctx context.Context) error
	ID() string
	Status() OrderStatus
}

// BuyOrder represents a financial buy order that implements the Command interface.
// It encapsulates the transaction parameters and state to guarantee idempotency and compensation.
type BuyOrder struct {
	mu              sync.RWMutex
	id              string
	portfolioID     string
	symbol          string
	quantity        int64 // Whole shares
	priceCents      int64 // Unit price in cents (integers: no float rounding errors)
	status          OrderStatus
	fundsReserved   bool // Saga step 1 completed: capital held
	createdAt       time.Time
	executedAt      *time.Time
	compensatedAt   *time.Time
	failureReason   string
	SimulateFailure bool // Flag to test automatic Saga compensation
}

// NewBuyOrder creates a new BuyOrder instance initialized in the PENDING state.
func NewBuyOrder(id, portfolioID, symbol string, quantity, priceCents int64) *BuyOrder {
	return &BuyOrder{
		id:          id,
		portfolioID: portfolioID,
		symbol:      symbol,
		quantity:    quantity,
		priceCents:  priceCents,
		status:      StatusPending,
		createdAt:   time.Now().UTC(),
	}
}

// Execute runs the buy order as a two-step Saga:
// (1) capital reservation and (2) broker settlement. If step 2 fails,
// step 1 remains applied and must be reverted with Undo.
func (b *BuyOrder) Execute(ctx context.Context) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.status != StatusPending {
		return ErrAlreadyExecuted
	}

	// 1. Context check (timeout or cancellation)
	select {
	case <-ctx.Done():
		b.status = StatusFailed
		b.failureReason = ctx.Err().Error()
		return fmt.Errorf("%w: %v", ErrOrderCancelled, ctx.Err())
	default:
	}

	// 2. Business invariant validation
	if b.quantity <= 0 {
		b.status = StatusFailed
		b.failureReason = ErrInvalidQuantity.Error()
		return ErrInvalidQuantity
	}
	if b.priceCents <= 0 {
		b.status = StatusFailed
		b.failureReason = ErrInvalidPrice.Error()
		return ErrInvalidPrice
	}

	// 3. Saga step 1: capital reservation (side effect that requires compensation if something fails later)
	b.fundsReserved = true

	// 4. Saga step 2: broker settlement (controlled failure to test compensation)
	if b.SimulateFailure {
		b.status = StatusFailed
		b.failureReason = ErrExecutionFailed.Error()
		return ErrExecutionFailed
	}

	// Simulated network latency and ACID persistence in PostgreSQL
	time.Sleep(10 * time.Millisecond)

	now := time.Now().UTC()
	b.executedAt = &now
	b.status = StatusExecuted
	return nil
}

// Undo performs the Saga-style compensation of the buy transaction.
// It reverts the capital deduction, releases the held balance, and updates the accounting position.
// It is idempotent: calling it again on an already compensated order has no effect.
func (b *BuyOrder) Undo(ctx context.Context) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.status == StatusCompensated {
		return nil
	}
	if !b.fundsReserved {
		return ErrNothingToCompensate
	}

	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}

	// Simulated reversal in the financial ledger
	time.Sleep(5 * time.Millisecond)

	now := time.Now().UTC()
	b.compensatedAt = &now
	b.fundsReserved = false
	b.status = StatusCompensated
	return nil
}

// Thread-safe getters for telemetry and audit inspection

func (b *BuyOrder) ID() string {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.id
}

func (b *BuyOrder) PortfolioID() string {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.portfolioID
}

func (b *BuyOrder) Symbol() string {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.symbol
}

func (b *BuyOrder) Quantity() int64 {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.quantity
}

func (b *BuyOrder) PriceCents() int64 {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.priceCents
}

// TotalValueCents returns the total order amount in cents.
func (b *BuyOrder) TotalValueCents() int64 {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.quantity * b.priceCents
}

func (b *BuyOrder) Status() OrderStatus {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.status
}

func (b *BuyOrder) FailureReason() string {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.failureReason
}

func (b *BuyOrder) FundsReserved() bool {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.fundsReserved
}

func (b *BuyOrder) CreatedAt() time.Time {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.createdAt
}
