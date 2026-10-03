import type { Pool } from 'pg';
import { pool } from './db.js';

export type Task = {
  id: string;
  title: string;
  dueDate: string | null;
  important: boolean;
  completed: boolean;
  createdAt: string;
  updatedAt: string;
};

export type CreateTaskInput = {
  title: string;
  dueDate: string | null;
  important: boolean;
};

export type UpdateTaskInput = Partial<
  Pick<Task, 'title' | 'dueDate' | 'important' | 'completed'>
>;

export interface TaskRepository {
  list(): Promise<Task[]>;
  create(input: CreateTaskInput): Promise<Task>;
  findById(id: string): Promise<Task | null>;
  update(id: string, input: UpdateTaskInput): Promise<Task | null>;
  remove(id: string): Promise<boolean>;
}

type TaskRow = {
  id: string;
  title: string;
  due_date: Date | string | null;
  important: boolean;
  completed: boolean;
  created_at: Date | string;
  updated_at: Date | string;
};

function normalizeDate(value: Date | string | null): string | null {
  if (value == null) return null;
  if (value instanceof Date) return value.toISOString().slice(0, 10);
  return value.slice(0, 10);
}

function normalizeTimestamp(value: Date | string): string {
  return value instanceof Date ? value.toISOString() : value;
}

function mapTask(row: TaskRow): Task {
  return {
    id: row.id,
    title: row.title,
    dueDate: normalizeDate(row.due_date),
    important: row.important,
    completed: row.completed,
    createdAt: normalizeTimestamp(row.created_at),
    updatedAt: normalizeTimestamp(row.updated_at),
  };
}

export class PgTaskRepository implements TaskRepository {
  constructor(private readonly db: Pool) {}

  async list(): Promise<Task[]> {
    const result = await this.db.query<TaskRow>(
      `SELECT * FROM tasks
       ORDER BY completed ASC, important DESC, due_date NULLS LAST, created_at DESC`,
    );
    return result.rows.map(mapTask);
  }

  async create(input: CreateTaskInput): Promise<Task> {
    const result = await this.db.query<TaskRow>(
      `INSERT INTO tasks (title, due_date, important)
       VALUES ($1, $2, $3)
       RETURNING *`,
      [input.title, input.dueDate, input.important],
    );
    return mapTask(result.rows[0]);
  }

  async findById(id: string): Promise<Task | null> {
    const result = await this.db.query<TaskRow>('SELECT * FROM tasks WHERE id = $1', [id]);
    return result.rows[0] ? mapTask(result.rows[0]) : null;
  }

  async update(id: string, input: UpdateTaskInput): Promise<Task | null> {
    const current = await this.findById(id);
    if (!current) return null;

    const result = await this.db.query<TaskRow>(
      `UPDATE tasks
       SET title = $1,
           due_date = $2,
           important = $3,
           completed = $4,
           updated_at = NOW()
       WHERE id = $5
       RETURNING *`,
      [
        input.title ?? current.title,
        input.dueDate === undefined ? current.dueDate : input.dueDate,
        input.important ?? current.important,
        input.completed ?? current.completed,
        id,
      ],
    );

    return result.rows[0] ? mapTask(result.rows[0]) : null;
  }

  async remove(id: string): Promise<boolean> {
    const result = await this.db.query('DELETE FROM tasks WHERE id = $1', [id]);
    return (result.rowCount ?? 0) > 0;
  }
}

export const taskRepository = new PgTaskRepository(pool);
