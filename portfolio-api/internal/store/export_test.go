package store

import "context"

// ExecRawForTest exposes direct SQL execution for tests only (e.g. verifying triggers).
func (s *Store) ExecRawForTest(ctx context.Context, stmt string) error {
	_, err := s.db.ExecContext(ctx, stmt)
	return err
}
