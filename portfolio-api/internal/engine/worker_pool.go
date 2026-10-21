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
	ErrQueueFull      = errors.New("la cola de órdenes está saturada (backpressure activado)")
	ErrPoolStopped    = errors.New("el worker pool está detenido o en proceso de apagado")
	ErrInvalidPoolCfg = errors.New("configuración de worker pool inválida: workerCount y queueSize deben ser > 0")
)

// PoolMetrics expone contadores atómicos del estado operativo del pool
type PoolMetrics struct {
	ActiveWorkers    int
	QueueCapacity    int
	CurrentQueueLen  int
	TotalSubmitted   uint64
	TotalExecuted    uint64
	TotalCompensated uint64
	TotalFailed      uint64
	TotalRejected    uint64
	TotalDuplicates  uint64 // Entregas repetidas descartadas (at-least-once + consumidor idempotente)
}

// WorkerPool coordina un número finito de goroutines para procesar transacciones financieras
// a través de un canal bidireccional no bloqueante, protegiendo las conexiones a la base de datos.
type WorkerPool struct {
	workerCount int
	queueSize   int

	// Canal bidireccional donde se encolan los comandos de compra/venta
	taskQueue chan domain.Command

	// queueMu protege el cierre de taskQueue: los productores toman RLock para enviar
	// y Shutdown toma Lock para cerrar, evitando el panic "send on closed channel".
	queueMu sync.RWMutex
	// quit se cierra al iniciar Shutdown para desbloquear a productores en SubmitWithTimeout.
	quit chan struct{}

	// Semáforo para limitar transacciones concurrentes hacia PostgreSQL (evita DB starvation)
	dbConnSemaphore chan struct{}

	workerWg sync.WaitGroup
	ctx      context.Context
	cancel   context.CancelFunc

	// Estado del pool
	isRunning atomic.Bool
	isClosing atomic.Bool

	// Métricas atómicas libres de race conditions
	submittedCount   atomic.Uint64
	executedCount    atomic.Uint64
	compensatedCount atomic.Uint64
	failedCount      atomic.Uint64
	rejectedCount    atomic.Uint64
	duplicateCount   atomic.Uint64
}

// NewWorkerPool inicializa el WorkerPool con el número de workers y el tamaño del canal.
// dbMaxConns define el límite estricto de transacciones de base de datos concurrentes.
func NewWorkerPool(workerCount, queueSize, dbMaxConns int) (*WorkerPool, error) {
	if workerCount <= 0 || queueSize <= 0 || dbMaxConns <= 0 {
		return nil, ErrInvalidPoolCfg
	}

	return &WorkerPool{
		workerCount:     workerCount,
		queueSize:       queueSize,
		taskQueue:       make(chan domain.Command, queueSize), // Canal bidireccional con búfer
		quit:            make(chan struct{}),
		dbConnSemaphore: make(chan struct{}, dbMaxConns),
	}, nil
}

// Channel devuelve el canal bidireccional de tareas para escenarios de streaming o integración directa.
func (wp *WorkerPool) Channel() chan domain.Command {
	return wp.taskQueue
}

// Start arranca las goroutines trabajadoras vinculadas al ciclo de vida del contexto recibido.
func (wp *WorkerPool) Start(parentCtx context.Context) {
	if !wp.isRunning.CompareAndSwap(false, true) {
		return // Ya iniciado
	}

	wp.ctx, wp.cancel = context.WithCancel(parentCtx)

	for i := 1; i <= wp.workerCount; i++ {
		wp.workerWg.Add(1)
		go wp.workerLoop(i)
	}

	log.Printf("[WorkerPool] Iniciado exitosamente con %d workers, búfer de %d y límite DB de %d",
		wp.workerCount, wp.queueSize, cap(wp.dbConnSemaphore))
}

// Submit envía una orden al canal de forma NO BLOQUEANTE (select con default).
// Si la cola está llena, rechaza inmediatamente sin bloquear el hilo solicitante.
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
		// Cola saturada: contrapresión inmediata sin degradar el servidor HTTP
		wp.rejectedCount.Add(1)
		return ErrQueueFull
	}
}

// SubmitWithTimeout intenta encolar la orden esperando un lapso máximo antes de descartar.
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

// workerLoop representa el ciclo de ejecución de cada goroutine trabajadora.
func (wp *WorkerPool) workerLoop(workerID int) {
	defer wp.workerWg.Done()

	for {
		select {
		case <-wp.ctx.Done():
			// Contexto global cancelado: procesar remanentes si es posible y salir
			return
		case cmd, ok := <-wp.taskQueue:
			if !ok {
				// El canal fue cerrado durante Shutdown
				return
			}
			wp.processCommand(workerID, cmd)
		}
	}
}

// processCommand ejecuta el comando adquiriendo un slot del semáforo de base de datos.
// Si ocurre un error, dispara automáticamente la compensación Saga (Undo).
func (wp *WorkerPool) processCommand(workerID int, cmd domain.Command) {
	// 1. Adquisición del semáforo de conexión a PostgreSQL
	wp.dbConnSemaphore <- struct{}{}
	defer func() { <-wp.dbConnSemaphore }()

	// Timeout de ejecución por transacción
	execCtx, cancel := context.WithTimeout(wp.ctx, 2*time.Second)
	defer cancel()

	// 2. Ejecutar comando (Execute)
	err := cmd.Execute(execCtx)
	if errors.Is(err, domain.ErrAlreadyExecuted) {
		// Entrega duplicada (p. ej. re-despacho del relay): otro worker ya la procesó; no hay nada que compensar
		wp.duplicateCount.Add(1)
		return
	}
	if err != nil {
		wp.failedCount.Add(1)
		log.Printf("[Worker %d] ERROR ejecutando orden %s: %v. Iniciando compensación Saga (Undo)...",
			workerID, cmd.ID(), err)

		// 3. Compensación transaccional (Undo)
		undoCtx, undoCancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer undoCancel()

		undoErr := cmd.Undo(undoCtx)
		switch {
		case errors.Is(undoErr, domain.ErrNothingToCompensate):
			log.Printf("[Worker %d] Orden %s falló sin efectos previos; no requiere compensación",
				workerID, cmd.ID())
		case undoErr != nil:
			log.Printf("[Worker %d] CRITICAL: Falló la compensación de orden %s: %v",
				workerID, cmd.ID(), undoErr)
		default:
			wp.compensatedCount.Add(1)
			log.Printf("[Worker %d] Compensación exitosa de orden %s (Nuevo Estado: %s)",
				workerID, cmd.ID(), cmd.Status())
		}
		return
	}

	wp.executedCount.Add(1)
}

// Shutdown realiza un apagado ordenado (graceful drain) de los workers y tareas pendientes.
func (wp *WorkerPool) Shutdown(drainTimeout time.Duration) error {
	if !wp.isRunning.Load() {
		return nil
	}

	if !wp.isClosing.CompareAndSwap(false, true) {
		return nil // Shutdown ya en curso
	}
	close(wp.quit) // Libera productores bloqueados en SubmitWithTimeout

	// Espera a que terminen los envíos en vuelo antes de cerrar el canal
	wp.queueMu.Lock()
	close(wp.taskQueue) // Cierra el canal para que los workers salgan al vaciar
	wp.queueMu.Unlock()

	done := make(chan struct{})
	go func() {
		wp.workerWg.Wait()
		close(done)
	}()

	select {
	case <-done:
		log.Printf("[WorkerPool] Todos los workers terminaron ordenadamente")
	case <-time.After(drainTimeout):
		wp.cancel() // Forzar cancelación de contextos activos
		return fmt.Errorf("timeout forzado (%v) drenando el pool de workers", drainTimeout)
	}

	wp.isRunning.Store(false)
	return nil
}

// Metrics retorna una instantánea de telemetría del pool de forma concurrente y segura.
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
