import request from 'supertest';
import { beforeEach, describe, expect, it } from 'vitest';
import { createApp } from '../src/app.js';
import type {
  CreateTaskInput,
  Task,
  TaskRepository,
  UpdateTaskInput,
} from '../src/taskRepository.js';

class InMemoryTaskRepository implements TaskRepository {
  private tasks: Task[] = [];

  async list(): Promise<Task[]> {
    return [...this.tasks];
  }

  async create(input: CreateTaskInput): Promise<Task> {
    const now = new Date().toISOString();
    const task: Task = {
      id: crypto.randomUUID(),
      title: input.title,
      dueDate: input.dueDate,
      important: input.important,
      completed: false,
      createdAt: now,
      updatedAt: now,
    };
    this.tasks.unshift(task);
    return task;
  }

  async findById(id: string): Promise<Task | null> {
    return this.tasks.find((task) => task.id === id) ?? null;
  }

  async update(id: string, input: UpdateTaskInput): Promise<Task | null> {
    const index = this.tasks.findIndex((task) => task.id === id);
    if (index < 0) return null;
    const updated = {
      ...this.tasks[index],
      ...input,
      updatedAt: new Date().toISOString(),
    };
    this.tasks[index] = updated;
    return updated;
  }

  async remove(id: string): Promise<boolean> {
    const initialLength = this.tasks.length;
    this.tasks = this.tasks.filter((task) => task.id !== id);
    return this.tasks.length < initialLength;
  }
}

describe('CloudTasks API', () => {
  let repository: InMemoryTaskRepository;

  beforeEach(() => {
    repository = new InMemoryTaskRepository();
  });

  it('retorna health 200 quando dependências estão disponíveis', async () => {
    const app = createApp({ repository, healthCheck: async () => undefined });

    await request(app)
      .get('/health')
      .expect(200)
      .expect({ status: 'ok', service: 'cloudtasks-api', database: 'ok' });
  });

  it('retorna health 503 quando a dependência de dados falha', async () => {
    const app = createApp({
      repository,
      healthCheck: async () => {
        throw new Error('database offline');
      },
    });

    await request(app)
      .get('/health')
      .expect(503)
      .expect({
        status: 'error',
        service: 'cloudtasks-api',
        database: 'unavailable',
      });
  });

  it('executa o fluxo CRUD completo', async () => {
    const app = createApp({ repository, healthCheck: async () => undefined });

    const created = await request(app)
      .post('/api/tasks')
      .send({ title: 'Configurar Amazon ECS', dueDate: '2026-09-25', important: true })
      .expect(201);

    expect(created.body).toMatchObject({
      title: 'Configurar Amazon ECS',
      dueDate: '2026-09-25',
      important: true,
      completed: false,
    });

    const id = created.body.id as string;

    const listed = await request(app).get('/api/tasks').expect(200);
    expect(listed.body).toHaveLength(1);

    const updated = await request(app)
      .put(`/api/tasks/${id}`)
      .send({ completed: true, title: 'Configurar ECS em produção' })
      .expect(200);

    expect(updated.body).toMatchObject({
      id,
      title: 'Configurar ECS em produção',
      completed: true,
    });

    await request(app).delete(`/api/tasks/${id}`).expect(204);
    const empty = await request(app).get('/api/tasks').expect(200);
    expect(empty.body).toEqual([]);
  });

  it('rejeita payload inválido', async () => {
    const app = createApp({ repository, healthCheck: async () => undefined });

    const response = await request(app)
      .post('/api/tasks')
      .send({ title: '', dueDate: 'data-invalida' })
      .expect(400);

    expect(response.body.message).toBe('Dados inválidos.');
  });

  it('preserva prazo em texto na criação e na edição de prioridade', async () => {
    const app = createApp({ repository, healthCheck: async () => undefined });
    const dueDate = 'Amanhã às 18h, após a reunião';
    const created = await request(app)
      .post('/api/tasks')
      .send({ title: 'Enviar relatório', dueDate })
      .expect(201);

    expect(created.body.dueDate).toBe(dueDate);
    const updated = await request(app)
      .put(`/api/tasks/${created.body.id}`)
      .send({ important: true })
      .expect(200);
    expect(updated.body).toMatchObject({ dueDate, important: true });
    const listed = await request(app).get('/api/tasks').expect(200);
    expect(listed.body[0].dueDate).toBe(dueDate);
  });

  it('mantém datas ISO e prazo nulo compatíveis', async () => {
    const app = createApp({ repository, healthCheck: async () => undefined });
    for (const dueDate of ['2026-09-25', null]) {
      const created = await request(app)
        .post('/api/tasks')
        .send({ title: 'Tarefa existente', dueDate })
        .expect(201);
      expect(created.body.dueDate).toBe(dueDate);
    }
  });

  it('rejeita prazo com tipo incorreto ou mais de 255 caracteres', async () => {
    const app = createApp({ repository, healthCheck: async () => undefined });
    for (const dueDate of [123, 'x'.repeat(256)]) {
      await request(app)
        .post('/api/tasks')
        .send({ title: 'Enviar relatório', dueDate })
        .expect(400);
    }
  });
});
