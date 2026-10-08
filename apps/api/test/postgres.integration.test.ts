import { randomUUID } from 'node:crypto';
import pg from 'pg';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';

const integration = process.env.TEST_DATABASE_URL ? describe : describe.skip;

integration('migração de prazo em PostgreSQL real isolado', () => {
  const schema = `cloudtasks_test_${randomUUID().replaceAll('-', '')}`;
  let admin: pg.Pool;
  let database: typeof import('../src/db.js');
  let repository: import('../src/taskRepository.js').PgTaskRepository;
  let schemaCreated = false;

  beforeAll(async () => {
    const url = new URL(process.env.TEST_DATABASE_URL!);
    admin = new pg.Pool({ connectionString: url.toString() });
    await admin.query(`CREATE SCHEMA ${schema}`);
    schemaCreated = true;
    await admin.query(`CREATE TABLE ${schema}.tasks (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      title VARCHAR(160) NOT NULL,
      due_date DATE,
      important BOOLEAN NOT NULL DEFAULT FALSE,
      completed BOOLEAN NOT NULL DEFAULT FALSE,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )`);
    await admin.query(
      `INSERT INTO ${schema}.tasks (title, due_date, important) VALUES ($1, $2, $3)`,
      ['Tarefa anterior à migração', '2026-09-25', true],
    );
    url.searchParams.set('options', `-csearch_path=${schema}`);
    vi.stubEnv('DATABASE_URL', url.toString());
    database = await import('../src/db.js');
    const { PgTaskRepository } = await import('../src/taskRepository.js');
    repository = new PgTaskRepository(database.pool);
    await Promise.all([database.ensureSchema(), database.ensureSchema()]);
  });

  afterAll(async () => {
    await database?.pool.end();
    if (schemaCreated) await admin.query(`DROP SCHEMA ${schema} CASCADE`);
    await admin?.end();
    vi.unstubAllEnvs();
  });

  it('migra duas inicializações concorrentes preservando a data e a prioridade antigas', async () => {
    const old = (await repository.list()).find((task) => task.title === 'Tarefa anterior à migração');
    expect(old).toMatchObject({ dueDate: '2026-09-25', important: true, completed: false });
    const columns = await database.pool.query(
      "SELECT column_name, data_type FROM information_schema.columns WHERE table_schema = $1 AND table_name = 'tasks'",
      [schema],
    );
    expect(columns.rows).toEqual(expect.arrayContaining([
      { column_name: 'due_date', data_type: 'date' },
      { column_name: 'due_text', data_type: 'text' },
    ]));
  });

  it('grava e atualiza texto completo com caracteres especiais sem perder o prazo', async () => {
    const title = "Relatório d'água <script>alert(1)</script>";
    const dueDate = '2026-10-08 após as 18h — validar com João';
    const created = await repository.create({ title, dueDate, important: false });
    expect(created).toMatchObject({ title, dueDate });
    const updated = await repository.update(created.id, { important: true, completed: true });
    expect(updated).toMatchObject({ title, dueDate, important: true, completed: true });
    expect(await repository.findById(created.id)).toMatchObject({ title, dueDate });
    expect(await repository.remove(created.id)).toBe(true);
    expect(await repository.findById(created.id)).toBeNull();
  });

  it('mantém a coluna DATE para clientes antigos e preserva prazo nulo', async () => {
    for (const dueDate of ['2026-10-08', null]) {
      const created = await repository.create({ title: 'Cliente anterior', dueDate, important: false });
      expect(created.dueDate).toBe(dueDate);
      const raw = await database.pool.query(
        'SELECT due_date::text AS due_date, due_text FROM tasks WHERE id = $1', [created.id],
      );
      expect(raw.rows[0]).toEqual({ due_date: dueDate, due_text: null });
      await database.pool.query('UPDATE tasks SET due_date = $1 WHERE id = $2', ['2026-11-01', created.id]);
      expect((await repository.findById(created.id))?.dueDate).toBe('2026-11-01');
      await repository.remove(created.id);
    }
    await database.ensureSchema();
    expect((await repository.list()).find((task) => task.title === 'Tarefa anterior à migração')?.dueDate).toBe('2026-09-25');
  });
});
