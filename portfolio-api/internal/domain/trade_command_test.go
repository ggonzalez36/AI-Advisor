package domain_test

import (
	"context"
	"testing"

	"fin-ai-advisor/portfolio-api/internal/domain"
)

func TestBuyOrder_ExecuteSuccess(t *testing.T) {
	ctx := context.Background()
	order := domain.NewBuyOrder("ord-1", "port-100", "AAPL", 10, 185.50)

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

	expectedTotal := 10 * 185.50
	if order.TotalValue() != expectedTotal {
		t.Fatalf("se esperaba valor total %f, obtenido: %f", expectedTotal, order.TotalValue())
	}
}

func TestBuyOrder_ExecuteValidationFailure(t *testing.T) {
	ctx := context.Background()

	// Cantidad inválida
	invalidQtyOrder := domain.NewBuyOrder("ord-2", "port-100", "MSFT", 0, 420.0)
	if err := invalidQtyOrder.Execute(ctx); err == nil {
		t.Fatal("se esperaba error por cantidad <= 0, pero retornó nil")
	}

	// Precio inválido
	invalidPriceOrder := domain.NewBuyOrder("ord-3", "port-100", "NVDA", 5, -10.0)
	if err := invalidPriceOrder.Execute(ctx); err == nil {
		t.Fatal("se esperaba error por precio <= 0, pero retornó nil")
	}
}

func TestBuyOrder_SagaCompensation(t *testing.T) {
	ctx := context.Background()
	order := domain.NewBuyOrder("ord-4", "port-200", "GOOGL", 15, 175.0)
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

func TestBuyOrder_ContextCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // Cancelado antes de ejecutar

	order := domain.NewBuyOrder("ord-5", "port-300", "TSLA", 2, 210.0)
	err := order.Execute(ctx)
	if err == nil {
		t.Fatal("se esperaba error por contexto cancelado")
	}

	if order.Status() != domain.StatusFailed {
		t.Fatalf("se esperaba estado FAILED, obtenido: %s", order.Status())
	}
}
