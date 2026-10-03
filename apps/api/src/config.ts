import 'dotenv/config';

type DatabaseSecret = {
  username?: unknown;
  password?: unknown;
  host?: unknown;
  port?: unknown;
  dbname?: unknown;
};

function requireSecretString(value: unknown, field: keyof DatabaseSecret): string {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new Error(`DATABASE_SECRET_JSON invalido: campo ${field} ausente.`);
  }
  return value;
}

function requireSecretPort(value: unknown): number {
  const port = typeof value === 'number' ? value : Number(value);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error('DATABASE_SECRET_JSON invalido: porta ausente ou invalida.');
  }
  return port;
}

export function buildDatabaseUrlFromSecret(
  secretJson: string,
  hostOverride?: string,
): string {
  let secret: DatabaseSecret;
  try {
    secret = JSON.parse(secretJson) as DatabaseSecret;
  } catch {
    throw new Error('DATABASE_SECRET_JSON invalido: JSON malformado.');
  }

  const username = requireSecretString(secret.username, 'username');
  const password = requireSecretString(secret.password, 'password');
  const secretHost = requireSecretString(secret.host, 'host');
  const database = requireSecretString(secret.dbname, 'dbname');
  const port = requireSecretPort(secret.port);
  const host = hostOverride?.trim() || secretHost;

  return `postgresql://${encodeURIComponent(username)}:${encodeURIComponent(password)}@${host}:${port}/${encodeURIComponent(database)}`;
}

export function resolveDatabaseUrl(environment: NodeJS.ProcessEnv = process.env): string {
  if (environment.DATABASE_URL?.trim()) {
    return environment.DATABASE_URL;
  }

  if (environment.DATABASE_SECRET_JSON?.trim()) {
    return buildDatabaseUrlFromSecret(
      environment.DATABASE_SECRET_JSON,
      environment.DATABASE_HOST_OVERRIDE,
    );
  }

  return 'postgresql://cloudtasks:cloudtasks@localhost:5432/cloudtasks';
}

export const config = {
  port: Number(process.env.PORT ?? 3000),
  databaseUrl: resolveDatabaseUrl(),
  databaseSsl: (process.env.DATABASE_SSL ?? 'false').toLowerCase() === 'true',
  corsOrigin: process.env.CORS_ORIGIN ?? 'http://localhost:5173',
  nodeEnv: process.env.NODE_ENV ?? 'development',
};
