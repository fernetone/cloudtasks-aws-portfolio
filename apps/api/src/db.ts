import pg from 'pg';
import { config } from './config.js';

const { Pool } = pg;

export const pool = new Pool({
  connectionString: config.databaseUrl,
  ssl: config.databaseSsl ? { rejectUnauthorized: false } : false,
});

export async function ensureSchema() {
  const client = await pool.connect();
  let discardConnection = false;
  try {
    await client.query('BEGIN');
    // Serialize first-start DDL across replicas; the lock ends with the transaction.
    await client.query(
      "SELECT pg_advisory_xact_lock(hashtext('cloudtasks'), hashtext('schema-init'))",
    );
    await client.query(`
    CREATE TABLE IF NOT EXISTS tasks (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      title VARCHAR(160) NOT NULL,
      due_date DATE,
      due_text TEXT,
      important BOOLEAN NOT NULL DEFAULT FALSE,
      completed BOOLEAN NOT NULL DEFAULT FALSE,
      created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    );
    ALTER TABLE tasks ADD COLUMN IF NOT EXISTS due_text TEXT;
    CREATE OR REPLACE FUNCTION cloudtasks_sync_legacy_deadline()
    RETURNS TRIGGER LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.due_date IS DISTINCT FROM OLD.due_date
         AND NEW.due_text IS NOT DISTINCT FROM OLD.due_text THEN
        NEW.due_text := NULL;
      END IF;
      RETURN NEW;
    END;
    $$;
    DROP TRIGGER IF EXISTS cloudtasks_legacy_deadline ON tasks;
    CREATE TRIGGER cloudtasks_legacy_deadline
      BEFORE UPDATE OF due_date ON tasks
      FOR EACH ROW EXECUTE FUNCTION cloudtasks_sync_legacy_deadline();
  `);
    await client.query('COMMIT');
  } catch (error) {
    try {
      await client.query('ROLLBACK');
    } catch {
      discardConnection = true;
    }
    throw error;
  } finally {
    client.release(discardConnection);
  }
}
