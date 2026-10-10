import test from "node:test";
import assert from "node:assert/strict";
import { closeMcpSessions } from "../mcp/mcp-session-lifecycle.mjs";
import { withAwsJsonInput } from "../mcp/mcp-aws-input.mjs";
import { readFile, stat } from "node:fs/promises";
import path from "node:path";
import {
  mcpEnvironment,
  checkedMcpRuntime,
  checkedDatabase,
  biaAgent,
  toolRoot,
} from "../mcp/mcp-config.mjs";
const runtime = {
  localStackContainerId: "a".repeat(64),
  cluster: "cloudtasks-cluster-r20261008153148448",
  service: "cloudtasks-service",
  dbIdentifier: "cloudtasks-postgres-r20261008152558596",
};
const database = {
  username: "cloudtasks_admin",
  password: "private-canary",
  host: "cloudtasks-postgres-r20261008152558596.example.rds.localhost.localstack.cloud",
  port: 4510,
  dbname: "cloudtasks",
  dbInstanceIdentifier: runtime.dbIdentifier,
};
const instance = {
  DBInstanceIdentifier: runtime.dbIdentifier,
  DBInstanceStatus: "available",
  Endpoint: { Address: database.host, Port: database.port },
};
test("MCP dependencies use the container filesystem instead of the Windows LocalStack bind mount", () => {
  assert.equal(toolRoot, "/opt/cloudtasks-mcp-tools");
});
test("MCP child receives only local endpoints, fake AWS keys and read-only flags", () => {
  const env = mcpEnvironment({
    PATH: "/bin",
    HOME: "/root",
    AWS_PROFILE: "paid",
    AWS_SECRET_ACCESS_KEY: "private-canary",
    LOCALSTACK_AUTH_TOKEN: "private-canary",
    ALLOW_WRITE: "true",
    AWS_ENDPOINT_URL: "https://ecs.us-east-1.amazonaws.com",
  });
  assert.equal(env.AWS_ENDPOINT_URL, "http://127.0.0.1:4566");
  assert.equal(env.AWS_SECRET_ACCESS_KEY, "test");
  assert.equal(env.ALLOW_WRITE, "false");
  assert.equal(env.ALLOW_SENSITIVE_DATA, "false");
  assert.equal(env.AWS_EC2_METADATA_DISABLED, "true");
  assert.equal(env.AWS_CONFIG_FILE, "/dev/null");
  assert.ok(!JSON.stringify(env).includes("private-canary"));
  assert.equal(env.AWS_PROFILE, undefined);
});
test("AWS JSON file transport roundtrips quotes and removes the private file after a rejected operation", async () => {
  let file;
  const input = { SecretString: 'private-canary "quote"\nline' };
  await assert.rejects(
    withAwsJsonInput(input, async (args) => {
      assert.equal(args[0], "--cli-input-json");
      file = args[1].slice("file://".length);
      assert.deepEqual(JSON.parse(await readFile(file, "utf8")), input);
      if (process.platform !== "win32") {
        assert.equal((await stat(file)).mode & 0o777, 0o600);
        assert.equal((await stat(path.dirname(file))).mode & 0o777, 0o700);
      }
      throw Error("controlled-operation-failure");
    }),
    /controlled-operation-failure/,
  );
  await assert.rejects(stat(file), { code: "ENOENT" });
  await assert.rejects(stat(path.dirname(file)), { code: "ENOENT" });
});
test("failed MCP shutdown remains rejected and still closes every owned transport", async () => {
  const called = [];
  const session = (name, fail) => ({
    name,
    client: {
      async close() {
        called.push(name + "-client");
        if (fail) throw Error("private-canary");
      },
    },
    transport: {
      async close() {
        called.push(name + "-transport");
      },
    },
  });
  await assert.rejects(
    closeMcpSessions([session("ecs", false), session("postgres", true)]),
    (e) => {
      assert.equal(e.message, "MCP_SESSION_CLOSE_FAILED");
      assert.ok(!JSON.stringify(e.outcomes).includes("private-canary"));
      assert.equal(e.outcomes[0].clientClosed, false);
      assert.equal(e.outcomes[0].transportClosed, true);
      return true;
    },
  );
  assert.deepEqual(called, [
    "postgres-client",
    "postgres-transport",
    "ecs-client",
    "ecs-transport",
  ]);
});
test("MCP runtime rejects foreign cluster, database, service and container IDs", () => {
  assert.deepEqual(
    checkedMcpRuntime({ ...runtime, password: "private-canary" }),
    runtime,
  );
  for (const change of [
    { cluster: "production" },
    { service: "foreign" },
    { dbIdentifier: "production" },
    { localStackContainerId: "short" },
  ])
    assert.throws(() => checkedMcpRuntime({ ...runtime, ...change }));
});
test("PostgreSQL connection remains bound to the owned local RDS runtime", () => {
  assert.equal(
    checkedDatabase(database, runtime, instance).dbname,
    "cloudtasks",
  );
  for (const change of [
    { host: "production.rds.amazonaws.com" },
    { dbname: "foreign" },
    { dbInstanceIdentifier: "cloudtasks-postgres" },
    { port: NaN },
    { password: "" },
  ])
    assert.throws(() =>
      checkedDatabase({ ...database, ...change }, runtime, instance),
    );
});
test("generic LocalStack RDS hostname is accepted only with matching current owned API endpoint", () => {
  const local = { ...database, host: "localhost.localstack.cloud" };
  const current = {
    ...instance,
    Endpoint: { Address: local.host, Port: local.port },
  };
  assert.equal(checkedDatabase(local, runtime, current).host, local.host);
  for (const changed of [
    { DBInstanceIdentifier: "foreign" },
    { DBInstanceStatus: "creating" },
    {
      Endpoint: {
        Address: "foreign.localhost.localstack.cloud",
        Port: local.port,
      },
    },
    { Endpoint: { Address: local.host, Port: 4511 } },
  ])
    assert.throws(() =>
      checkedDatabase(local, runtime, { ...current, ...changed }),
    );
  assert.throws(() => checkedDatabase(local, runtime));
});
test("bia agent exposes only real MCP read tools and no built-in shell or hidden legacy servers", () => {
  const agent = biaAgent("container");
  assert.equal(agent.name, "bia");
  assert.equal(agent.useLegacyMcpJson, false);
  assert.deepEqual(agent.tools, [
    "@ecs/ecs_resource_management",
    "@postgres/query",
  ]);
  assert.deepEqual(agent.allowedTools, agent.tools);
  assert.equal(Object.keys(agent.mcpServers).length, 2);
  assert.ok(!JSON.stringify(agent).includes("private-canary"));
  assert.equal(biaAgent("host").mcpServers.ecs.command, "docker");
});
