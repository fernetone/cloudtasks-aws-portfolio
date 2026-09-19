import { z } from 'zod';

const optionalDate = z
  .union([z.string().regex(/^\d{4}-\d{2}-\d{2}$/), z.null()])
  .optional();

export const createTaskSchema = z.object({
  title: z.string().trim().min(1).max(160),
  dueDate: optionalDate,
  important: z.boolean().optional().default(false),
});

export const updateTaskSchema = z
  .object({
    title: z.string().trim().min(1).max(160).optional(),
    dueDate: optionalDate,
    important: z.boolean().optional(),
    completed: z.boolean().optional(),
  })
  .refine((payload) => Object.keys(payload).length > 0, {
    message: 'Informe ao menos um campo para atualizar.',
  });

export const taskIdSchema = z.string().uuid();
