package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"fin-ai-advisor/portfolio-api/internal/domain"
	"fin-ai-advisor/portfolio-api/internal/engine"
)

// Configuración de la API
const (
	defaultPort         = "8080"
	workerPoolSize      = 16  // Goroutines de trabajo continuo
	queueBufferSize     = 250 // Búfer no bloqueante
	maxConcurrentDBConn = 8   // Límite de conexiones activas a PostgreSQL (< workers para que el semáforo sea efectivo)
)

func main() {
	log.Println("=== [FIN-AI-ADVISOR] Iniciando Portfolio API Backend ===")

	// 1. Inicialización del contexto raíz con control de señales de SO
	rootCtx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// 2. Instanciación del Worker Pool (Command Pattern + Worker Pool)
	pool, err := engine.NewWorkerPool(workerPoolSize, queueBufferSize, maxConcurrentDBConn)
	if err != nil {
		log.Fatalf("Error crítico al inicializar Worker Pool: %v", err)
	}

	// 3. Inicio del pool de goroutines concurrentes.
	// Se usa un contexto independiente de las señales del SO: al recibir SIGTERM el pool
	// debe drenar la cola vía Shutdown, no abortar las órdenes en vuelo.
	pool.Start(context.Background())

	// 4. Simulación de tráfico concurrente de mercado financiero (solo en demos locales)
	if os.Getenv("SIMULATE_LOAD") == "true" {
		go simulateFinancialMarketLoad(pool)
	}

	// 5. Configuración de endpoints HTTP REST
	mux := http.NewServeMux()

	// Health Check
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"status":    "UP",
			"timestamp": time.Now().UTC().Format(time.RFC3339),
			"service":   "portfolio-api",
		})
	})

	// Métricas en tiempo real del Worker Pool
	mux.HandleFunc("GET /api/v1/metrics", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		metrics := pool.Metrics()
		_ = json.NewEncoder(w).Encode(metrics)
	})

	// Envío de órdenes BuyOrder vía HTTP (No bloqueante)
	mux.HandleFunc("POST /api/v1/orders/buy", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			PortfolioID     string  `json:"portfolio_id"`
			Symbol          string  `json:"symbol"`
			Quantity        int64   `json:"quantity"`
			Price           string  `json:"price"` // Decimal en texto ("185.50"): nunca float para dinero
			SimulateFailure bool    `json:"simulate_failure"`
		}

		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, `{"error":"payload JSON inválido"}`, http.StatusBadRequest)
			return
		}

		orderID := fmt.Sprintf("ord-%d", time.Now().UnixNano())
		priceCents, err := domain.ParseCents(req.Price)
		if err != nil {
			http.Error(w, `{"error":"price inválido"}`, http.StatusBadRequest)
			return
		}
		buyCmd := domain.NewBuyOrder(orderID, req.PortfolioID, req.Symbol, req.Quantity, priceCents)
		buyCmd.SimulateFailure = req.SimulateFailure

		// Envío NO BLOQUEANTE al canal del worker pool
		if err := pool.Submit(buyCmd); err != nil {
			if err == engine.ErrQueueFull {
				w.WriteHeader(http.StatusTooManyRequests)
				_ = json.NewEncoder(w).Encode(map[string]string{
					"error":   "Servicio saturado temporalmente. Intente nuevamente (Backpressure activado)",
					"code":    "QUEUE_FULL",
					"orderId": orderID,
				})
				return
			}
			http.Error(w, fmt.Sprintf(`{"error":"%v"}`, err), http.StatusServiceUnavailable)
			return
		}

		w.WriteHeader(http.StatusAccepted)
		_ = json.NewEncoder(w).Encode(map[string]interface{}{
			"message":  "Orden de compra encolada exitosamente para procesamiento asíncrono",
			"order_id": orderID,
			"symbol":   req.Symbol,
			"status":   buyCmd.Status(),
		})
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = defaultPort
	}

	server := &http.Server{
		Addr:         ":" + port,
		Handler:      mux,
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// 6. Lanzamiento del servidor en goroutine separada
	go func() {
		log.Printf("[HTTP] Servidor escuchando en http://0.0.0.0:%s", port)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Error en servidor HTTP: %v", err)
		}
	}()

	// 7. Espera de señal de apagado ordenado
	<-rootCtx.Done()
	log.Println("[Shutdown] Señal de apagado detectada. Iniciando drenado ordenado...")

	// Timeout para cerrar el servidor HTTP
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()

	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("[Shutdown] Error cerrando servidor HTTP: %v", err)
	}

	// Drenar y esperar workers
	if err := pool.Shutdown(5 * time.Second); err != nil {
		log.Printf("[Shutdown] Advertencia drenando worker pool: %v", err)
	}

	log.Printf("[Shutdown] Resumen final de métricas: %+v", pool.Metrics())
	log.Println("=== [FIN-AI-ADVISOR] Backend detenido con éxito ===")
}

// simulateFinancialMarketLoad genera una ráfaga concurrente de órdenes para validar el pool
func simulateFinancialMarketLoad(pool *engine.WorkerPool) {
	time.Sleep(300 * time.Millisecond) // Esperar inicio del servidor
	log.Println("[MarketSimulation] Disparando ráfaga concurrente de órdenes financieras...")

	symbols := []string{"AAPL", "NVDA", "MSFT", "GOOGL", "AMZN"}
	var simWg sync.WaitGroup

	for i := 1; i <= 25; i++ {
		simWg.Add(1)
		go func(idx int) {
			defer simWg.Done()
			sym := symbols[idx%len(symbols)]
			order := domain.NewBuyOrder(
				fmt.Sprintf("sim-ord-%03d", idx),
				fmt.Sprintf("usr-%02d", idx%7),
				sym,
				int64(idx*2),
				int64(15000+idx*100),
			)

			// Simular falla intencional en la orden 13 para evidenciar compensación Saga
			if idx == 13 {
				order.SimulateFailure = true
			}

			// Envío no bloqueante
			if err := pool.Submit(order); err != nil {
				log.Printf("[MarketSimulation] Orden %s rechazada: %v", order.ID(), err)
			}
		}(i)
	}

	simWg.Wait()
	log.Println("[MarketSimulation] Ráfaga de simulación despachada exitosamente al Worker Pool.")
}
