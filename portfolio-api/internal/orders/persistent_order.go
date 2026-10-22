package orders

import (
	"context"
	"errors"

	"fin-ai-advisor/portfolio-api/internal/domain"
	"fin-ai-advisor/portfolio-api/internal/store"
)

// persistentOrder applies the Decorator pattern to domain.BuyOrder: it implements the same
// Command interface and adds persistence around each transition, without the domain
// knowing about the database. The worker pool cannot tell the two apart.
type persistentOrder struct {
	inner *domain.BuyOrder
	rec   store.Order
	repo  Repository
}

var _ domain.Command = (*persistentOrder)(nil)

// Execute claims the order (compare-and-set) before executing it. If another worker already
// claimed it, it returns ErrAlreadyExecuted and the pool discards it as a duplicate delivery.
func (p *persistentOrder) Execute(ctx context.Context) error {
	claimed, err := p.repo.ClaimOrder(ctx, p.rec.ID)
	if err != nil {
		return err // Still PENDING in the DB: the relay will retry it
	}
	if !claimed {
		return domain.ErrAlreadyExecuted
	}

	// Result writes must not be aborted if the execution timeout expired:
	// the domain effect has already happened and must be recorded.
	persistCtx := context.WithoutCancel(ctx)

	if execErr := p.inner.Execute(ctx); execErr != nil {
		if err := p.repo.MarkFailed(persistCtx, p.rec, execErr.Error(), p.inner.FundsReserved()); err != nil {
			return errors.Join(execErr, err)
		}
		return execErr
	}
	return p.repo.MarkExecuted(persistCtx, p.rec)
}

// Undo compensates in the domain and records the release of funds in the ledger.
func (p *persistentOrder) Undo(ctx context.Context) error {
	if err := p.inner.Undo(ctx); err != nil {
		return err
	}
	return p.repo.MarkCompensated(ctx, p.rec)
}

func (p *persistentOrder) ID() string                 { return p.rec.ID }
func (p *persistentOrder) Status() domain.OrderStatus { return p.inner.Status() }
