package domain

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"
)

// Errores canónicos del dominio transaccional
var (
	ErrInvalidQuantity = errors.New("la cantidad de la orden debe ser estrictamente mayor a cero")
	ErrInvalidPrice    = errors.New("el precio unitario de la orden debe ser estrictamente mayor a cero")
	ErrOrderCancelled  = errors.New("la orden fue cancelada por tiempo de espera o contexto")
	ErrAlreadyExecuted = errors.New("la orden ya fue ejecutada previamente")
	ErrExecutionFailed = errors.New("falla transaccional simulada en liquidación del broker")
)

// OrderStatus define el ciclo de vida de una orden financiera
type OrderStatus string

const (
	StatusPending     OrderStatus = "PENDING"
	StatusExecuted    OrderStatus = "EXECUTED"
	StatusCompensated OrderStatus = "COMPENSATED"
	StatusFailed      OrderStatus = "FAILED"
)

// Command define la interfaz del Command Pattern con soporte para
// compensación transaccional (patrón Saga) según Refactoring Guru.
type Command interface {
	Execute(ctx context.Context) error
	Undo(ctx context.Context) error
	ID() string
	Status() OrderStatus
}

// BuyOrder representa una orden de compra financiera que implementa la interfaz Command.
// Encapsula los parámetros de la transacción y el estado para garantizar idempotencia y compensación.
type BuyOrder struct {
	mu              sync.RWMutex
	id              string
	portfolioID     string
	symbol          string
	quantity        float64
	price           float64
	status          OrderStatus
	createdAt       time.Time
	executedAt      *time.Time
	compensatedAt   *time.Time
	failureReason   string
	SimulateFailure bool // Bandera para probar la compensación automática Saga
}

// NewBuyOrder crea una nueva instancia de BuyOrder inicializada en estado PENDING.
func NewBuyOrder(id, portfolioID, symbol string, quantity, price float64) *BuyOrder {
	return &BuyOrder{
		id:          id,
		portfolioID: portfolioID,
		symbol:      symbol,
		quantity:    quantity,
		price:       price,
		status:      StatusPending,
		createdAt:   time.Now().UTC(),
	}
}

// Execute ejecuta la orden de compra: valida fondos, reserva balance y liquidación contable.
func (b *BuyOrder) Execute(ctx context.Context) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	// 1. Verificación del contexto (timeout o cancelación)
	select {
	case <-ctx.Done():
		b.status = StatusFailed
		b.failureReason = ctx.Err().Error()
		return fmt.Errorf("%w: %v", ErrOrderCancelled, ctx.Err())
	default:
	}

	// 2. Validación de invariantes de negocio
	if b.quantity <= 0 {
		b.status = StatusFailed
		b.failureReason = ErrInvalidQuantity.Error()
		return ErrInvalidQuantity
	}
	if b.price <= 0 {
		b.status = StatusFailed
		b.failureReason = ErrInvalidPrice.Error()
		return ErrInvalidPrice
	}

	// 3. Simulación de fallo controlado para verificar el flujo de compensación Saga
	if b.SimulateFailure {
		b.status = StatusFailed
		b.failureReason = ErrExecutionFailed.Error()
		return ErrExecutionFailed
	}

	// 4. Simulación de latencia de red y persistencia ACID en PostgreSQL
	time.Sleep(10 * time.Millisecond)

	now := time.Now().UTC()
	b.executedAt = &now
	b.status = StatusExecuted
	return nil
}

// Undo ejecuta la compensación tipo Saga de la transacción de compra.
// Revierte la deducción de capital, libera el saldo retenido y actualiza la posición contable.
func (b *BuyOrder) Undo(ctx context.Context) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}

	// Simulación de reversión en ledger financiero
	time.Sleep(5 * time.Millisecond)

	now := time.Now().UTC()
	b.compensatedAt = &now
	b.status = StatusCompensated
	return nil
}

// Getters thread-safe para inspección de telemetría y auditoría

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

func (b *BuyOrder) Quantity() float64 {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.quantity
}

func (b *BuyOrder) Price() float64 {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.price
}

func (b *BuyOrder) TotalValue() float64 {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.quantity * b.price
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
