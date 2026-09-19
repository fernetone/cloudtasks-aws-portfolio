import { createApp } from './app.js';
import { config } from './config.js';
import { ensureSchema, pool } from './db.js';

await ensureSchema();

const app = createApp();
const server = app.listen(config.port, '0.0.0.0', () => {
  console.log(`CloudTasks API ouvindo na porta ${config.port}`);
});

let shuttingDown = false;

async function shutdown(signal: string) {
  if (shuttingDown) return;
  shuttingDown = true;

  console.log(`${signal} recebido. Encerrando CloudTasks...`);

  const forceExit = setTimeout(() => {
    console.error('Encerramento gracioso excedeu o limite de tempo.');
    process.exit(1);
  }, 10_000);
  forceExit.unref();

  server.close(async (error) => {
    try {
      await pool.end();
    } finally {
      if (error) {
        console.error(error);
        process.exit(1);
      }
      process.exit(0);
    }
  });
}

process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));
