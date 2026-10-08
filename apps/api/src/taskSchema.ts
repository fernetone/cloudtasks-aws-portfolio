import { z } from 'zod';

export const taskCreateSchema = z.object({
  title: z.string().trim().min(1).max(160),
  dueDate: z.string().trim().max(255).nullable().optional(),
  important: z.boolean().optional().default(false),
});

export const taskUpdateSchema = z.object({
  title: z.string().trim().min(1).max(160).optional(),
  dueDate: z.string().trim().max(255).nullable().optional(),
  important: z.boolean().optional(),
  completed: z.boolean().optional(),
});
