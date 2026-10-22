package domain_test

import (
	"context"
	"errors"
	"testing"

	"fin-ai-advisor/portfolio-api/internal/domain"
)

func TestBuyOrder_ExecuteSuccess(t *testing.T) {
	ctx := context.Background()
	order := domain.NewBuyOrder("ord-1", "port-100", "AAPL", 10, 18550)

	if order.Status() != domain.StatusPending {
		t.Fatalf("expected PENDING status, got: %s", order.Status())
	}

	err := order.Execute(ctx)
	if err != nil {
		t.Fatalf("unexpected error in Execute: %v", err)
	}

	if order.Status() != domain.StatusExecuted {
		t.Fatalf("expected EXECUTED status, got: %s", order.Status())
	}

	expectedTotal := int64(10 * 18550)
	if order.TotalValueCents() != expectedTotal {
		t.Fatalf("expected total value %d, got: %d", expectedTotal, order.TotalValueCents())
	}
}

func TestBuyOrder_ExecuteValidationFailure(t *testing.T) {
	ctx := context.Background()

	// Invalid quantity
	invalidQtyOrder := domain.NewBuyOrder("ord-2", "port-100", "MSFT", 0, 42000)
	if err := invalidQtyOrder.Execute(ctx); err == nil {
		t.Fatal("expected error for quantity <= 0, but got nil")
	}

	// Invalid price
	invalidPriceOrder := domain.NewBuyOrder("ord-3", "port-100", "NVDA", 5, -1000)
	if err := invalidPriceOrder.Execute(ctx); err == nil {
		t.Fatal("expected error for price <= 0, but got nil")
	}
}

func TestBuyOrder_SagaCompensation(t *testing.T) {
	ctx := context.Background()
	order := domain.NewBuyOrder("ord-4", "port-200", "GOOGL", 15, 17500)
	order.SimulateFailure = true

	// Execution must fail
	err := order.Execute(ctx)
	if err == nil {
		t.Fatal("expected simulated execution failure")
	}

	if order.Status() != domain.StatusFailed {
		t.Fatalf("expected FAILED status, got: %s", order.Status())
	}

	// Run Undo (Saga compensation)
	undoErr := order.Undo(ctx)
	if undoErr != nil {
		t.Fatalf("unexpected error in Undo: %v", undoErr)
	}

	if order.Status() != domain.StatusCompensated {
		t.Fatalf("expected COMPENSATED status, got: %s", order.Status())
	}
}

func TestBuyOrder_UndoIsIdempotent(t *testing.T) {
	ctx := context.Background()
	order := domain.NewBuyOrder("ord-6", "port-200", "AMZN", 3, 18000)
	order.SimulateFailure = true
	_ = order.Execute(ctx)

	if err := order.Undo(ctx); err != nil {
		t.Fatalf("first Undo unexpectedly failed: %v", err)
	}
	if err := order.Undo(ctx); err != nil {
		t.Fatalf("second Undo should be a no-op, got: %v", err)
	}
	if order.Status() != domain.StatusCompensated {
		t.Fatalf("expected COMPENSATED status, got: %s", order.Status())
	}
}

func TestBuyOrder_UndoWithoutSideEffects(t *testing.T) {
	ctx := context.Background()
	order := domain.NewBuyOrder("ord-7", "port-100", "MSFT", 0, 42000)
	_ = order.Execute(ctx) // Fails validation, before reserving funds

	if err := order.Undo(ctx); !errors.Is(err, domain.ErrNothingToCompensate) {
		t.Fatalf("expected ErrNothingToCompensate, got: %v", err)
	}
	if order.Status() != domain.StatusFailed {
		t.Fatalf("order should remain FAILED, got: %s", order.Status())
	}
}

func TestBuyOrder_ExecuteTwiceRejected(t *testing.T) {
	ctx := context.Background()
	order := domain.NewBuyOrder("ord-8", "port-100", "AAPL", 1, 10000)
	if err := order.Execute(ctx); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if err := order.Execute(ctx); !errors.Is(err, domain.ErrAlreadyExecuted) {
		t.Fatalf("expected ErrAlreadyExecuted, got: %v", err)
	}
}

func TestBuyOrder_ContextCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // Cancelled before execution

	order := domain.NewBuyOrder("ord-5", "port-300", "TSLA", 2, 21000)
	err := order.Execute(ctx)
	if err == nil {
		t.Fatal("expected error due to cancelled context")
	}

	if order.Status() != domain.StatusFailed {
		t.Fatalf("expected FAILED status, got: %s", order.Status())
	}
}
