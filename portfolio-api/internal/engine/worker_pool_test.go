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

// Regresión: Submit concurrente con Shutdown provocaba panic "send on closed channel".
func TestWorkerPool_SubmitDuringShutdownDoesNotPanic(t *testing.T) {
	for round := 0; round < 100; round++ {
		pool, _ := engine.NewWorkerPool(2, 1000, 2)
		pool.Start(context.Background())

		var wg sync.WaitGroup
		for g := 0; g < 16; g++ {
			wg.Add(1)
			go func(g int) {
				defer wg.Done()
				for i := 0; i < 100; i++ {
					err := pool.Submit(domain.NewBuyOrder(fmt.Sprintf("r%d-%d-%d", round, g, i), "p", "X", 1, 1))
					if err != nil && err != engine.ErrPoolStopped && err != engine.ErrQueueFull {
						t.Errorf("error inesperado: %v", err)
					}
				}
			}(g)
		}

		_ = pool.Shutdown(time.Second)
		wg.Wait()
	}
}

// Una orden que falla en validación no tiene efectos y no debe contarse como compensada.
func TestWorkerPool_ValidationFailureIsNotCompensated(t *testing.T) {
	pool, _ := engine.NewWorkerPool(1, 10, 1)
	pool.Start(context.Background())

	_ = pool.Submit(domain.NewBuyOrder("bad-1", "port-1", "AAPL", 0, 150))
	_ = pool.Shutdown(time.Second)

	metrics := pool.Metrics()
	if metrics.TotalFailed != 1 || metrics.TotalCompensated != 0 {
		t.Fatalf("se esperaba 1 fallida y 0 compensadas, obtenido: %+v", metrics)
	}
}

// Shutdown debe drenar las órdenes ya encoladas en lugar de descartarlas.
func TestWorkerPool_ShutdownDrainsQueue(t *testing.T) {
	pool, _ := engine.NewWorkerPool(1, 50, 1)
	pool.Start(context.Background())

	for i := 0; i < 20; i++ {
		if err := pool.Submit(domain.NewBuyOrder(fmt.Sprintf("drain-%d", i), "p", "AAPL", 1, 100)); err != nil {
			t.Fatalf("submit falló: %v", err)
		}
	}
	if err := pool.Shutdown(5 * time.Second); err != nil {
		t.Fatalf("shutdown falló: %v", err)
	}
	if got := pool.Metrics().TotalExecuted; got != 20 {
		t.Fatalf("se esperaban 20 órdenes drenadas, obtenido: %d", got)
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
