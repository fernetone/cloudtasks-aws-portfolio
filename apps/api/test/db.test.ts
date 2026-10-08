import { beforeEach, describe, expect, it, vi } from 'vitest';

const database = vi.hoisted(() => ({
  query: vi.fn(),
  release: vi.fn(),
  connect: vi.fn(),
  pooledQuery: vi.fn(),
}));

vi.mock('pg', () => ({
  default: {
    Pool: class {
      connect = database.connect;
      query = database.pooledQuery;
    },
  },
}));

import { ensureSchema } from '../src/db.js';

describe('bootstrap do schema PostgreSQL', () => {
  beforeEach(() => {
    vi.resetAllMocks();
    database.query.mockResolvedValue({ rows: [], rowCount: 0 });
    database.pooledQuery.mockResolvedValue({ rows: [], rowCount: 0 });
    database.connect.mockResolvedValue({
      query: database.query,
      release: database.release,
    });
  });

  it('protege a criacao por lock transacional na mesma conexao', async () => {
    await ensureSchema();

    const statements = database.query.mock.calls.map(([sql]) => String(sql).trim());
    expect(statements[0]).toBe('BEGIN');
    expect(statements[1]).toMatch(/^SELECT pg_advisory_xact_lock\(/);
    expect(statements[2]).toMatch(/^CREATE TABLE IF NOT EXISTS tasks/);
    expect(statements[3]).toBe('COMMIT');
    expect(statements).toHaveLength(4);
    expect(database.pooledQuery).not.toHaveBeenCalled();
    expect(database.release).toHaveBeenCalledOnce();
    expect(database.release).toHaveBeenCalledWith(false);
  });

  it.each(['BEGIN', 'LOCK', 'DDL', 'COMMIT'])(
    'propaga a falha de %s e encerra a transacao',
    async (phase) => {
      const original = new Error(`falha controlada de ${phase}`);
      database.query.mockImplementation(async (sql: string) => {
        const statement = sql.trim();
        if (
          (phase === 'BEGIN' && statement === 'BEGIN') ||
          (phase === 'LOCK' && statement.startsWith('SELECT pg_advisory_xact_lock(')) ||
          (phase === 'DDL' && statement.startsWith('CREATE TABLE')) ||
          (phase === 'COMMIT' && statement === 'COMMIT')
        ) {
          throw original;
        }
        return { rows: [], rowCount: 0 };
      });

      await expect(ensureSchema()).rejects.toBe(original);
      expect(database.query).toHaveBeenLastCalledWith('ROLLBACK');
      expect(database.release).toHaveBeenCalledWith(false);
    },
  );

  it('descarta a conexao se rollback falhar, preservando o erro original', async () => {
    const original = new Error('falha original de DDL');
    database.query.mockImplementation(async (sql: string) => {
      if (sql.trim().startsWith('CREATE TABLE')) throw original;
      if (sql === 'ROLLBACK') throw new Error('conexao interrompida');
      return { rows: [], rowCount: 0 };
    });

    await expect(ensureSchema()).rejects.toBe(original);
    expect(database.release).toHaveBeenCalledWith(true);
  });

  it('propaga falha ao adquirir conexao sem executar DDL', async () => {
    const original = new Error('conexao indisponivel');
    database.connect.mockRejectedValue(original);

    await expect(ensureSchema()).rejects.toBe(original);
    expect(database.query).not.toHaveBeenCalled();
    expect(database.pooledQuery).not.toHaveBeenCalled();
    expect(database.release).not.toHaveBeenCalled();
  });
});
