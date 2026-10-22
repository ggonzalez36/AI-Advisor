package orders

import (
	"context"
	"log"
	"time"
)

// Relay implements the "publisher" side of the Transactional Outbox: it re-dispatches persisted
// orders whose event is still unpublished (saturated pool or process crash before
// dispatch). Delivery is at-least-once; the compare-and-set claim in the DB guarantees
// that each order executes at most once.
type Relay struct {
	svc      *Service
	interval time.Duration
	minAge   time.Duration // Grace period to avoid racing with the immediate dispatch just performed
	batch    int
}

func NewRelay(svc *Service, interval, minAge time.Duration, batch int) *Relay {
	return &Relay{svc: svc, interval: interval, minAge: minAge, batch: batch}
}

// Run calls DispatchOnce periodically until ctx is cancelled.
func (r *Relay) Run(ctx context.Context) {
	ticker := time.NewTicker(r.interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if n, err := r.DispatchOnce(ctx); err != nil {
				log.Printf("[Relay] error re-dispatching outbox: %v", err)
			} else if n > 0 {
				log.Printf("[Relay] %d orders re-dispatched from the outbox", n)
			}
		}
	}
}

// DispatchOnce re-dispatches a batch of pending orders. It stops as soon as the pool
// rejects (saturated), leaving the rest for the next cycle.
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
