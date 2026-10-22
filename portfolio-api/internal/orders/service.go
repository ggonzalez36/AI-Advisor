// Package orders orchestrates the "place order" use case: durable persistence (outbox),
// dispatch to the worker pool, and crash recovery (relay). It is the application layer
// between the HTTP API, the pure domain, and the infrastructure (store, engine).
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
	ErrInvalidOrder = errors.New("invalid order")
	ErrBackpressure = errors.New("pending order backlog exceeded")
)

// Dispatch describes how an accepted order was dispatched.
const (
	DispatchImmediate = "immediate" // Enqueued in the worker pool within the same request
	DispatchDeferred  = "deferred"  // Pool saturated: persisted, the relay will dispatch it
	DispatchReplay    = "replay"    // Repeated idempotency key: the original order is returned
)

// Repository is the persistence port the service requires (implemented by store.Store).
type Repository interface {
	CreateOrder(ctx context.Context, o store.Order) (store.Order, bool, error)
	ClaimOrder(ctx context.Context, orderID string) (bool, error)
	MarkExecuted(ctx context.Context, o store.Order) error
	MarkFailed(ctx context.Context, o store.Order, reason string, fundsReserved bool) error
	MarkCompensated(ctx context.Context, o store.Order) error
	UndispatchedOrders(ctx context.Context, olderThan time.Time, limit int) ([]store.Order, error)
	CountUndispatched(ctx context.Context) (int, error)
}

// Dispatcher is the port to the concurrent execution engine (implemented by engine.WorkerPool).
type Dispatcher interface {
	Submit(cmd domain.Command) error
}

type PlaceOrderRequest struct {
	IdempotencyKey  string
	PortfolioID     string
	Symbol          string
	Quantity        int64
	PriceCents      int64
	SimulateFailure bool // Demo only: forces a settlement failure to showcase compensation
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

// NewService creates the service. maxBacklog caps the orders pending dispatch
// before responding 429: it protects the DB when the workers cannot keep up.
func NewService(repo Repository, dispatcher Dispatcher, maxBacklog int) *Service {
	return &Service{repo: repo, dispatcher: dispatcher, maxBacklog: maxBacklog, newID: newOrderID}
}

// PlaceOrder validates, persists (order + outbox in one transaction), and dispatches the order.
// The response to the client depends only on persistence: if the pool is saturated the
// order remains durable and the relay dispatches it later (at-least-once).
func (s *Service) PlaceOrder(ctx context.Context, req PlaceOrderRequest) (PlaceOrderResult, error) {
	req.Symbol = strings.ToUpper(strings.TrimSpace(req.Symbol))
	req.PortfolioID = strings.TrimSpace(req.PortfolioID)

	switch {
	case req.PortfolioID == "":
		return PlaceOrderResult{}, fmt.Errorf("%w: portfolio_id is required", ErrInvalidOrder)
	case req.Symbol == "":
		return PlaceOrderResult{}, fmt.Errorf("%w: symbol is required", ErrInvalidOrder)
	case req.Quantity <= 0:
		return PlaceOrderResult{}, fmt.Errorf("%w: %v", ErrInvalidOrder, domain.ErrInvalidQuantity)
	case req.PriceCents <= 0:
		return PlaceOrderResult{}, fmt.Errorf("%w: %v", ErrInvalidOrder, domain.ErrInvalidPrice)
	}

	id := s.newID()
	if req.IdempotencyKey == "" {
		req.IdempotencyKey = id // Without a key the client gives up safe retries
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

// command builds the domain Command wrapped in the persistence decorator.
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
