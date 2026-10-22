package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"fin-ai-advisor/portfolio-api/internal/engine"
	"fin-ai-advisor/portfolio-api/internal/httpapi"
	"fin-ai-advisor/portfolio-api/internal/orders"
	"fin-ai-advisor/portfolio-api/internal/store"
)

// API configuration
const (
	defaultHost         = "127.0.0.1" // Secure by default: loopback only. Containers use HOST=0.0.0.0
	defaultPort         = "8080"
	defaultDBPath       = "data/portfolio.db"
	workerPoolSize      = 16  // Long-running worker goroutines
	queueBufferSize     = 250 // Non-blocking buffer
	maxConcurrentDBConn = 8   // Concurrent transaction limit (< workers so the semaphore is effective)
	maxOutboxBacklog    = 1000
	relayInterval       = 2 * time.Second
	relayMinAge         = 5 * time.Second
)

func main() {
	log.Println("=== [FIN-AI-ADVISOR] Starting Portfolio API Backend ===")

	// 1. Root context wired to OS signals
	rootCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// 2. Persistence: SQLite with embedded migrations
	dbPath := getenv("DB_PATH", defaultDBPath)
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o755); err != nil {
		log.Fatalf("Error creating data directory: %v", err)
	}
	repo, err := store.Open(rootCtx, dbPath)
	if err != nil {
		log.Fatalf("Critical error opening database: %v", err)
	}
	log.Printf("[Store] SQLite ready at %s", dbPath)

	// 3. Worker Pool (Command Pattern + Worker Pool).
	// Context independent of OS signals: on SIGTERM the pool must
	// drain the queue via Shutdown, not abort in-flight orders.
	pool, err := engine.NewWorkerPool(workerPoolSize, queueBufferSize, maxConcurrentDBConn)
	if err != nil {
		log.Fatalf("Critical error initializing Worker Pool: %v", err)
	}
	pool.Start(context.Background())

	// 4. Order service + outbox relay (recovers undispatched orders)
	svc := orders.NewService(repo, pool, maxOutboxBacklog)
	relayCtx, stopRelay := context.WithCancel(context.Background())
	var relayWg sync.WaitGroup
	relayWg.Add(1)
	go func() {
		defer relayWg.Done()
		orders.NewRelay(svc, relayInterval, relayMinAge, 100).Run(relayCtx)
	}()

	// 5. Concurrent traffic simulation (local demos only)
	host := getenv("HOST", defaultHost)
	port := getenv("PORT", defaultPort)
	if os.Getenv("SIMULATE_LOAD") == "true" {
		go simulateFinancialMarketLoad("http://localhost:" + port)
	}

	server := &http.Server{
		Addr:         net.JoinHostPort(host, port),
		Handler:      httpapi.New(svc, repo, pool).Routes(),
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		log.Printf("[HTTP] Server listening on http://%s", net.JoinHostPort(host, port))
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("HTTP server error: %v", err)
		}
	}()

	// 6. Graceful shutdown: first stop accepting traffic, then stop the relay,
	// drain the pool, and finally close the database.
	<-rootCtx.Done()
	log.Println("[Shutdown] Shutdown signal received. Starting graceful drain...")

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("[Shutdown] Error closing HTTP server: %v", err)
	}

	stopRelay()
	relayWg.Wait()

	if err := pool.Shutdown(5 * time.Second); err != nil {
		log.Printf("[Shutdown] Warning while draining worker pool: %v", err)
	}
	if err := repo.Close(); err != nil {
		log.Printf("[Shutdown] Error closing database: %v", err)
	}

	log.Printf("[Shutdown] Final metrics summary: %+v", pool.Metrics())
	log.Println("=== [FIN-AI-ADVISOR] Backend stopped successfully ===")
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// simulateFinancialMarketLoad fires a concurrent burst of orders at the API itself,
// including an intentional failure (order 13) to demonstrate Saga compensation.
func simulateFinancialMarketLoad(baseURL string) {
	time.Sleep(300 * time.Millisecond) // Wait for the server to start
	log.Println("[MarketSimulation] Firing concurrent burst of financial orders...")

	symbols := []string{"AAPL", "NVDA", "MSFT", "GOOGL", "AMZN"}
	var wg sync.WaitGroup

	for i := 1; i <= 25; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			body := fmt.Sprintf(`{"portfolio_id":"usr-%02d","symbol":"%s","quantity":%d,"price":"%d.%02d","simulate_failure":%t}`,
				idx%7, symbols[idx%len(symbols)], idx*2, 150+idx, idx%100, idx == 13)

			req, _ := http.NewRequest(http.MethodPost, baseURL+"/api/v1/orders/buy", strings.NewReader(body))
			req.Header.Set("Content-Type", "application/json")
			req.Header.Set("Idempotency-Key", fmt.Sprintf("sim-%03d", idx))

			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				log.Printf("[MarketSimulation] Order %d failed: %v", idx, err)
				return
			}
			_ = resp.Body.Close()
		}(i)
	}

	wg.Wait()
	log.Println("[MarketSimulation] Simulation burst dispatched successfully.")
}
