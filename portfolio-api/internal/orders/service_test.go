package orders_test

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"fin-ai-advisor/portfolio-api/internal/engine"
	"fin-ai-advisor/portfolio-api/internal/orders"
	"fin-ai-advisor/portfolio-api/internal/store"
)

type harness struct {
	repo *store.Store
	pool *engine.WorkerPool
	svc  *orders.Service
}

func newHarness(t *testing.T, startPool bool, maxBacklog int) *harness {
	t.Helper()
	repo, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "orders.db"))
	if err != nil {
		t.Fatal(err)
	}
	pool, _ := engine.NewWorkerPool(4, 100, 2)
	if startPool {
		pool.Start(context.Background())
	}
	t.Cleanup(func() {
		_ = pool.Shutdown(2 * time.Second)
		_ = repo.Close()
	})
	return &harness{repo: repo, pool: pool, svc: orders.NewService(repo, pool, maxBacklog)}
}

// waitForStatus espera a que el procesamiento asíncrono alcance el estado esperado.
func (h *harness) waitForStatus(t *testing.T, id, want string) store.Order {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		o, err := h.repo.GetOrder(context.Background(), id)
		if err == nil && o.Status == want {
			return o
		}
		if time.Now().After(deadline) {
			t.Fatalf("orden %s: se esperaba %s, último estado %q (err=%v)", id, want, o.Status, err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func buy(key string) orders.PlaceOrderRequest {
	return orders.PlaceOrderRequest{
		IdempotencyKey: key, PortfolioID: "port-1", Symbol: "nvda", Quantity: 4, PriceCents: 12000,
	}
}

func TestPlaceOrder_ExecutesAndUpdatesLedger(t *testing.T) {
	h := newHarness(t, true, 100)
	ctx := context.Background()

	res, err := h.svc.PlaceOrder(ctx, buy("k1"))
	if err != nil {
		t.Fatal(err)
	}
	if !res.Created || res.Dispatch != orders.DispatchImmediate || res.Order.Symbol != "NVDA" {
		t.Fatalf("resultado inesperado: %+v", res)
	}

	h.waitForStatus(t, res.Order.ID, store.StatusExecuted)

	positions, _ := h.repo.Positions(ctx, "port-1")
	if fmt.Sprint(positions) != fmt.Sprint([]store.Position{{Asset: "NVDA", Amount: 4}, {Asset: "USD", Amount: -48000}}) {
		t.Fatalf("posiciones inesperadas: %+v", positions)
	}
}

func TestPlaceOrder_IdempotentRetryDoesNotDuplicate(t *testing.T) {
	h := newHarness(t, true, 100)
	ctx := context.Background()

	first, _ := h.svc.PlaceOrder(ctx, buy("same-key"))
	h.waitForStatus(t, first.Order.ID, store.StatusExecuted)

	retry, err := h.svc.PlaceOrder(ctx, buy("same-key"))
	if err != nil {
		t.Fatal(err)
	}
	if retry.Created || retry.Dispatch != orders.DispatchReplay || retry.Order.ID != first.Order.ID {
		t.Fatalf("el reintento debió devolver la orden original: %+v", retry)
	}

	entries, _ := h.repo.LedgerForOrder(ctx, first.Order.ID)
	if len(entries) != 2 {
		t.Fatalf("se esperaban 2 asientos (débito + posición), obtenido %d", len(entries))
	}
}

func TestPlaceOrder_FailureIsCompensatedAndNetsToZero(t *testing.T) {
	h := newHarness(t, true, 100)
	ctx := context.Background()

	req := buy("k-fail")
	req.SimulateFailure = true
	res, _ := h.svc.PlaceOrder(ctx, req)

	o := h.waitForStatus(t, res.Order.ID, store.StatusCompensated)
	if o.FailureReason != "" {
		t.Logf("motivo registrado: %s", o.FailureReason)
	}

	positions, _ := h.repo.Positions(ctx, "port-1")
	if len(positions) != 0 {
		t.Fatalf("reserva + liberación deben netear a cero, obtenido %+v", positions)
	}
}

func TestRelay_RecoversOrdersPersistedButNeverDispatched(t *testing.T) {
	// Pool detenido: simula caída/saturación entre el commit y el despacho
	h := newHarness(t, false, 100)
	ctx := context.Background()

	res, err := h.svc.PlaceOrder(ctx, buy("k-crash"))
	if err != nil {
		t.Fatal(err)
	}
	if res.Dispatch != orders.DispatchDeferred {
		t.Fatalf("con el pool detenido el despacho debe diferirse, obtenido %s", res.Dispatch)
	}

	// "Reinicio": el pool vuelve y el relay barre el outbox
	h.pool.Start(ctx)
	relay := orders.NewRelay(h.svc, time.Hour, 0, 50)
	n, err := relay.DispatchOnce(ctx)
	if err != nil || n != 1 {
		t.Fatalf("el relay debió re-despachar 1 orden, obtenido n=%d err=%v", n, err)
	}

	h.waitForStatus(t, res.Order.ID, store.StatusExecuted)
	if pending, _ := h.repo.CountUndispatched(ctx); pending != 0 {
		t.Fatalf("el outbox debe quedar vacío, pendientes: %d", pending)
	}
}

func TestRelay_DuplicateDeliveryExecutesOnce(t *testing.T) {
	h := newHarness(t, true, 100)
	ctx := context.Background()

	res, _ := h.svc.PlaceOrder(ctx, buy("k-dup"))
	// El relay corre antes de que el worker reclame la orden: entrega duplicada
	relay := orders.NewRelay(h.svc, time.Hour, -time.Second, 50)
	_, _ = relay.DispatchOnce(ctx)

	h.waitForStatus(t, res.Order.ID, store.StatusExecuted)
	_ = h.pool.Shutdown(2 * time.Second)

	entries, _ := h.repo.LedgerForOrder(ctx, res.Order.ID)
	if len(entries) != 2 {
		t.Fatalf("la orden debe ejecutarse una sola vez (2 asientos), obtenido %d", len(entries))
	}
	m := h.pool.Metrics()
	if m.TotalExecuted != 1 {
		t.Fatalf("se esperaba 1 ejecución, métricas: %+v", m)
	}
}

func TestPlaceOrder_BackpressureWhenBacklogFull(t *testing.T) {
	h := newHarness(t, false, 2) // Pool detenido: todo queda pendiente en el outbox
	ctx := context.Background()

	for i := 0; i < 2; i++ {
		if _, err := h.svc.PlaceOrder(ctx, buy(fmt.Sprintf("bp-%d", i))); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := h.svc.PlaceOrder(ctx, buy("bp-overflow")); !errors.Is(err, orders.ErrBackpressure) {
		t.Fatalf("se esperaba ErrBackpressure, obtenido %v", err)
	}
}

func TestPlaceOrder_Validation(t *testing.T) {
	h := newHarness(t, true, 100)
	bad := []orders.PlaceOrderRequest{
		{PortfolioID: "", Symbol: "AAPL", Quantity: 1, PriceCents: 100},
		{PortfolioID: "p", Symbol: " ", Quantity: 1, PriceCents: 100},
		{PortfolioID: "p", Symbol: "AAPL", Quantity: 0, PriceCents: 100},
		{PortfolioID: "p", Symbol: "AAPL", Quantity: 1, PriceCents: 0},
	}
	for _, req := range bad {
		if _, err := h.svc.PlaceOrder(context.Background(), req); !errors.Is(err, orders.ErrInvalidOrder) {
			t.Errorf("%+v: se esperaba ErrInvalidOrder, obtenido %v", req, err)
		}
	}
}
