import { describe, expect, it } from 'vitest';
import { requireTestDatabase } from '../integration/helpers.ts';

// The integration tests drop and recreate tables: DB_* exported for other work never reaches them.
const REFUSED = [undefined, '', 'dx02v2', 'postgres', 'test', '_test', 'dx02v2_test_backup', 'app-test'];

describe('requireTestDatabase', () => {
  it('accepts a database whose name ends in _test', () => {
    expect(requireTestDatabase('dx02v2_test')).toBe('dx02v2_test');
  });

  it.each(REFUSED)('refuses %j', (name) => {
    expect(() => requireTestDatabase(name)).toThrow(/DB_NAME must end in _test/);
  });
});
