import { FormEvent, useEffect, useState } from 'react';
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
    if (!title.trim()) return;
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

  return (
    <main className="page-shell">
      <section className="hero">
        <div>
          <span className="eyebrow">AWS PORTFOLIO PROJECT</span>
          <h1>CloudTasks</h1>
          <p>Organize suas tarefas, prioridades e prazos em um único lugar.</p>
        </div>
        <div className="status-pill"><span /> API + PostgreSQL</div>
      </section>

      <section className="card composer">
        <form onSubmit={submit}>
          <label>
            Tarefa
            <input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="O que você precisa fazer?" maxLength={160} />
          </label>
          <label>
            Data / prazo
            <input type="date" value={dueDate} onChange={(e) => setDueDate(e.target.value)} />
          </label>
          <label className="check-row">
            <input type="checkbox" checked={important} onChange={(e) => setImportant(e.target.checked)} />
            Importante
          </label>
          <button type="submit" disabled={saving || !title.trim()}>{saving ? 'Adicionando...' : 'Adicionar nova tarefa'}</button>
        </form>
      </section>

      {error && <div className="error-banner">{error}</div>}

      <section className="tasks-section">
        <div className="section-heading">
          <div><span className="eyebrow">MINHAS TAREFAS</span><h2>Fila de execução</h2></div>
          <strong>{tasks.filter((task) => !task.completed).length} pendente(s)</strong>
        </div>

        {loading ? (
          <div className="empty card">Carregando tarefas...</div>
        ) : tasks.length === 0 ? (
          <div className="empty card">Nenhuma tarefa ainda. Crie a primeira acima.</div>
        ) : (
          <div className="task-list">
            {tasks.map((task) => (
              <article key={task.id} className={`task card ${task.completed ? 'done' : ''}`}>
                <button className="complete-button" aria-label="Alternar conclusão" onClick={() => void toggle(task)}>{task.completed ? '✓' : ''}</button>
                <div className="task-content">
                  <div className="task-title-row">
                    <h3>{task.title}</h3>
                    {task.important && <span className="important">Importante</span>}
                  </div>
                  <p>{formatDate(task.dueDate)}</p>
                </div>
                <div className="actions">
                  <button onClick={() => void rename(task)}>Editar</button>
                  <button className="danger" onClick={() => void remove(task.id)}>Excluir</button>
                </div>
              </article>
            ))}
          </div>
        )}
      </section>
    </main>
  );
}
