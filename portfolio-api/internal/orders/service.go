// Package orders orquesta el caso de uso "colocar orden": persistencia durable (outbox),
// despacho al worker pool y recuperación ante caídas (relay). Es la capa de aplicación
// entre la API HTTP, el dominio puro y la infraestructura (store, engine).
package orders

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"

	"fin-ai-advisor/portfolio-api/internal/domain"
	"fin-ai-advisor/portfolio-api/internal/store"
)

var (
	ErrInvalidOrder = errors.New("orden inválida")
	ErrBackpressure = errors.New("backlog de órdenes pendientes excedido")
)

// Dispatch describe cómo se despachó una orden aceptada.
const (
	DispatchImmediate = "immediate" // Encolada en el worker pool en la misma petición
	DispatchDeferred  = "deferred"  // Pool saturado: persistida, el relay la despachará
	DispatchReplay    = "replay"    // Idempotency key repetida: se devuelve la orden original
)

// Repository es el puerto de persistencia que requiere el servicio (implementado por store.Store).
type Repository interface {
	CreateOrder(ctx context.Context, o store.Order) (store.Order, bool, error)
	ClaimOrder(ctx context.Context, orderID string) (bool, error)
	MarkExecuted(ctx context.Context, o store.Order) error
	MarkFailed(ctx context.Context, o store.Order, reason string, fundsReserved bool) error
	MarkCompensated(ctx context.Context, o store.Order) error
	UndispatchedOrders(ctx context.Context, olderThan time.Time, limit int) ([]store.Order, error)
	CountUndispatched(ctx context.Context) (int, error)
}

// Dispatcher es el puerto hacia el motor de ejecución concurrente (implementado por engine.WorkerPool).
type Dispatcher interface {
	Submit(cmd domain.Command) error
}

type PlaceOrderRequest struct {
	IdempotencyKey  string
	PortfolioID     string
	Symbol          string
	Quantity        int64
	PriceCents      int64
	SimulateFailure bool // Solo demo: fuerza falla en liquidación para mostrar la compensación
}

type PlaceOrderResult struct {
	Order    store.Order
	Created  bool
	Dispatch string
}

type Service struct {
	repo       Repository
	dispatcher Dispatcher
	maxBacklog int
	newID      func() string
}

// NewService crea el servicio. maxBacklog limita las órdenes pendientes de despacho
// antes de responder 429: protege la BD cuando los workers no dan abasto.
func NewService(repo Repository, dispatcher Dispatcher, maxBacklog int) *Service {
	return &Service{repo: repo, dispatcher: dispatcher, maxBacklog: maxBacklog, newID: newOrderID}
}

// PlaceOrder valida, persiste (orden + outbox en una transacción) y despacha la orden.
// La respuesta al cliente depende solo de la persistencia: si el pool está saturado la
// orden queda durable y el relay la despacha después (at-least-once).
func (s *Service) PlaceOrder(ctx context.Context, req PlaceOrderRequest) (PlaceOrderResult, error) {
	req.Symbol = strings.ToUpper(strings.TrimSpace(req.Symbol))
	req.PortfolioID = strings.TrimSpace(req.PortfolioID)

	switch {
	case req.PortfolioID == "":
		return PlaceOrderResult{}, fmt.Errorf("%w: portfolio_id requerido", ErrInvalidOrder)
	case req.Symbol == "":
		return PlaceOrderResult{}, fmt.Errorf("%w: symbol requerido", ErrInvalidOrder)
	case req.Quantity <= 0:
		return PlaceOrderResult{}, fmt.Errorf("%w: %v", ErrInvalidOrder, domain.ErrInvalidQuantity)
	case req.PriceCents <= 0:
		return PlaceOrderResult{}, fmt.Errorf("%w: %v", ErrInvalidOrder, domain.ErrInvalidPrice)
	}

	id := s.newID()
	if req.IdempotencyKey == "" {
		req.IdempotencyKey = id // Sin key el cliente renuncia a reintentos seguros
	}

	backlog, err := s.repo.CountUndispatched(ctx)
	if err != nil {
		return PlaceOrderResult{}, err
	}
	if backlog >= s.maxBacklog {
		return PlaceOrderResult{}, ErrBackpressure
	}

	rec, created, err := s.repo.CreateOrder(ctx, store.Order{
		ID: id, IdempotencyKey: req.IdempotencyKey, PortfolioID: req.PortfolioID,
		Symbol: req.Symbol, Side: "BUY", Quantity: req.Quantity, PriceCents: req.PriceCents,
	})
	if err != nil {
		return PlaceOrderResult{}, err
	}
	if !created {
		return PlaceOrderResult{Order: rec, Created: false, Dispatch: DispatchReplay}, nil
	}

	dispatch := DispatchImmediate
	if err := s.dispatcher.Submit(s.command(rec, req.SimulateFailure)); err != nil {
		dispatch = DispatchDeferred
	}
	return PlaceOrderResult{Order: rec, Created: true, Dispatch: dispatch}, nil
}

// command construye el Command de dominio envuelto en el decorador de persistencia.
func (s *Service) command(rec store.Order, simulateFailure bool) domain.Command {
	order := domain.NewBuyOrder(rec.ID, rec.PortfolioID, rec.Symbol, rec.Quantity, rec.PriceCents)
	order.SimulateFailure = simulateFailure
	return &persistentOrder{inner: order, rec: rec, repo: s.repo}
}

func newOrderID() string {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	return "ord_" + hex.EncodeToString(b)
}
