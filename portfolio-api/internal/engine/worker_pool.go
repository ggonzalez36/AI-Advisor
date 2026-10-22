package engine

import (
	"context"
	"errors"
	"fmt"
	"log"
	"sync"
	"sync/atomic"
	"time"

	"fin-ai-advisor/portfolio-api/internal/domain"
)

var (
	ErrQueueFull      = errors.New("order queue is saturated (backpressure engaged)")
	ErrPoolStopped    = errors.New("worker pool is stopped or shutting down")
	ErrInvalidPoolCfg = errors.New("invalid worker pool configuration: workerCount and queueSize must be > 0")
)

// PoolMetrics exposes atomic counters of the pool's operational state
type PoolMetrics struct {
	ActiveWorkers    int
	QueueCapacity    int
	CurrentQueueLen  int
	TotalSubmitted   uint64
	TotalExecuted    uint64
	TotalCompensated uint64
	TotalFailed      uint64
	TotalRejected    uint64
	TotalDuplicates  uint64 // Discarded repeat deliveries (at-least-once + idempotent consumer)
}

// WorkerPool coordinates a finite number of goroutines to process financial transactions
// through a non-blocking bidirectional channel, protecting database connections.
type WorkerPool struct {
	workerCount int
	queueSize   int

	// Bidirectional channel where buy/sell commands are enqueued
	taskQueue chan domain.Command

	// queueMu guards closing taskQueue: producers take RLock to send
	// and Shutdown takes Lock to close, preventing the "send on closed channel" panic.
	queueMu sync.RWMutex
	// quit is closed when Shutdown starts to unblock producers in SubmitWithTimeout.
	quit chan struct{}

	// Semaphore limiting concurrent transactions to PostgreSQL (prevents DB starvation)
	dbConnSemaphore chan struct{}

	workerWg sync.WaitGroup
	ctx      context.Context
	cancel   context.CancelFunc

	// Pool state
	isRunning atomic.Bool
	isClosing atomic.Bool

	// Race-free atomic metrics
	submittedCount   atomic.Uint64
	executedCount    atomic.Uint64
	compensatedCount atomic.Uint64
	failedCount      atomic.Uint64
	rejectedCount    atomic.Uint64
	duplicateCount   atomic.Uint64
}

// NewWorkerPool initializes the WorkerPool with the number of workers and the channel size.
// dbMaxConns sets the hard limit on concurrent database transactions.
func NewWorkerPool(workerCount, queueSize, dbMaxConns int) (*WorkerPool, error) {
	if workerCount <= 0 || queueSize <= 0 || dbMaxConns <= 0 {
		return nil, ErrInvalidPoolCfg
	}

	return &WorkerPool{
		workerCount:     workerCount,
		queueSize:       queueSize,
		taskQueue:       make(chan domain.Command, queueSize), // Buffered bidirectional channel
		quit:            make(chan struct{}),
		dbConnSemaphore: make(chan struct{}, dbMaxConns),
	}, nil
}

// Channel returns the bidirectional task channel for streaming or direct-integration scenarios.
func (wp *WorkerPool) Channel() chan domain.Command {
	return wp.taskQueue
}

// Start launches the worker goroutines bound to the lifecycle of the given context.
func (wp *WorkerPool) Start(parentCtx context.Context) {
	if !wp.isRunning.CompareAndSwap(false, true) {
		return // Already started
	}

	wp.ctx, wp.cancel = context.WithCancel(parentCtx)

	for i := 1; i <= wp.workerCount; i++ {
		wp.workerWg.Add(1)
		go wp.workerLoop(i)
	}

	log.Printf("[WorkerPool] Started successfully with %d workers, buffer of %d and DB limit of %d",
		wp.workerCount, wp.queueSize, cap(wp.dbConnSemaphore))
}

// Submit sends an order to the channel in a NON-BLOCKING way (select with default).
// If the queue is full, it rejects immediately without blocking the calling goroutine.
func (wp *WorkerPool) Submit(cmd domain.Command) error {
	wp.queueMu.RLock()
	defer wp.queueMu.RUnlock()

	if !wp.isRunning.Load() || wp.isClosing.Load() {
		return ErrPoolStopped
	}

	select {
	case wp.taskQueue <- cmd:
		wp.submittedCount.Add(1)
		return nil
	default:
		// Queue saturated: immediate backpressure without degrading the HTTP server
		wp.rejectedCount.Add(1)
		return ErrQueueFull
	}
}

// SubmitWithTimeout tries to enqueue the order, waiting up to a maximum duration before giving up.
func (wp *WorkerPool) SubmitWithTimeout(ctx context.Context, cmd domain.Command, timeout time.Duration) error {
	wp.queueMu.RLock()
	defer wp.queueMu.RUnlock()

	if !wp.isRunning.Load() || wp.isClosing.Load() {
		return ErrPoolStopped
	}

	timer := time.NewTimer(timeout)
	defer timer.Stop()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-wp.quit:
		return ErrPoolStopped
	case <-timer.C:
		wp.rejectedCount.Add(1)
		return ErrQueueFull
	case wp.taskQueue <- cmd:
		wp.submittedCount.Add(1)
		return nil
	}
}

// workerLoop is the execution loop of each worker goroutine.
func (wp *WorkerPool) workerLoop(workerID int) {
	defer wp.workerWg.Done()

	for {
		select {
		case <-wp.ctx.Done():
			// Global context cancelled: process leftovers if possible and exit
			return
		case cmd, ok := <-wp.taskQueue:
			if !ok {
				// The channel was closed during Shutdown
				return
			}
			wp.processCommand(workerID, cmd)
		}
	}
}

// processCommand executes the command after acquiring a slot from the database semaphore.
// If an error occurs, it automatically triggers Saga compensation (Undo).
func (wp *WorkerPool) processCommand(workerID int, cmd domain.Command) {
	// 1. Acquire the PostgreSQL connection semaphore
	wp.dbConnSemaphore <- struct{}{}
	defer func() { <-wp.dbConnSemaphore }()

	// Per-transaction execution timeout
	execCtx, cancel := context.WithTimeout(wp.ctx, 2*time.Second)
	defer cancel()

	// 2. Run the command (Execute)
	err := cmd.Execute(execCtx)
	if errors.Is(err, domain.ErrAlreadyExecuted) {
		// Duplicate delivery (e.g. relay re-dispatch): another worker already processed it; nothing to compensate
		wp.duplicateCount.Add(1)
		return
	}
	if err != nil {
		wp.failedCount.Add(1)
		log.Printf("[Worker %d] ERROR executing order %s: %v. Starting Saga compensation (Undo)...",
			workerID, cmd.ID(), err)

		// 3. Transactional compensation (Undo)
		undoCtx, undoCancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer undoCancel()

		undoErr := cmd.Undo(undoCtx)
		switch {
		case errors.Is(undoErr, domain.ErrNothingToCompensate):
			log.Printf("[Worker %d] Order %s failed with no prior side effects; no compensation required",
				workerID, cmd.ID())
		case undoErr != nil:
			log.Printf("[Worker %d] CRITICAL: Compensation failed for order %s: %v",
				workerID, cmd.ID(), undoErr)
		default:
			wp.compensatedCount.Add(1)
			log.Printf("[Worker %d] Order %s compensated successfully (New Status: %s)",
				workerID, cmd.ID(), cmd.Status())
		}
		return
	}

	wp.executedCount.Add(1)
}

// Shutdown performs a graceful drain of the workers and pending tasks.
func (wp *WorkerPool) Shutdown(drainTimeout time.Duration) error {
	if !wp.isRunning.Load() {
		return nil
	}

	if !wp.isClosing.CompareAndSwap(false, true) {
		return nil // Shutdown already in progress
	}
	close(wp.quit) // Releases producers blocked in SubmitWithTimeout

	// Wait for in-flight sends to finish before closing the channel
	wp.queueMu.Lock()
	close(wp.taskQueue) // Close the channel so workers exit once it is drained
	wp.queueMu.Unlock()

	done := make(chan struct{})
	go func() {
		wp.workerWg.Wait()
		close(done)
	}()

	select {
	case <-done:
		log.Printf("[WorkerPool] All workers finished gracefully")
	case <-time.After(drainTimeout):
		wp.cancel() // Force cancellation of active contexts
		return fmt.Errorf("forced timeout (%v) while draining the worker pool", drainTimeout)
	}

	wp.isRunning.Store(false)
	return nil
}

// Metrics returns a concurrency-safe telemetry snapshot of the pool.
func (wp *WorkerPool) Metrics() PoolMetrics {
	return PoolMetrics{
		ActiveWorkers:    wp.workerCount,
		QueueCapacity:    wp.queueSize,
		CurrentQueueLen:  len(wp.taskQueue),
		TotalSubmitted:   wp.submittedCount.Load(),
		TotalExecuted:    wp.executedCount.Load(),
		TotalCompensated: wp.compensatedCount.Load(),
		TotalFailed:      wp.failedCount.Load(),
		TotalRejected:    wp.rejectedCount.Load(),
		TotalDuplicates:  wp.duplicateCount.Load(),
	}
}
