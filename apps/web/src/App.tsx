import { FormEvent, useEffect, useState } from 'react';
import { taskApi } from './api';
import { formatDate } from './date';
import type { Task } from './types';

export default function App() {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [title, setTitle] = useState('');
  const [dueDate, setDueDate] = useState('');
  const [important, setImportant] = useState(false);
  const [loading, setLoading] = useState(true);
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

  async function handleSubmit(event: FormEvent) {
    event.preventDefault();
    if (!title.trim()) return;

    try {
      setError('');
      await taskApi.create({
        title: title.trim(),
        dueDate: dueDate || null,
        important,
      });
      setTitle('');
      setDueDate('');
      setImportant(false);
      await loadTasks();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Não foi possível criar a tarefa.');
    }
  }

  async function toggle(task: Task) {
    try {
      setError('');
      await taskApi.update(task.id, { completed: !task.completed });
      await loadTasks();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Não foi possível atualizar a tarefa.');
    }
  }

  async function remove(task: Task) {
    try {
      setError('');
      await taskApi.remove(task.id);
      await loadTasks();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Não foi possível excluir a tarefa.');
    }
  }

  return (
    <main className="shell">
      <header className="hero">
        <div>
          <p className="eyebrow">AWS DEVOPS PORTFOLIO</p>
          <h1>CloudTasks</h1>
          <p className="subtitle">
            CRUD full stack containerizado, preparado para evoluir até GitHub → CodePipeline → CodeBuild →
            ECR → ECS/EC2 → ALB → CloudFront.
          </p>
        </div>
        <span className="badge">Etapa local</span>
      </header>

      <section className="panel">
        <form className="form-grid" onSubmit={handleSubmit}>
          <input
            aria-label="Título da tarefa"
            value={title}
            onChange={(event) => setTitle(event.target.value)}
            placeholder="Ex.: Configurar Amazon ECS"
            maxLength={160}
          />
          <input
            aria-label="Data da tarefa"
            type="date"
            value={dueDate}
            onChange={(event) => setDueDate(event.target.value)}
          />
          <label className="checkbox">
            <input
              type="checkbox"
              checked={important}
              onChange={(event) => setImportant(event.target.checked)}
            />
            Importante
          </label>
          <button className="primary" type="submit">
            Adicionar tarefa
          </button>
        </form>
      </section>

      {error && <p className="error">{error}</p>}

      <section className="list" aria-live="polite">
        {loading ? (
          <div className="empty">Carregando...</div>
        ) : tasks.length === 0 ? (
          <div className="empty">Nenhuma tarefa ainda.</div>
        ) : (
          tasks.map((task) => (
            <article className={`task ${task.completed ? 'completed' : ''}`} key={task.id}>
              <div className="task-main">
                <input
                  aria-label={`Concluir ${task.title}`}
                  type="checkbox"
                  checked={task.completed}
                  onChange={() => void toggle(task)}
                />
                <div>
                  <h2>
                    {task.important && <span className="star">★ </span>}
                    {task.title}
                  </h2>
                  <p>{task.dueDate ? `Prazo: ${formatDate(task.dueDate)}` : 'Sem prazo definido'}</p>
                </div>
              </div>
              <div className="actions">
                <button className="danger" type="button" onClick={() => void remove(task)}>
                  Excluir
                </button>
              </div>
            </article>
          ))
        )}
      </section>
    </main>
  );
}
