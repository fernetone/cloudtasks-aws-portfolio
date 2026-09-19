import type { Task } from './types';

const API_URL = import.meta.env.VITE_API_URL ?? '/api';

async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const response = await fetch(`${API_URL}${path}`, {
    headers: { 'Content-Type': 'application/json', ...(options?.headers ?? {}) },
    ...options,
  });

  if (!response.ok) {
    const payload = await response.json().catch(() => ({}));
    throw new Error(payload.message ?? `Erro HTTP ${response.status}`);
  }

  if (response.status === 204) return undefined as T;
  return response.json() as Promise<T>;
}

export const taskApi = {
  list: () => request<Task[]>('/tasks'),
  create: (payload: { title: string; dueDate: string | null; important: boolean }) =>
    request<Task>('/tasks', {
      method: 'POST',
      body: JSON.stringify(payload),
    }),
  update: (
    id: string,
    payload: Partial<Pick<Task, 'title' | 'dueDate' | 'important' | 'completed'>>,
  ) =>
    request<Task>(`/tasks/${id}`, {
      method: 'PUT',
      body: JSON.stringify(payload),
    }),
  remove: (id: string) => request<void>(`/tasks/${id}`, { method: 'DELETE' }),
};
