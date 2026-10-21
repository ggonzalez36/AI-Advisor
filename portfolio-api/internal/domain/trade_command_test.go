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
		t.Fatalf("se esperaba estado PENDING, obtenido: %s", order.Status())
	}

	err := order.Execute(ctx)
	if err != nil {
		t.Fatalf("error inesperado en Execute: %v", err)
	}

	if order.Status() != domain.StatusExecuted {
		t.Fatalf("se esperaba estado EXECUTED, obtenido: %s", order.Status())
	}

	expectedTotal := int64(10 * 18550)
	if order.TotalValueCents() != expectedTotal {
		t.Fatalf("se esperaba valor total %d, obtenido: %d", expectedTotal, order.TotalValueCents())
	}
}

func TestBuyOrder_ExecuteValidationFailure(t *testing.T) {
	ctx := context.Background()

	// Cantidad inválida
	invalidQtyOrder := domain.NewBuyOrder("ord-2", "port-100", "MSFT", 0, 42000)
	if err := invalidQtyOrder.Execute(ctx); err == nil {
		t.Fatal("se esperaba error por cantidad <= 0, pero retornó nil")
	}

	// Precio inválido
	invalidPriceOrder := domain.NewBuyOrder("ord-3", "port-100", "NVDA", 5, -1000)
	if err := invalidPriceOrder.Execute(ctx); err == nil {
		t.Fatal("se esperaba error por precio <= 0, pero retornó nil")
	}
}

func TestBuyOrder_SagaCompensation(t *testing.T) {
	ctx := context.Background()
	order := domain.NewBuyOrder("ord-4", "port-200", "GOOGL", 15, 17500)
	order.SimulateFailure = true

	// La ejecución debe fallar
	err := order.Execute(ctx)
	if err == nil {
		t.Fatal("se esperaba falla en ejecución simulada")
	}

	if order.Status() != domain.StatusFailed {
		t.Fatalf("se esperaba estado FAILED, obtenido: %s", order.Status())
	}

	// Ejecución de Undo (Saga compensation)
	undoErr := order.Undo(ctx)
	if undoErr != nil {
		t.Fatalf("error inesperado en Undo: %v", undoErr)
	}

	if order.Status() != domain.StatusCompensated {
		t.Fatalf("se esperaba estado COMPENSATED, obtenido: %s", order.Status())
	}
}

func TestBuyOrder_UndoIsIdempotent(t *testing.T) {
	ctx := context.Background()
	order := domain.NewBuyOrder("ord-6", "port-200", "AMZN", 3, 18000)
	order.SimulateFailure = true
	_ = order.Execute(ctx)

	if err := order.Undo(ctx); err != nil {
		t.Fatalf("primer Undo inesperadamente falló: %v", err)
	}
	if err := order.Undo(ctx); err != nil {
		t.Fatalf("segundo Undo debe ser no-op, obtenido: %v", err)
	}
	if order.Status() != domain.StatusCompensated {
		t.Fatalf("se esperaba estado COMPENSATED, obtenido: %s", order.Status())
	}
}

func TestBuyOrder_UndoWithoutSideEffects(t *testing.T) {
	ctx := context.Background()
	order := domain.NewBuyOrder("ord-7", "port-100", "MSFT", 0, 42000)
	_ = order.Execute(ctx) // Falla en validación, antes de reservar fondos

	if err := order.Undo(ctx); !errors.Is(err, domain.ErrNothingToCompensate) {
		t.Fatalf("se esperaba ErrNothingToCompensate, obtenido: %v", err)
	}
	if order.Status() != domain.StatusFailed {
		t.Fatalf("la orden debe permanecer FAILED, obtenido: %s", order.Status())
	}
}

func TestBuyOrder_ExecuteTwiceRejected(t *testing.T) {
	ctx := context.Background()
	order := domain.NewBuyOrder("ord-8", "port-100", "AAPL", 1, 10000)
	if err := order.Execute(ctx); err != nil {
		t.Fatalf("error inesperado: %v", err)
	}
	if err := order.Execute(ctx); !errors.Is(err, domain.ErrAlreadyExecuted) {
		t.Fatalf("se esperaba ErrAlreadyExecuted, obtenido: %v", err)
	}
}

func TestBuyOrder_ContextCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // Cancelado antes de ejecutar

	order := domain.NewBuyOrder("ord-5", "port-300", "TSLA", 2, 21000)
	err := order.Execute(ctx)
	if err == nil {
		t.Fatal("se esperaba error por contexto cancelado")
	}

	if order.Status() != domain.StatusFailed {
		t.Fatalf("se esperaba estado FAILED, obtenido: %s", order.Status())
	}
}
