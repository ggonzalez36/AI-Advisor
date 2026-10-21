package orders

import (
	"context"
	"log"
	"time"
)

// Relay implementa el lado "publicador" del Transactional Outbox: re-despacha órdenes
// persistidas cuyo evento sigue sin publicar (pool saturado o caída del proceso antes
// del despacho). La entrega es at-least-once; el claim compare-and-set en BD garantiza
// que cada orden se ejecute como máximo una vez.
type Relay struct {
	svc      *Service
	interval time.Duration
	minAge   time.Duration // Margen para no competir con el despacho inmediato recién hecho
	batch    int
}

func NewRelay(svc *Service, interval, minAge time.Duration, batch int) *Relay {
	return &Relay{svc: svc, interval: interval, minAge: minAge, batch: batch}
}

// Run ejecuta DispatchOnce periódicamente hasta que ctx se cancele.
func (r *Relay) Run(ctx context.Context) {
	ticker := time.NewTicker(r.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if n, err := r.DispatchOnce(ctx); err != nil {
				log.Printf("[Relay] error re-despachando outbox: %v", err)
			} else if n > 0 {
				log.Printf("[Relay] %d órdenes re-despachadas desde el outbox", n)
			}
		}
	}
}

// DispatchOnce re-despacha un lote de órdenes pendientes. Se detiene en cuanto el pool
// rechaza (saturado), dejando el resto para el siguiente ciclo.
func (r *Relay) DispatchOnce(ctx context.Context) (int, error) {
	pending, err := r.svc.repo.UndispatchedOrders(ctx, time.Now().Add(-r.minAge), r.batch)
	if err != nil {
		return 0, err
	}

	dispatched := 0
	for _, rec := range pending {
		if err := r.svc.dispatcher.Submit(r.svc.command(rec, false)); err != nil {
			break
		}
		dispatched++
	}
	return dispatched, nil
}
