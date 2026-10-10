import { runtime, database, packageRequire, safeCode } from "./mcp-runtime.mjs";
import { readonlyRole, readonlySecret } from "./mcp-config.mjs";
let client;
try {
  const context = await runtime(),
    { value, connection } = await database(readonlySecret, context);
  if (
    value.username !== readonlyRole ||
    value.runtime !== context.localStackContainerId
  )
    throw Error("MCP_SECRET_OWNERSHIP_INVALID");
  const { Client } = packageRequire("pg");
  client = new Client(connection);
  await client.connect();
  const { rows } = await client.query(
    "SELECT current_user AS role,current_database() AS database,count(*)::int AS count,md5(coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb)::text) AS fingerprint FROM public.tasks t",
  );
  if (
    rows.length !== 1 ||
    rows[0].role !== readonlyRole ||
    rows[0].database !== "cloudtasks"
  )
    throw Error("MCP_POSTGRES_IDENTITY_INVALID");
  await client.end();
  client = null;
  console.log(JSON.stringify(rows[0]));
} catch (error) {
  console.error(safeCode(error));
  process.exitCode = 1;
} finally {
  if (client) await client.end().catch(() => {});
}
