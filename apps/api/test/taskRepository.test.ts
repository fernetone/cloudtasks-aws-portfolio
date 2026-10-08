import type { Pool } from 'pg';
import { describe, expect, it, vi } from 'vitest';
import { PgTaskRepository } from '../src/taskRepository.js';

const row = {
  id: '11111111-1111-4111-8111-111111111111',
  title: 'Enviar relatório',
  due_date: '2026-09-25',
  due_text: 'Amanhã às 18h, após a reunião',
  important: false,
  completed: false,
  created_at: '2026-09-20T12:00:00.000Z',
  updated_at: '2026-09-20T12:00:00.000Z',
};

describe('prazo da tarefa no PostgreSQL', () => {
  it('retorna todo o prazo textual sem truncar nem substituir pela data antiga', async () => {
    const db = { query: vi.fn().mockResolvedValue({ rows: [row] }) };
    const repository = new PgTaskRepository(db as unknown as Pool);
    expect((await repository.list())[0].dueDate).toBe('Amanhã às 18h, após a reunião');
  });

  it('lê a data de registros anteriores que ainda não têm prazo textual', async () => {
    const db = { query: vi.fn().mockResolvedValue({ rows: [{ ...row, due_text: null }] }) };
    const repository = new PgTaskRepository(db as unknown as Pool);
    expect((await repository.list())[0].dueDate).toBe('2026-09-25');
  });

  it('preserva o texto ao editar somente a prioridade', async () => {
    const db = { query: vi.fn().mockResolvedValue({ rows: [row] }) };
    const repository = new PgTaskRepository(db as unknown as Pool);
    const result = await repository.update(row.id, { important: true });
    expect(result?.dueDate).toBe('Amanhã às 18h, após a reunião');
    expect(db.query.mock.calls[1][1]).toContain('Amanhã às 18h, após a reunião');
  });

  it('guarda datas ISO somente na coluna DATE para receber futuras edições de clientes anteriores', async () => {
    const db = { query: vi.fn().mockResolvedValue({ rows: [{ ...row, due_text: null }] }) };
    const repository = new PgTaskRepository(db as unknown as Pool);
    await repository.create({ title: row.title, dueDate: '2026-09-25', important: false });
    expect(db.query.mock.calls[0][1]).toEqual([row.title, '2026-09-25', null, false]);
    await repository.update(row.id, { dueDate: '2026-10-08' });
    expect(db.query.mock.calls[2][1]).toEqual([row.title, '2026-10-08', null, false, false, row.id]);
  });
});
