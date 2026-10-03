import path from 'node:path';
import { fileURLToPath } from 'node:url';
import cors from 'cors';
import express from 'express';
import helmet from 'helmet';
import { ZodError } from 'zod';
import { config } from './config.js';
import { pool } from './db.js';
import { taskRepository, type TaskRepository } from './taskRepository.js';
import { createTasksRouter } from './tasksRouter.js';

type AppDependencies = {
  repository?: TaskRepository;
  healthCheck?: () => Promise<void>;
};

export function createApp(dependencies: AppDependencies = {}) {
  const app = express();
  const repository = dependencies.repository ?? taskRepository;
  const healthCheck =
    dependencies.healthCheck ??
    (async () => {
      await pool.query('SELECT 1');
    });

  app.disable('x-powered-by');
  app.use(helmet({ contentSecurityPolicy: false }));
  app.use(express.json({ limit: '100kb' }));

  if (config.nodeEnv !== 'production') {
    app.use(cors({ origin: config.corsOrigin }));
  }

  app.get('/health', async (_req, res) => {
    try {
      await healthCheck();
      res.json({ status: 'ok', service: 'cloudtasks-api', database: 'ok' });
    } catch {
      res.status(503).json({
        status: 'error',
        service: 'cloudtasks-api',
        database: 'unavailable',
      });
    }
  });

  app.use('/api/tasks', createTasksRouter(repository));

  const currentDir = path.dirname(fileURLToPath(import.meta.url));
  const webDist = path.resolve(currentDir, '../../web/dist');
  if (config.nodeEnv === 'production') {
    app.use(express.static(webDist));
    app.get(/^(?!\/api|\/health).*/, (_req, res) => {
      res.sendFile(path.join(webDist, 'index.html'));
    });
  }

  app.use(
    (
      error: unknown,
      _req: express.Request,
      res: express.Response,
      _next: express.NextFunction,
    ) => {
      // Express identifica middleware de erro pela assinatura com 4 argumentos.
      // O `void` mantem o quarto argumento explicitamente usado sem alterar o runtime.
      void _next;

      if (error instanceof ZodError) {
        res.status(400).json({ message: 'Dados inválidos.', issues: error.issues });
        return;
      }
      console.error(error);
      res.status(500).json({ message: 'Erro interno do servidor.' });
    },
  );

  return app;
}
