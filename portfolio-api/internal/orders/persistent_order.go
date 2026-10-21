package orders

import (
	"context"
	"errors"

	"fin-ai-advisor/portfolio-api/internal/domain"
	"fin-ai-advisor/portfolio-api/internal/store"
)

// persistentOrder aplica el patrón Decorator sobre domain.BuyOrder: implementa la misma
// interfaz Command y añade persistencia alrededor de cada transición, sin que el dominio
// conozca la base de datos. El worker pool no distingue entre ambos.
type persistentOrder struct {
	inner *domain.BuyOrder
	rec   store.Order
	repo  Repository
}

var _ domain.Command = (*persistentOrder)(nil)

// Execute reclama la orden (compare-and-set) antes de ejecutarla. Si otro worker ya la
// reclamó, retorna ErrAlreadyExecuted y el pool la descarta como entrega duplicada.
func (p *persistentOrder) Execute(ctx context.Context) error {
	claimed, err := p.repo.ClaimOrder(ctx, p.rec.ID)
	if err != nil {
		return err // Sigue PENDING en BD: el relay la reintentará
	}
	if !claimed {
		return domain.ErrAlreadyExecuted
	}

	// Las escrituras de resultado no deben abortarse si el timeout de ejecución expiró:
	// el efecto en el dominio ya ocurrió y debe quedar registrado.
	persistCtx := context.WithoutCancel(ctx)

	if execErr := p.inner.Execute(ctx); execErr != nil {
		if err := p.repo.MarkFailed(persistCtx, p.rec, execErr.Error(), p.inner.FundsReserved()); err != nil {
			return errors.Join(execErr, err)
		}
		return execErr
	}
	return p.repo.MarkExecuted(persistCtx, p.rec)
}

// Undo compensa en el dominio y registra la liberación de fondos en el ledger.
func (p *persistentOrder) Undo(ctx context.Context) error {
	if err := p.inner.Undo(ctx); err != nil {
		return err
	}
	return p.repo.MarkCompensated(ctx, p.rec)
}

func (p *persistentOrder) ID() string                 { return p.rec.ID }
func (p *persistentOrder) Status() domain.OrderStatus { return p.inner.Status() }
