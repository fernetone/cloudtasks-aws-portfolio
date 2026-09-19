import { Router } from 'express';
import { createTaskSchema, taskIdSchema, updateTaskSchema } from './taskSchema.js';
import type { TaskRepository } from './taskRepository.js';

export function createTasksRouter(repository: TaskRepository) {
  const router = Router();

  router.get('/', async (_req, res) => {
    const tasks = await repository.list();
    res.json(tasks);
  });

  router.post('/', async (req, res) => {
    const payload = createTaskSchema.parse(req.body);
    const task = await repository.create(payload);
    res.status(201).json(task);
  });

  router.put('/:id', async (req, res) => {
    const id = taskIdSchema.parse(req.params.id);
    const payload = updateTaskSchema.parse(req.body);
    const task = await repository.update(id, payload);

    if (!task) {
      res.status(404).json({ message: 'Tarefa não encontrada.' });
      return;
    }

    res.json(task);
  });

  router.delete('/:id', async (req, res) => {
    const id = taskIdSchema.parse(req.params.id);
    const removed = await repository.remove(id);

    if (!removed) {
      res.status(404).json({ message: 'Tarefa não encontrada.' });
      return;
    }

    res.status(204).send();
  });

  return router;
}
