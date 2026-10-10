import { pathToFileURL } from "node:url";
import { readFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import {
  toolRoot,
  mcpEnvironment,
  readonlyRole,
  readonlySecret,
} from "./mcp-config.mjs";
import { runtime, database, save, safeCode } from "./mcp-runtime.mjs";
const base = toolRoot + "/node/node_modules/@modelcontextprotocol/sdk/dist/";
const { Client } = await import(pathToFileURL(base + "client/index.js").href);
const { StdioClientTransport } = await import(
  pathToFileURL(base + "client/stdio.js").href
);
const sessions = [];
import { closeMcpSessions } from "./mcp-session-lifecycle.mjs";
let proof, shutdown;
let phase = "runtime";
const started = performance.now();
const requireValue = (value, code) => {
  if (!value) throw Error(code);
};
function decoded(result) {
  requireValue(!result.isError, "MCP_TOOL_RETURNED_ERROR");
  const text = result.content
    ?.filter((c) => c.type === "text")
    .map((c) => c.text)
    .join("\n");
  try {
    return JSON.parse(text);
  } catch {
    throw Error("MCP_TOOL_JSON_INVALID");
  }
}
function find(value, key) {
  if (!value || typeof value !== "object") return undefined;
  if (Object.hasOwn(value, key)) return value[key];
  for (const child of Object.values(value)) {
    const result = find(child, key);
    if (result !== undefined) return result;
  }
  return undefined;
}
async function connect(file) {
  phase = file === "ecs-stdio.mjs" ? "ecs-initialize" : "postgres-initialize";
  const client = new Client(
    { name: "cloudtasks-functional-verifier", version: "1.0.0" },
    { capabilities: {} },
  );
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [toolRoot + "/project/scripts/mcp/" + file],
    env: mcpEnvironment(),
    stderr: "pipe",
  });
  sessions.push({ name: file, client, transport });
  const connecting = client.connect(transport);
  transport.stderr?.on("data", () => {});
  try {
    await connecting;
  } catch (e) {
    if (e.code === -2) throw Error("MCP_SERVER_INITIALIZATION_TIMEOUT");
    if (e.code === -1) throw Error("MCP_SERVER_CONNECTION_CLOSED");
    throw e;
  }
  return client;
}
async function call(client, name, args) {
  return await client.callTool({ name, arguments: args }, undefined, {
    timeout: 90000,
  });
}
try {
  const context = await runtime(),
    source = await database("cloudtasks/database", context),
    reader = await database(readonlySecret, context);
  const privateValues = [
    source.value.password,
    reader.value.password,
    process.env.LOCALSTACK_AUTH_TOKEN,
  ].filter((v) => typeof v === "string" && v.length >= 8);
  const noSecrets = (value) => {
    const text = JSON.stringify(value);
    for (const s of privateValues)
      for (const v of [
        s,
        encodeURIComponent(s),
        Buffer.from(s).toString("base64"),
      ])
        requireValue(!text.includes(v), "MCP_RESPONSE_CONTAINS_SECRET");
  };
  const ecs = await connect("ecs-stdio.mjs"),
    ecsTools = await ecs.listTools();
  requireValue(
    ecsTools.tools.some((t) => t.name === "ecs_resource_management"),
    "MCP_ECS_RESOURCE_TOOL_MISSING",
  );
  console.log("MCP_ECS_INITIALIZED");
  phase = "ecs-clusters";
  const clusters = decoded(
    await call(ecs, "ecs_resource_management", {
      api_operation: "ListClusters",
      api_params: {},
    }),
  );
  noSecrets(clusters);
  requireValue(
    find(clusters, "clusterArns")?.some((a) =>
      a.endsWith("/" + context.cluster),
    ),
    "MCP_CURRENT_CLUSTER_NOT_READ",
  );
  phase = "ecs-service";
  const described = decoded(
    await call(ecs, "ecs_resource_management", {
      api_operation: "DescribeServices",
      api_params: { cluster: context.cluster, services: [context.service] },
    }),
  );
  noSecrets(described);
  const service = find(described, "services")?.find(
    (s) => s.serviceName === context.service,
  );
  requireValue(
    service?.runningCount === 2 &&
      service.desiredCount === 2 &&
      service.pendingCount === 0,
    "MCP_ECS_SERVICE_NOT_HEALTHY",
  );
  phase = "ecs-task-definition";
  const taskDefinition = decoded(
    await call(ecs, "ecs_resource_management", {
      api_operation: "DescribeTaskDefinition",
      api_params: { taskDefinition: service.taskDefinition },
    }),
  );
  noSecrets(taskDefinition);
  phase = "ecs-write-denial";
  let ecsWriteDenied = false;
  try {
    const denied = await call(ecs, "ecs_resource_management", {
      api_operation: "DeleteCluster",
      api_params: { cluster: "cloudtasks-mcp-denial-canary-" + randomUUID() },
    });
    noSecrets(denied);
    ecsWriteDenied =
      /ALLOW_WRITE|requires write|write.*(disabled|permission|not allowed)|read.only/i.test(
        JSON.stringify(denied),
      );
  } catch (e) {
    ecsWriteDenied =
      /ALLOW_WRITE|requires write|write.*(disabled|permission|not allowed)|read.only/i.test(
        e.message ?? "",
      );
  }
  requireValue(ecsWriteDenied, "MCP_ECS_WRITE_NOT_DENIED");
  console.log("MCP_ECS_REAL_READ_AND_WRITE_DENIAL_ACCEPTED");
  const postgres = await connect("postgres-stdio.mjs"),
    postgresTools = await postgres.listTools();
  requireValue(
    postgresTools.tools.some((t) => t.name === "query"),
    "MCP_POSTGRES_QUERY_TOOL_MISSING",
  );
  const resources = await postgres.listResources();
  phase = "postgres-schema";
  noSecrets(resources);
  const tasks = resources.resources.find((r) => r.name.includes("tasks"));
  requireValue(tasks, "MCP_TASKS_SCHEMA_RESOURCE_MISSING");
  const schema = await postgres.readResource({ uri: tasks.uri });
  noSecrets(schema);
  const columns = JSON.parse(schema.contents[0].text);
  requireValue(
    ["id", "title", "due_text", "important", "completed"].every((n) =>
      columns.some((c) => c.column_name === n),
    ),
    "MCP_TASKS_SCHEMA_NOT_READ",
  );
  const query = async (sql) => {
    const result = decoded(await call(postgres, "query", { sql }));
    noSecrets(result);
    return result;
  };
  phase = "postgres-queries";
  const identity = (
    await query(
      "SELECT current_user AS role,current_database() AS database,current_setting('server_version') AS version",
    )
  )[0];
  requireValue(
    identity.role === readonlyRole && identity.database === "cloudtasks",
    "MCP_POSTGRES_IDENTITY_INVALID",
  );
  const fingerprint =
    "SELECT count(*)::int AS count,md5(coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb)::text) AS fingerprint FROM public.tasks t";
  const before = (await query(fingerprint))[0];
  phase = "postgres-write-denial";
  let postgresWriteDenied = false,
    transactionEscapeDenied = false;
  try {
    await query("UPDATE public.tasks SET title=title WHERE false");
  } catch (e) {
    postgresWriteDenied = /read.only|permission denied/i.test(e.message ?? "");
  }
  requireValue(
    postgresWriteDenied,
    "MCP_POSTGRES_TRANSACTION_WRITE_NOT_DENIED",
  );
  try {
    await query(
      "COMMIT; BEGIN READ WRITE; UPDATE public.tasks SET title=title WHERE false",
    );
  } catch (e) {
    transactionEscapeDenied = /permission denied/i.test(e.message ?? "");
  }
  requireValue(transactionEscapeDenied, "MCP_POSTGRES_ROLE_ESCAPE_NOT_DENIED");
  phase = "postgres-fingerprint";
  const after = (await query(fingerprint))[0];
  requireValue(
    JSON.stringify(before) === JSON.stringify(after),
    "MCP_TASK_DATA_CHANGED",
  );
  const bootstrap = JSON.parse(
    await readFile(toolRoot + "/postgres-bootstrap-evidence.json", "utf8"),
  );
  requireValue(
    bootstrap.status === "PASSED" && bootstrap.databasePermissionDenialVerified,
    "MCP_DATABASE_BOOTSTRAP_NOT_VERIFIED",
  );
  proof = {
    schemaVersion: 1,
    status: "PASSED",
    scope:
      "real stdio MCP initialization, tools, local ECS and PostgreSQL queries; Q chat not yet authenticated",
    ...context,
    ecs: {
      package: "awslabs.ecs-mcp-server",
      packageVersion: "0.1.36",
      server: ecs.getServerVersion(),
      resourceToolLoaded: true,
      clusterRead: true,
      service: {
        name: service.serviceName,
        runningCount: service.runningCount,
        desiredCount: service.desiredCount,
        pendingCount: service.pendingCount,
        taskDefinition: service.taskDefinition,
      },
      taskDefinitionRead: true,
      sensitiveValueScanPassed: true,
      writeDenied: ecsWriteDenied,
    },
    postgres: {
      package: "@modelcontextprotocol/server-postgres",
      packageVersion: "0.6.2",
      archivedPackage: true,
      server: postgres.getServerVersion(),
      queryToolLoaded: true,
      schemaColumns: columns.map((c) => ({
        name: c.column_name,
        type: c.data_type,
      })),
      identity,
      readOnlyTransactionDeniedWrite: postgresWriteDenied,
      databaseRoleDeniedTransactionEscape: transactionEscapeDenied,
      before,
      after,
      bootstrap,
    },
    serversInitialized: 2,
    serversClosed: false,
    qChatVerified: false,
    recordedAt: new Date().toISOString(),
  };
} catch (e) {
  proof = {
    status: "FAILED",
    error: safeCode(e),
    phase,
    elapsedMs: Math.round(performance.now() - started),
    recordedAt: new Date().toISOString(),
  };
  console.error(safeCode(e));
  process.exitCode = 1;
} finally {
  try {
    shutdown = await closeMcpSessions(sessions);
  } catch (e) {
    proof = {
      ...proof,
      status: "FAILED",
      error: safeCode(e),
      serversClosed: false,
    };
    shutdown = e.outcomes;
    console.error(safeCode(e));
    process.exitCode = 1;
  }
}
if (proof.status === "PASSED") proof.serversClosed = true;
proof.shutdown = {
  verification: "SDK client and stdio transport close promises completed",
  outcomes: shutdown,
};
await save(toolRoot + "/mcp-evidence.json", proof);
if (proof.status === "PASSED")
  console.log("MCP_BOTH_SERVERS_AND_REAL_DATABASE_ACCEPTED");
