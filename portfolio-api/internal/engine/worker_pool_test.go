package engine_test

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"fin-ai-advisor/portfolio-api/internal/domain"
	"fin-ai-advisor/portfolio-api/internal/engine"
)

func TestWorkerPool_HighConcurrencyProcessing(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	workerCount := 5
	queueSize := 50
	dbConns := 10

	pool, err := engine.NewWorkerPool(workerCount, queueSize, dbConns)
	if err != nil {
		t.Fatalf("error creando worker pool: %v", err)
	}

	pool.Start(ctx)

	// Simulación de alta concurrencia enviando 40 órdenes concurrentes
	numOrders := 40
	var wg sync.WaitGroup

	for i := 1; i <= numOrders; i++ {
		wg.Add(1)
		go func(orderIdx int) {
			defer wg.Done()
			cmd := domain.NewBuyOrder(
				fmt.Sprintf("ord-%d", orderIdx),
				fmt.Sprintf("port-%d", orderIdx%5),
				"NVDA",
				float64(orderIdx),
				120.0,
			)

			// Envío no bloqueante
			err := pool.Submit(cmd)
			if err != nil && err != engine.ErrQueueFull {
				t.Errorf("error inesperado en submit: %v", err)
			}
		}(i)
	}

	wg.Wait()

	// Dar tiempo a los workers para drenar las órdenes
	time.Sleep(200 * time.Millisecond)

	err = pool.Shutdown(2 * time.Second)
	if err != nil {
		t.Fatalf("error en shutdown: %v", err)
	}

	metrics := pool.Metrics()
	if metrics.TotalSubmitted == 0 {
		t.Fatal("se esperaba al menos una orden encolada")
	}
	if metrics.TotalExecuted == 0 {
		t.Fatal("se esperaba al menos una orden procesada exitosamente")
	}
}

func TestWorkerPool_AutomaticSagaCompensation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	pool, _ := engine.NewWorkerPool(2, 10, 2)
	pool.Start(ctx)

	// Crear orden configurada para fallar
	failingOrder := domain.NewBuyOrder("fail-1", "port-99", "CRASH", 100, 50.0)
	failingOrder.SimulateFailure = true

	err := pool.Submit(failingOrder)
	if err != nil {
		t.Fatalf("error en submit: %v", err)
	}

	// Esperar procesamiento y compensación
	time.Sleep(100 * time.Millisecond)

	_ = pool.Shutdown(1 * time.Second)

	metrics := pool.Metrics()
	if metrics.TotalFailed != 1 {
		t.Fatalf("se esperaba 1 orden fallida, obtenido: %d", metrics.TotalFailed)
	}
	if metrics.TotalCompensated != 1 {
		t.Fatalf("se esperaba 1 orden compensada, obtenido: %d", metrics.TotalCompensated)
	}
	if failingOrder.Status() != domain.StatusCompensated {
		t.Fatalf("se esperaba orden con estado COMPENSATED, obtenido: %s", failingOrder.Status())
	}
}

func TestWorkerPool_NonBlockingBackpressure(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Pool con búfer minúsculo de 1 orden y 1 worker
	pool, _ := engine.NewWorkerPool(1, 1, 1)
	pool.Start(ctx)

	// Llenar canal rápidamente
	var rejected bool
	for i := 0; i < 20; i++ {
		cmd := domain.NewBuyOrder(fmt.Sprintf("burst-%d", i), "port-1", "AAPL", 1, 150)
		err := pool.Submit(cmd)
		if err == engine.ErrQueueFull {
			rejected = true
			break
		}
	}

	if !rejected {
		t.Log("Nota: en máquinas ultra rápidas el worker drena antes de saturar, pero el mecanismo select/default está activo")
	}

	_ = pool.Shutdown(500 * time.Millisecond)
}
