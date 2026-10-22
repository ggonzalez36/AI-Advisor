// Package httpapi exposes the portfolio-api REST API. It translates HTTP <-> use cases and
// centralizes the mapping of domain errors to status codes.
package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"time"

	"fin-ai-advisor/portfolio-api/internal/domain"
	"fin-ai-advisor/portfolio-api/internal/engine"
	"fin-ai-advisor/portfolio-api/internal/orders"
	"fin-ai-advisor/portfolio-api/internal/store"
)

// Reader groups the read-only queries the API needs.
type Reader interface {
	Ping(ctx context.Context) error
	GetOrder(ctx context.Context, id string) (store.Order, error)
	LedgerForOrder(ctx context.Context, orderID string) ([]store.LedgerEntry, error)
	Positions(ctx context.Context, portfolioID string) ([]store.Position, error)
}

type MetricsSource interface {
	Metrics() engine.PoolMetrics
}

type API struct {
	svc     *orders.Service
	reader  Reader
	metrics MetricsSource
}

func New(svc *orders.Service, reader Reader, metrics MetricsSource) *API {
	return &API{svc: svc, reader: reader, metrics: metrics}
}

// Routes registers the endpoints using Go 1.22+ method and pattern routing.
func (a *API) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", a.health)
	mux.HandleFunc("GET /api/v1/metrics", a.getMetrics)
	mux.HandleFunc("POST /api/v1/orders/buy", a.placeBuyOrder)
	mux.HandleFunc("GET /api/v1/orders/{id}", a.getOrder)
	mux.HandleFunc("GET /api/v1/portfolios/{id}/positions", a.getPositions)
	return mux
}

type placeOrderRequest struct {
	PortfolioID     string `json:"portfolio_id"`
	Symbol          string `json:"symbol"`
	Quantity        int64  `json:"quantity"`
	Price           string `json:"price"` // Decimal as text ("185.50"): never float for money
	SimulateFailure bool   `json:"simulate_failure"`
}

type orderResponse struct {
	ID            string    `json:"id"`
	PortfolioID   string    `json:"portfolio_id"`
	Symbol        string    `json:"symbol"`
	Side          string    `json:"side"`
	Quantity      int64     `json:"quantity"`
	Price         string    `json:"price"`
	Total         string    `json:"total"`
	Status        string    `json:"status"`
	FailureReason string    `json:"failure_reason,omitempty"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

func toOrderResponse(o store.Order) orderResponse {
	return orderResponse{
		ID: o.ID, PortfolioID: o.PortfolioID, Symbol: o.Symbol, Side: o.Side, Quantity: o.Quantity,
		Price: domain.FormatCents(o.PriceCents), Total: domain.FormatCents(o.Quantity * o.PriceCents),
		Status: o.Status, FailureReason: o.FailureReason, CreatedAt: o.CreatedAt, UpdatedAt: o.UpdatedAt,
	}
}

// placeBuyOrder accepts the order asynchronously.
//   - 202 Accepted: new order persisted (the result is queried via GET /orders/{id})
//   - 200 OK: retry with the same Idempotency-Key; returns the original order
//   - 400 Bad Request: invalid payload or business rules
//   - 429 Too Many Requests: backlog exceeded (backpressure), with Retry-After
func (a *API) placeBuyOrder(w http.ResponseWriter, r *http.Request) {
	var req placeOrderRequest
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_JSON", "invalid JSON payload")
		return
	}

	priceCents, err := domain.ParseCents(req.Price)
	if err != nil {
		writeError(w, http.StatusBadRequest, "INVALID_PRICE", err.Error())
		return
	}

	res, err := a.svc.PlaceOrder(r.Context(), orders.PlaceOrderRequest{
		IdempotencyKey:  r.Header.Get("Idempotency-Key"),
		PortfolioID:     req.PortfolioID,
		Symbol:          req.Symbol,
		Quantity:        req.Quantity,
		PriceCents:      priceCents,
		SimulateFailure: req.SimulateFailure,
	})
	switch {
	case errors.Is(err, orders.ErrInvalidOrder):
		writeError(w, http.StatusBadRequest, "INVALID_ORDER", err.Error())
		return
	case errors.Is(err, orders.ErrBackpressure):
		w.Header().Set("Retry-After", "2")
		writeError(w, http.StatusTooManyRequests, "BACKPRESSURE", err.Error())
		return
	case err != nil:
		log.Printf("[HTTP] error placing order: %v", err)
		writeError(w, http.StatusInternalServerError, "INTERNAL", "internal error")
		return
	}

	status := http.StatusAccepted
	if !res.Created {
		status = http.StatusOK
	}
	w.Header().Set("Location", "/api/v1/orders/"+res.Order.ID)
	writeJSON(w, status, map[string]any{"order": toOrderResponse(res.Order), "dispatch": res.Dispatch})
}

func (a *API) getOrder(w http.ResponseWriter, r *http.Request) {
	o, err := a.reader.GetOrder(r.Context(), r.PathValue("id"))
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "NOT_FOUND", "order not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL", "internal error")
		return
	}
	ledger, err := a.reader.LedgerForOrder(r.Context(), o.ID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL", "internal error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"order": toOrderResponse(o), "ledger": ledger})
}

func (a *API) getPositions(w http.ResponseWriter, r *http.Request) {
	positions, err := a.reader.Positions(r.Context(), r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "INTERNAL", "internal error")
		return
	}

	type positionResponse struct {
		Asset  string `json:"asset"`
		Amount string `json:"amount"` // Cash as a decimal; positions as number of shares
	}
	out := make([]positionResponse, 0, len(positions))
	for _, p := range positions {
		amount := domain.FormatCents(p.Amount)
		if p.Asset != "USD" {
			amount = strconv.FormatInt(p.Amount, 10)
		}
		out = append(out, positionResponse{Asset: p.Asset, Amount: amount})
	}
	writeJSON(w, http.StatusOK, map[string]any{"portfolio_id": r.PathValue("id"), "positions": out})
}

func (a *API) health(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), time.Second)
	defer cancel()
	if err := a.reader.Ping(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "DOWN", "db": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"status": "UP", "service": "portfolio-api", "timestamp": time.Now().UTC().Format(time.RFC3339),
	})
}

func (a *API) getMetrics(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, a.metrics.Metrics())
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]string{"error": msg, "code": code})
}
