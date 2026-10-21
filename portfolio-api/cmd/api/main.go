package main

import (
	"context"
	"fmt"
	"log"
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

// Configuración de la API
const (
	defaultPort         = "8080"
	defaultDBPath       = "data/portfolio.db"
	workerPoolSize      = 16  // Goroutines de trabajo continuo
	queueBufferSize     = 250 // Búfer no bloqueante
	maxConcurrentDBConn = 8   // Límite de transacciones concurrentes (< workers para que el semáforo sea efectivo)
	maxOutboxBacklog    = 1000
	relayInterval       = 2 * time.Second
	relayMinAge         = 5 * time.Second
)

func main() {
	log.Println("=== [FIN-AI-ADVISOR] Iniciando Portfolio API Backend ===")

	// 1. Contexto raíz con control de señales de SO
	rootCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// 2. Persistencia: SQLite con migraciones embebidas
	dbPath := getenv("DB_PATH", defaultDBPath)
	if err := os.MkdirAll(filepath.Dir(dbPath), 0o755); err != nil {
		log.Fatalf("Error creando directorio de datos: %v", err)
	}
	repo, err := store.Open(rootCtx, dbPath)
	if err != nil {
		log.Fatalf("Error crítico abriendo base de datos: %v", err)
	}
	log.Printf("[Store] SQLite listo en %s", dbPath)

	// 3. Worker Pool (Command Pattern + Worker Pool).
	// Contexto independiente de las señales del SO: al recibir SIGTERM el pool
	// debe drenar la cola vía Shutdown, no abortar las órdenes en vuelo.
	pool, err := engine.NewWorkerPool(workerPoolSize, queueBufferSize, maxConcurrentDBConn)
	if err != nil {
		log.Fatalf("Error crítico al inicializar Worker Pool: %v", err)
	}
	pool.Start(context.Background())

	// 4. Servicio de órdenes + relay del outbox (recupera órdenes no despachadas)
	svc := orders.NewService(repo, pool, maxOutboxBacklog)
	relayCtx, stopRelay := context.WithCancel(context.Background())
	var relayWg sync.WaitGroup
	relayWg.Add(1)
	go func() {
		defer relayWg.Done()
		orders.NewRelay(svc, relayInterval, relayMinAge, 100).Run(relayCtx)
	}()

	// 5. Simulación de tráfico concurrente (solo en demos locales)
	port := getenv("PORT", defaultPort)
	if os.Getenv("SIMULATE_LOAD") == "true" {
		go simulateFinancialMarketLoad("http://localhost:" + port)
	}

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      httpapi.New(svc, repo, pool).Routes(),
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		log.Printf("[HTTP] Servidor escuchando en http://0.0.0.0:%s", port)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Error en servidor HTTP: %v", err)
		}
	}()

	// 6. Apagado ordenado: primero se deja de aceptar tráfico, luego se detiene el relay,
	// se drena el pool y por último se cierra la base de datos.
	<-rootCtx.Done()
	log.Println("[Shutdown] Señal de apagado detectada. Iniciando drenado ordenado...")

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("[Shutdown] Error cerrando servidor HTTP: %v", err)
	}

	stopRelay()
	relayWg.Wait()

	if err := pool.Shutdown(5 * time.Second); err != nil {
		log.Printf("[Shutdown] Advertencia drenando worker pool: %v", err)
	}
	if err := repo.Close(); err != nil {
		log.Printf("[Shutdown] Error cerrando base de datos: %v", err)
	}

	log.Printf("[Shutdown] Resumen final de métricas: %+v", pool.Metrics())
	log.Println("=== [FIN-AI-ADVISOR] Backend detenido con éxito ===")
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// simulateFinancialMarketLoad dispara una ráfaga concurrente de órdenes contra la propia API,
// incluyendo una falla intencional (orden 13) para evidenciar la compensación Saga.
func simulateFinancialMarketLoad(baseURL string) {
	time.Sleep(300 * time.Millisecond) // Esperar inicio del servidor
	log.Println("[MarketSimulation] Disparando ráfaga concurrente de órdenes financieras...")

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
				log.Printf("[MarketSimulation] Orden %d falló: %v", idx, err)
				return
			}
			_ = resp.Body.Close()
		}(i)
	}

	wg.Wait()
	log.Println("[MarketSimulation] Ráfaga de simulación despachada exitosamente.")
}
