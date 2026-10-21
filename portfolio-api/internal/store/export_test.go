package store

import "context"

// ExecRawForTest expone ejecución SQL directa solo para pruebas (p. ej. verificar triggers).
func (s *Store) ExecRawForTest(ctx context.Context, stmt string) error {
	_, err := s.db.ExecContext(ctx, stmt)
	return err
}
