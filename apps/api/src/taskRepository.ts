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
  dueDate?: string | null;
  important?: boolean;
};

export type UpdateTaskInput = Partial<
  Pick<Task, 'title' | 'dueDate' | 'important' | 'completed'>
>;

export interface TaskRepository {
  list(): Promise<Task[]>;
  create(input: CreateTaskInput): Promise<Task>;
  update(id: string, input: UpdateTaskInput): Promise<Task | null>;
  remove(id: string): Promise<boolean>;
}

type TaskRow = {
  id: string;
  title: string;
  due_date: string | Date | null;
  important: boolean;
  completed: boolean;
  created_at: string | Date;
  updated_at: string | Date;
};

function normalizeDate(value: string | Date | null): string | null {
  if (value === null) return null;
  if (value instanceof Date) return value.toISOString().slice(0, 10);
  return String(value).slice(0, 10);
}

function normalizeDateTime(value: string | Date): string {
  return value instanceof Date ? value.toISOString() : String(value);
}

function mapTask(row: TaskRow): Task {
  return {
    id: row.id,
    title: row.title,
    dueDate: normalizeDate(row.due_date),
    important: row.important,
    completed: row.completed,
    createdAt: normalizeDateTime(row.created_at),
    updatedAt: normalizeDateTime(row.updated_at),
  };
}

export function createPostgresTaskRepository(): TaskRepository {
  return {
    async list() {
      const result = await pool.query<TaskRow>(`
        SELECT id, title, due_date, important, completed, created_at, updated_at
        FROM tasks
        ORDER BY completed ASC, important DESC, created_at DESC;
      `);
      return result.rows.map(mapTask);
    },

    async create(input) {
      const result = await pool.query<TaskRow>(
        `INSERT INTO tasks (title, due_date, important)
         VALUES ($1, $2, $3)
         RETURNING id, title, due_date, important, completed, created_at, updated_at;`,
        [input.title, input.dueDate ?? null, input.important ?? false],
      );
      return mapTask(result.rows[0]);
    },

    async update(id, input) {
      const existing = await pool.query<TaskRow>(
        `SELECT id, title, due_date, important, completed, created_at, updated_at
         FROM tasks WHERE id = $1;`,
        [id],
      );
      if (!existing.rowCount) return null;

      const current = mapTask(existing.rows[0]);
      const result = await pool.query<TaskRow>(
        `UPDATE tasks
         SET title = $2,
             due_date = $3,
             important = $4,
             completed = $5,
             updated_at = NOW()
         WHERE id = $1
         RETURNING id, title, due_date, important, completed, created_at, updated_at;`,
        [
          id,
          input.title ?? current.title,
          input.dueDate === undefined ? current.dueDate : input.dueDate,
          input.important ?? current.important,
          input.completed ?? current.completed,
        ],
      );
      return mapTask(result.rows[0]);
    },

    async remove(id) {
      const result = await pool.query('DELETE FROM tasks WHERE id = $1;', [id]);
      return Boolean(result.rowCount);
    },
  };
}
