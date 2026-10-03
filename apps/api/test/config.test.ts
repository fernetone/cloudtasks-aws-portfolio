import { describe, expect, it } from 'vitest';
import { buildDatabaseUrlFromSecret, resolveDatabaseUrl } from '../src/config.js';

describe('database configuration', () => {
  it('prefere DATABASE_URL explicita', () => {
    expect(
      resolveDatabaseUrl({
        DATABASE_URL: 'postgresql://direct:secret@db:5432/app',
        DATABASE_SECRET_JSON: '{"username":"ignored"}',
      }),
    ).toBe('postgresql://direct:secret@db:5432/app');
  });

  it('monta a URL a partir do secret sem expor a senha em arquivo de configuracao', () => {
    const secret = JSON.stringify({
      username: 'cloudtasks_admin',
      password: 'p@ss word',
      host: 'localhost.localstack.cloud',
      port: 4510,
      dbname: 'cloudtasks',
    });

    expect(buildDatabaseUrlFromSecret(secret, 'cloudtasks-localstack')).toBe(
      'postgresql://cloudtasks_admin:p%40ss%20word@cloudtasks-localstack:4510/cloudtasks',
    );
  });

  it('usa o fallback local quando nenhuma configuracao de banco foi fornecida', () => {
    expect(resolveDatabaseUrl({})).toBe(
      'postgresql://cloudtasks:cloudtasks@localhost:5432/cloudtasks',
    );
  });
});
