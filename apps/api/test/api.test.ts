import request from 'supertest';
import { describe, expect, it } from 'vitest';
import { createApp } from '../src/app.js';
import type {
  CreateTaskInput,
  Task,
  TaskRepository,
  UpdateTaskInput,
} from '../src/taskRepository.js';

class InMemoryTaskRepository implements TaskRepository {
  tasks: Task[] = [];

  async list() {
    return this.tasks;
  }

  async create(input: CreateTaskInput) {
    const now = new Date().toISOString();
    const task: Task = {
      id: crypto.randomUUID(),
      title: input.title,
      dueDate: input.dueDate ?? null,
      important: input.important ?? false,
      completed: false,
      createdAt: now,
      updatedAt: now,
    };
    this.tasks.push(task);
    return task;
  }

  async update(id: string, input: UpdateTaskInput) {
    const index = this.tasks.findIndex((task) => task.id === id);
    if (index === -1) return null;
    this.tasks[index] = {
      ...this.tasks[index],
      ...input,
      updatedAt: new Date().toISOString(),
    };
    return this.tasks[index];
  }

  async remove(id: string) {
    const originalLength = this.tasks.length;
    this.tasks = this.tasks.filter((task) => task.id !== id);
    return this.tasks.length !== originalLength;
  }
}

describe('CloudTasks API', () => {
  it('executa o CRUD de uma tarefa', async () => {
    const repository = new InMemoryTaskRepository();
    const app = createApp(repository);

    const created = await request(app).post('/api/tasks').send({
      title: 'Configurar Amazon ECS',
      dueDate: '2026-09-20',
      important: true,
    });

    expect(created.status).toBe(201);
    expect(created.body.title).toBe('Configurar Amazon ECS');

    const listed = await request(app).get('/api/tasks');
    expect(listed.status).toBe(200);
    expect(listed.body).toHaveLength(1);

    const updated = await request(app)
      .put(`/api/tasks/${created.body.id}`)
      .send({ completed: true });
    expect(updated.status).toBe(200);
    expect(updated.body.completed).toBe(true);

    const removed = await request(app).delete(`/api/tasks/${created.body.id}`);
    expect(removed.status).toBe(204);
  });

  it('rejeita payload inválido', async () => {
    const app = createApp(new InMemoryTaskRepository());
    const response = await request(app).post('/api/tasks').send({ title: '' });
    expect(response.status).toBe(400);
  });

  it('rejeita UUID inválido', async () => {
    const app = createApp(new InMemoryTaskRepository());
    const response = await request(app).delete('/api/tasks/123');
    expect(response.status).toBe(400);
  });

  it('retorna 404 quando a tarefa não existe', async () => {
    const app = createApp(new InMemoryTaskRepository());
    const response = await request(app)
      .put(`/api/tasks/${crypto.randomUUID()}`)
      .send({ completed: true });
    expect(response.status).toBe(404);
  });
});
