import { pathToFileURL } from "node:url";
import {
  toolRoot,
  readonlyRole,
  readonlySecret,
  mcpEnvironment,
} from "./mcp-config.mjs";
import { runtime, database, safeCode } from "./mcp-runtime.mjs";
try {
  const context = await runtime(),
    { value, connection } = await database(readonlySecret, context);
  if (
    value.username !== readonlyRole ||
    value.runtime !== context.localStackContainerId
  )
    throw Error("MCP_SECRET_OWNERSHIP_INVALID");
  const url = new URL(
    "postgresql://" +
      connection.host +
      ":" +
      connection.port +
      "/" +
      connection.database,
  );
  url.username = connection.user;
  url.password = connection.password;
  // Only this process's JS argv changes. No password is passed to an OS process.
  process.argv = [process.argv[0], process.argv[1], url.href];
  const clean = mcpEnvironment();
  for (const key of Object.keys(process.env))
    if (!(key in clean)) delete process.env[key];
  Object.assign(process.env, clean);
  await import(
    pathToFileURL(
      toolRoot +
        "/node/node_modules/@modelcontextprotocol/server-postgres/dist/index.js",
    ).href
  );
} catch (e) {
  console.error(safeCode(e));
  process.exitCode = 1;
}
