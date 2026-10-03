import { Router } from 'express';
import { z } from 'zod';
import { taskCreateSchema, taskUpdateSchema } from './taskSchema.js';
import type { TaskRepository } from './taskRepository.js';

const taskIdSchema = z.string().uuid();

export function createTasksRouter(repository: TaskRepository) {
  const router = Router();

  router.get('/', async (_req, res, next) => {
    try {
      res.json(await repository.list());
    } catch (error) {
      next(error);
    }
  });

  router.post('/', async (req, res, next) => {
    try {
      const parsed = taskCreateSchema.parse(req.body);
      const created = await repository.create({
        title: parsed.title,
        dueDate: parsed.dueDate ?? null,
        important: parsed.important,
      });
      res.status(201).json(created);
    } catch (error) {
      next(error);
    }
  });

  router.put('/:id', async (req, res, next) => {
    try {
      const id = taskIdSchema.parse(req.params.id);
      const parsed = taskUpdateSchema.parse(req.body);
      const updated = await repository.update(id, parsed);
      if (!updated) {
        res.status(404).json({ message: 'Tarefa não encontrada.' });
        return;
      }
      res.json(updated);
    } catch (error) {
      next(error);
    }
  });

  router.delete('/:id', async (req, res, next) => {
    try {
      const id = taskIdSchema.parse(req.params.id);
      const removed = await repository.remove(id);
      if (!removed) {
        res.status(404).json({ message: 'Tarefa não encontrada.' });
        return;
      }
      res.status(204).send();
    } catch (error) {
      next(error);
    }
  });

  return router;
}
