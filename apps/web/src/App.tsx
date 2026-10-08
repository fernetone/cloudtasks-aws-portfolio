import { FormEvent, useCallback, useEffect, useRef, useState } from 'react';
import { taskApi } from './api';
import type { Task } from './types';
import './styles.css';

import { formatDate } from './date';
export default function App() {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [title, setTitle] = useState('');
  const [dueDate, setDueDate] = useState('');
  const [important, setImportant] = useState(false);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const [health, setHealth] = useState<'checking' | 'online' | 'offline'>('checking');
  const healthRequest = useRef<AbortController | null>(null);
  const [priorityPending, setPriorityPending] = useState<string[]>([]);
  const [theme, setTheme] = useState<'dark' | 'light'>(() => {
    try { return localStorage.getItem('theme') === 'light' ? 'light' : 'dark'; }
    catch { return 'dark'; }
  });
  const isAbout = window.location.pathname === '/about';

  const refreshHealth = useCallback(async () => {
    healthRequest.current?.abort();
    const controller = new AbortController();
    healthRequest.current = controller;
    const timeout = window.setTimeout(() => controller.abort(), 5000);
    setHealth('checking');
    try {
      const online = await taskApi.health(controller.signal);
      if (healthRequest.current === controller) setHealth(online ? 'online' : 'offline');
    } catch {
      if (healthRequest.current === controller) setHealth('offline');
    } finally {
      window.clearTimeout(timeout);
    }
  }, []);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
    try { localStorage.setItem('theme', theme); } catch { /* Preferência opcional. */ }
  }, [theme]);

  useEffect(() => {
    void refreshHealth();
    const interval = window.setInterval(() => void refreshHealth(), 30000);
    return () => {
      window.clearInterval(interval);
      healthRequest.current?.abort();
      healthRequest.current = null;
    };
  }, [refreshHealth]);

  async function loadTasks() {
    try {
      setError('');
      setTasks(await taskApi.list());
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Não foi possível carregar as tarefas.');
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void loadTasks();
  }, []);

  async function submit(event: FormEvent) {
    event.preventDefault();
    if (!title.trim()) {
      setError('Por favor, adicione uma descrição para a tarefa.');
      return;
    }
    setSaving(true);
    setError('');
    try {
      const created = await taskApi.create({ title: title.trim(), dueDate: dueDate || null, important });
      setTasks((current) => [created, ...current]);
      setTitle('');
      setDueDate('');
      setImportant(false);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Não foi possível criar a tarefa.');
    } finally {
      setSaving(false);
    }
  }

  async function toggle(task: Task) {
    try {
      setError('');
      const updated = await taskApi.update(task.id, { completed: !task.completed });
      setTasks((current) => current.map((item) => (item.id === task.id ? updated : item)));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Não foi possível atualizar a tarefa.');
    }
  }

  async function remove(id: string) {
    try {
      setError('');
      await taskApi.remove(id);
      setTasks((current) => current.filter((item) => item.id !== id));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Não foi possível excluir a tarefa.');
    }
  }

  async function rename(task: Task) {
    const nextTitle = window.prompt('Novo nome da tarefa:', task.title)?.trim();
    if (!nextTitle || nextTitle === task.title) return;
    try {
      setError('');
      const updated = await taskApi.update(task.id, { title: nextTitle });
      setTasks((current) => current.map((item) => (item.id === task.id ? updated : item)));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Não foi possível editar a tarefa.');
    }
  }

  async function changePriority(task: Task) {
    if (priorityPending.includes(task.id)) return;
    setPriorityPending((current) => [...current, task.id]);
    try {
      setError('');
      const updated = await taskApi.update(task.id, { important: !task.important });
      setTasks((current) => current.map((item) => (item.id === task.id ? updated : item)));
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Não foi possível alterar a prioridade.');
    } finally {
      setPriorityPending((current) => current.filter((id) => id !== task.id));
    }
  }

  const statusText = health === 'online' ? 'Online' : health === 'offline' ? 'Offline' : 'Verificando...';

  return (
    <main className="app">
      <div className="container">
        <header className="header">
          <h1>BIA</h1>
          <div className="header-controls">
            <button className={`version-trigger ${health}`} aria-label={`API: ${statusText}`} title={`API: ${statusText}`} disabled={health === 'checking'} onClick={() => void refreshHealth()}>
              <span aria-hidden="true">{health === 'online' ? '🟢' : health === 'offline' ? '🔴' : '🟡'}</span>
            </button>
            <button className="theme-toggle" aria-label={theme === 'dark' ? 'Tema claro' : 'Tema escuro'} title={theme === 'dark' ? 'Tema claro' : 'Tema escuro'} onClick={() => setTheme((current) => current === 'dark' ? 'light' : 'dark')}>
              <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
                {theme === 'dark' ? <><circle cx="12" cy="12" r="4" /><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5" /></> : <path d="M21 13a9 9 0 1 1-10-10 7 7 0 0 0 10 10Z" />}
              </svg>
            </button>
          </div>
        </header>

        {isAbout ? (
          <section className="about-page">
            <h2>Sobre a BIA</h2>
            <p>Organize suas tarefas, prazos e prioridades.</p>
            <a className="back-button" href="/">← Voltar</a>
          </section>
        ) : (
          <>
            <form className="add-form" onSubmit={submit}>
              <div className="form-control">
                <label htmlFor="task-title">Tarefa</label>
                <input id="task-title" type="text" value={title} onChange={(e) => setTitle(e.target.value)} placeholder="O que você precisa fazer?" maxLength={160} />
              </div>
              <div className="form-control">
                <label htmlFor="task-deadline">Data/Prazo</label>
                <input id="task-deadline" type="text" value={dueDate} onChange={(e) => setDueDate(e.target.value)} placeholder="Quando?" maxLength={255} />
              </div>
              <div className="form-control-check">
                <input id="important" type="checkbox" checked={important} onChange={(e) => setImportant(e.target.checked)} />
                <label htmlFor="important">Importante</label>
              </div>
              <button className="btn btn-block success" type="submit" disabled={saving}>{saving ? 'Adicionando...' : 'Adicionar Nova Tarefa'}</button>
            </form>

            {error && <div className="error-banner" role="alert">{error}</div>}
            {loading ? (
              <div className="empty-state">Carregando tarefas...</div>
            ) : tasks.length === 0 ? (
              <div className="empty-state">
                <h3>Nenhuma tarefa por aqui 📝</h3>
                <p>Adicione sua primeira tarefa usando o formulário acima!</p>
              </div>
            ) : (
              <section className="task-list" aria-label="Tarefas">
                {tasks.map((task) => (
                  <article key={task.id} className={`task ${task.important ? 'reminder' : ''} ${task.completed ? 'done' : ''}`} onDoubleClick={(event) => {
                    if ((event.target as Element).closest('button')) return;
                    void changePriority(task);
                  }}>
                    <button className="complete-button" aria-label={task.completed ? 'Reabrir tarefa' : 'Concluir tarefa'} onClick={() => void toggle(task)}>{task.completed ? '✓' : ''}</button>
                    <div className="task-content">
                      <h3>{task.title}</h3>
                      <p>📅 {formatDate(task.dueDate)}</p>
                    </div>
                    <div className="task-actions">
                      <button className="task-priority" aria-label={task.important ? 'Remover importante' : 'Marcar importante'} title={task.important ? 'Remover importante' : 'Marcar importante'} disabled={priorityPending.includes(task.id)} onClick={() => void changePriority(task)}>{task.important ? '★' : '☆'}</button>
                      <button className="task-edit" onClick={() => void rename(task)}>Editar</button>
                      <button className="task-delete" aria-label="Excluir tarefa" title="Excluir" onClick={() => void remove(task.id)}>×</button>
                    </div>
                  </article>
                ))}
              </section>
            )}
          </>
        )}
        <footer>
          <div className="footer-content">
            <p>Formação AWS</p>
            <a className="footer-link" href="/about">Sobre a BIA</a>
          </div>
        </footer>
      </div>
    </main>
  );
}
