import 'dotenv/config';

export const config = {
  port: Number(process.env.PORT ?? 3000),
  databaseUrl:
    process.env.DATABASE_URL ??
    'postgresql://cloudtasks:cloudtasks@localhost:5432/cloudtasks',
  databaseSsl: (process.env.DATABASE_SSL ?? 'false').toLowerCase() === 'true',
  corsOrigin: process.env.CORS_ORIGIN ?? 'http://localhost:5173',
  nodeEnv: process.env.NODE_ENV ?? 'development',
};
