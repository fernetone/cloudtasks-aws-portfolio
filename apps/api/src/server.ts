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
    console.error('Encerramento excedeu 10s. Finalizando processo.');
    process.exit(1);
  }, 10_000);
  forceExit.unref();

  server.close(async () => {
    try {
      await pool.end();
      clearTimeout(forceExit);
      process.exit(0);
    } catch (error) {
      console.error('Erro ao encerrar pool do PostgreSQL.', error);
      process.exit(1);
    }
  });
}

process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));
