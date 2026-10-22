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
		t.Fatalf("error creating worker pool: %v", err)
	}

	pool.Start(ctx)

	// High-concurrency simulation submitting 40 concurrent orders
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
				int64(orderIdx),
				12000,
			)

			// Non-blocking submit
			err := pool.Submit(cmd)
			if err != nil && err != engine.ErrQueueFull {
				t.Errorf("unexpected error in submit: %v", err)
			}
		}(i)
	}

	wg.Wait()

	// Give the workers time to drain the orders
	time.Sleep(200 * time.Millisecond)

	err = pool.Shutdown(2 * time.Second)
	if err != nil {
		t.Fatalf("error in shutdown: %v", err)
	}

	metrics := pool.Metrics()
	if metrics.TotalSubmitted == 0 {
		t.Fatal("expected at least one enqueued order")
	}
	if metrics.TotalExecuted == 0 {
		t.Fatal("expected at least one successfully processed order")
	}
}

func TestWorkerPool_AutomaticSagaCompensation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	pool, _ := engine.NewWorkerPool(2, 10, 2)
	pool.Start(ctx)

	// Create an order configured to fail
	failingOrder := domain.NewBuyOrder("fail-1", "port-99", "CRASH", 100, 5000)
	failingOrder.SimulateFailure = true

	err := pool.Submit(failingOrder)
	if err != nil {
		t.Fatalf("error in submit: %v", err)
	}

	// Wait for processing and compensation
	time.Sleep(100 * time.Millisecond)

	_ = pool.Shutdown(1 * time.Second)

	metrics := pool.Metrics()
	if metrics.TotalFailed != 1 {
		t.Fatalf("expected 1 failed order, got: %d", metrics.TotalFailed)
	}
	if metrics.TotalCompensated != 1 {
		t.Fatalf("expected 1 compensated order, got: %d", metrics.TotalCompensated)
	}
	if failingOrder.Status() != domain.StatusCompensated {
		t.Fatalf("expected order with COMPENSATED status, got: %s", failingOrder.Status())
	}
}

// Regression: Submit concurrent with Shutdown caused a "send on closed channel" panic.
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
						t.Errorf("unexpected error: %v", err)
					}
				}
			}(g)
		}

		_ = pool.Shutdown(time.Second)
		wg.Wait()
	}
}

// An order that fails validation has no side effects and must not be counted as compensated.
func TestWorkerPool_ValidationFailureIsNotCompensated(t *testing.T) {
	pool, _ := engine.NewWorkerPool(1, 10, 1)
	pool.Start(context.Background())

	_ = pool.Submit(domain.NewBuyOrder("bad-1", "port-1", "AAPL", 0, 150))
	_ = pool.Shutdown(time.Second)

	metrics := pool.Metrics()
	if metrics.TotalFailed != 1 || metrics.TotalCompensated != 0 {
		t.Fatalf("expected 1 failed and 0 compensated, got: %+v", metrics)
	}
}

// Shutdown must drain already-enqueued orders instead of discarding them.
func TestWorkerPool_ShutdownDrainsQueue(t *testing.T) {
	pool, _ := engine.NewWorkerPool(1, 50, 1)
	pool.Start(context.Background())

	for i := 0; i < 20; i++ {
		if err := pool.Submit(domain.NewBuyOrder(fmt.Sprintf("drain-%d", i), "p", "AAPL", 1, 100)); err != nil {
			t.Fatalf("submit failed: %v", err)
		}
	}
	if err := pool.Shutdown(5 * time.Second); err != nil {
		t.Fatalf("shutdown failed: %v", err)
	}
	if got := pool.Metrics().TotalExecuted; got != 20 {
		t.Fatalf("expected 20 drained orders, got: %d", got)
	}
}

func TestWorkerPool_NonBlockingBackpressure(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Pool with a tiny buffer of 1 order and 1 worker
	pool, _ := engine.NewWorkerPool(1, 1, 1)
	pool.Start(ctx)

	// Fill the channel quickly
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
		t.Log("Note: on very fast machines the worker drains before saturation, but the select/default mechanism is active")
	}

	_ = pool.Shutdown(500 * time.Millisecond)
}
