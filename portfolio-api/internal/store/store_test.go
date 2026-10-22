package store_test

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"fin-ai-advisor/portfolio-api/internal/store"
)

func openTestStore(t *testing.T) *store.Store {
	t.Helper()
	s, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatalf("opening store: %v", err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func newOrder(id, key string) store.Order {
	return store.Order{
		ID: id, IdempotencyKey: key, PortfolioID: "port-1", Symbol: "AAPL",
		Side: "BUY", Quantity: 10, PriceCents: 18550,
	}
}

func TestCreateOrder_IsIdempotent(t *testing.T) {
	ctx := context.Background()
	s := openTestStore(t)

	first, created, err := s.CreateOrder(ctx, newOrder("ord-1", "key-1"))
	if err != nil || !created {
		t.Fatalf("first creation: created=%v err=%v", created, err)
	}

	// Client retry with the same key but a different generated ID
	second, created, err := s.CreateOrder(ctx, newOrder("ord-2", "key-1"))
	if err != nil {
		t.Fatalf("retry: %v", err)
	}
	if created || second.ID != first.ID {
		t.Fatalf("expected the original order %s without creating another, got %s created=%v", first.ID, second.ID, created)
	}

	if n, _ := s.CountUndispatched(ctx); n != 1 {
		t.Fatalf("expected 1 outbox event, got %d", n)
	}
}

func TestCreateOrder_RejectsInvalidRowsAtSchemaLevel(t *testing.T) {
	s := openTestStore(t)
	bad := newOrder("ord-bad", "key-bad")
	bad.Quantity = 0

	if _, _, err := s.CreateOrder(context.Background(), bad); err == nil {
		t.Fatal("expected a CHECK violation (quantity > 0)")
	}
}

func TestClaimOrder_OnlyOneWinnerUnderConcurrency(t *testing.T) {
	ctx := context.Background()
	s := openTestStore(t)
	if _, _, err := s.CreateOrder(ctx, newOrder("ord-1", "key-1")); err != nil {
		t.Fatal(err)
	}

	var winners atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ok, err := s.ClaimOrder(ctx, "ord-1")
			if err != nil {
				t.Errorf("claim: %v", err)
			}
			if ok {
				winners.Add(1)
			}
		}()
	}
	wg.Wait()

	if winners.Load() != 1 {
		t.Fatalf("expected exactly 1 successful claim, got %d", winners.Load())
	}
	if n, _ := s.CountUndispatched(ctx); n != 0 {
		t.Fatalf("the event must be marked published after the claim, pending: %d", n)
	}
}

func TestLedger_IsAppendOnly(t *testing.T) {
	ctx := context.Background()
	s := openTestStore(t)
	o, _, _ := s.CreateOrder(ctx, newOrder("ord-1", "key-1"))
	_, _ = s.ClaimOrder(ctx, o.ID)
	if err := s.MarkExecuted(ctx, o); err != nil {
		t.Fatal(err)
	}

	for _, stmt := range []string{
		"UPDATE ledger_entries SET amount = 0",
		"DELETE FROM ledger_entries",
	} {
		err := s.ExecRawForTest(ctx, stmt)
		if err == nil || !strings.Contains(err.Error(), "append-only") {
			t.Fatalf("%q should have been rejected by a trigger, got: %v", stmt, err)
		}
	}
}

func TestPositions_ExecutedAndCompensatedOrders(t *testing.T) {
	ctx := context.Background()
	s := openTestStore(t)

	// Executed order: -1855.00 USD, +10 AAPL
	ok, _, _ := s.CreateOrder(ctx, newOrder("ord-ok", "key-ok"))
	_, _ = s.ClaimOrder(ctx, ok.ID)
	if err := s.MarkExecuted(ctx, ok); err != nil {
		t.Fatal(err)
	}

	// Order failed after reserving funds and then compensated: zero net effect
	failed, _, _ := s.CreateOrder(ctx, newOrder("ord-fail", "key-fail"))
	_, _ = s.ClaimOrder(ctx, failed.ID)
	if err := s.MarkFailed(ctx, failed, "broker down", true); err != nil {
		t.Fatal(err)
	}
	if err := s.MarkCompensated(ctx, failed); err != nil {
		t.Fatal(err)
	}
	if err := s.MarkCompensated(ctx, failed); err != nil { // idempotent
		t.Fatal(err)
	}

	positions, err := s.Positions(ctx, "port-1")
	if err != nil {
		t.Fatal(err)
	}
	got := fmt.Sprint(positions)
	want := fmt.Sprint([]store.Position{{Asset: "AAPL", Amount: 10}, {Asset: "USD", Amount: -185500}})
	if got != want {
		t.Fatalf("positions: expected %s, got %s", want, got)
	}

	entries, _ := s.LedgerForOrder(ctx, failed.ID)
	if len(entries) != 2 {
		t.Fatalf("the compensated order must have reservation + release (2 ledger entries), got %d", len(entries))
	}
	if o, _ := s.GetOrder(ctx, failed.ID); o.Status != store.StatusCompensated {
		t.Fatalf("expected status COMPENSATED, got %s", o.Status)
	}
}

func TestUndispatchedOrders_ReturnsOnlyStalePending(t *testing.T) {
	ctx := context.Background()
	s := openTestStore(t)
	_, _, _ = s.CreateOrder(ctx, newOrder("ord-stale", "key-1"))
	_, _, _ = s.CreateOrder(ctx, newOrder("ord-claimed", "key-2"))
	_, _ = s.ClaimOrder(ctx, "ord-claimed")

	none, _ := s.UndispatchedOrders(ctx, time.Now().Add(-time.Hour), 10)
	if len(none) != 0 {
		t.Fatalf("no order is older than 1h, got %d", len(none))
	}

	stale, err := s.UndispatchedOrders(ctx, time.Now().Add(time.Second), 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(stale) != 1 || stale[0].ID != "ord-stale" {
		t.Fatalf("expected only ord-stale, got %+v", stale)
	}
}
