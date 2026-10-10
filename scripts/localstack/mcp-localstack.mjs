import { readFile, writeFile, rename, unlink, mkdir } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { randomUUID } from "node:crypto";
import {
  checkedRuntime,
  docker,
  runtimeRoot,
  LocalOperationError,
  safeErrorCode,
} from "./localstack-tools.mjs";
import { toolRoot, checkedMcpRuntime, biaAgent } from "../mcp/mcp-config.mjs";
const execute = promisify(execFile),
  projectRoot = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "../..",
  ),
  root = runtimeRoot(),
  metadataFile = path.join(root, "mcp-runtime.json"),
  evidenceFile = path.join(root, "mcp-evidence.json");
const files = [
  "package.json",
  "package-lock.json",
  "mcp-config.mjs",
  "mcp-runtime.mjs",
  "mcp-aws-input.mjs",
  "mcp-session-lifecycle.mjs",
  "bootstrap-postgres.mjs",
  "postgres-stdio.mjs",
  "ecs-stdio.mjs",
  "verify-mcp.mjs",
];
const mode = process.argv[2];
async function saved(file, value) {
  const temporary = file + "." + randomUUID() + ".tmp";
  try {
    await writeFile(temporary, JSON.stringify(value, null, 2) + "\n", {
      mode: 0o600,
      flag: "wx",
    });
    await rename(temporary, file);
  } finally {
    await unlink(temporary).catch((e) => {
      if (e.code !== "ENOENT") throw e;
    });
  }
}
async function context() {
  const ecs = await checkedRuntime();
  const rds = JSON.parse(
    (await readFile(path.join(root, "rds-runtime.json"), "utf8")).replace(
      /^\uFEFF/,
      "",
    ),
  );
  return checkedMcpRuntime({ ...ecs, dbIdentifier: rds.dbIdentifier });
}
async function command(args) {
  try {
    return (
      await execute("docker", args, {
        timeout: 300000,
        maxBuffer: 8 * 1024 * 1024,
      })
    ).stdout;
  } catch (error) {
    const reason = String(error.stderr ?? "").match(
      /(?:^|\n)(MCP_[A-Z0-9_]+(?:\/[A-Za-z0-9_.-]+)?)(?:\r?\n|$)/,
    )?.[1];
    throw new LocalOperationError(
      "MCP_LOCAL_COMMAND_FAILED/" +
        args[0].toUpperCase() +
        (reason ? "/" + reason.toUpperCase() : ""),
    );
  }
}
async function copyJSON(value, destination) {
  const temporary = path.join(root, "mcp-input-" + randomUUID() + ".json");
  try {
    await saved(temporary, value);
    await docker(["cp", temporary, "cloudtasks-localstack:" + destination]);
  } finally {
    await unlink(temporary).catch((e) => {
      if (e.code !== "ENOENT") throw e;
    });
  }
}
async function metadata(current) {
  const meta = JSON.parse(await readFile(metadataFile, "utf8"));
  if (JSON.stringify(meta.runtime) !== JSON.stringify(current))
    throw new LocalOperationError("MCP_RUNTIME_OWNERSHIP_MISMATCH");
  return meta;
}
try {
  if (!["create", "status", "test"].includes(mode))
    throw new LocalOperationError("MCP_MODE_INVALID");
  const current = await context();
  if (mode === "create") {
    try {
      await metadata(current);
    } catch (e) {
      if (e.code !== "ENOENT") throw e;
    }
    for (const f of files)
      await readFile(path.join(projectRoot, "scripts/mcp", f));
    await command([
      "exec",
      "cloudtasks-localstack",
      "mkdir",
      "-p",
      toolRoot + "/node",
      toolRoot + "/project/scripts/mcp",
      toolRoot + "/project/.amazonq/cli-agents",
    ]);
    for (const f of files)
      await docker([
        "cp",
        path.join(projectRoot, "scripts/mcp", f),
        "cloudtasks-localstack:" + toolRoot + "/project/scripts/mcp/" + f,
      ]);
    for (const f of ["package.json", "package-lock.json"])
      await docker([
        "cp",
        path.join(projectRoot, "scripts/mcp", f),
        "cloudtasks-localstack:" + toolRoot + "/node/" + f,
      ]);
    await copyJSON(current, toolRoot + "/runtime.json");
    await copyJSON(
      biaAgent("container"),
      toolRoot + "/project/.amazonq/cli-agents/bia.json",
    );
    await command([
      "exec",
      "-e",
      "UV_TOOL_DIR=" + toolRoot + "/python",
      "-e",
      "UV_TOOL_BIN_DIR=" + toolRoot + "/bin",
      "cloudtasks-localstack",
      "uv",
      "tool",
      "install",
      "awslabs.ecs-mcp-server==0.1.36",
      "--with",
      "fastmcp==3.4.8",
      "--with",
      "mcp==1.30.0",
    ]);
    await command([
      "exec",
      "-w",
      toolRoot + "/node",
      "cloudtasks-localstack",
      "npm",
      "ci",
      "--ignore-scripts",
      "--omit=dev",
    ]);
    await command([
      "exec",
      "cloudtasks-localstack",
      "node",
      toolRoot + "/project/scripts/mcp/bootstrap-postgres.mjs",
    ]);
    await saved(metadataFile, {
      schemaVersion: 1,
      runtime: current,
      toolsRoot: toolRoot,
      agentName: "bia",
      serverCount: 2,
      qChatVerified: false,
      recordedAt: new Date().toISOString(),
    });
    console.log("MCP_SERVERS_AND_BIA_AGENT_CONFIGURED");
  } else {
    await metadata(current);
    if (mode === "test") {
      await command([
        "exec",
        "cloudtasks-localstack",
        "node",
        toolRoot + "/project/scripts/mcp/verify-mcp.mjs",
      ]);
      const proof = JSON.parse(
        await docker([
          "exec",
          "cloudtasks-localstack",
          "cat",
          toolRoot + "/mcp-evidence.json",
        ]),
      );
      if (
        proof.status !== "PASSED" ||
        JSON.stringify(checkedMcpRuntime(proof)) !== JSON.stringify(current)
      )
        throw new LocalOperationError("MCP_EVIDENCE_INVALID");
      await saved(evidenceFile, proof);
      console.log("MCP_ECS_POSTGRES_REAL_PROTOCOL_ACCEPTED");
    } else {
      const proof = JSON.parse(await readFile(evidenceFile, "utf8"));
      if (JSON.stringify(checkedMcpRuntime(proof)) !== JSON.stringify(current))
        throw new LocalOperationError("MCP_EVIDENCE_RUNTIME_MISMATCH");
      console.log(
        JSON.stringify({
          runtime: current,
          recordedStatus: proof.status,
          serversInitialized: proof.serversInitialized,
          qChatVerified: proof.qChatVerified,
          recordedAt: proof.recordedAt,
        }),
      );
    }
  }
} catch (e) {
  await mkdir(root, { recursive: true });
  const code = /^MCP_[A-Z0-9_/]{1,160}$/.test(e.message ?? "")
    ? e.message
    : safeErrorCode(e);
  console.error("MCP_LOCAL_FAILED=" + code);
  process.exitCode = 1;
}
