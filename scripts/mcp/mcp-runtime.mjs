import { spawn } from "node:child_process";
import { readFile, writeFile, rename, unlink } from "node:fs/promises";
import { createRequire } from "node:module";
import { randomUUID } from "node:crypto";
import { withAwsJsonInput } from "./mcp-aws-input.mjs";
import {
  toolRoot,
  mcpEnvironment,
  checkedMcpRuntime,
  checkedDatabase,
} from "./mcp-config.mjs";
export const packageRequire = createRequire(toolRoot + "/node/package.json");
export async function runtime() {
  return checkedMcpRuntime(
    JSON.parse(await readFile(toolRoot + "/runtime.json", "utf8")),
  );
}
export async function save(file, value) {
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
export async function localAws(args, input) {
  return await withAwsJsonInput(
    input,
    async (inputArgs) =>
      await new Promise((resolve, reject) => {
        let stdout = "",
          stderr = "",
          settled = false;
        const child = spawn(
          "awslocal",
          [
            "--endpoint-url",
            "http://127.0.0.1:4566",
            ...args,
            ...inputArgs,
            "--output",
            "json",
          ],
          { env: mcpEnvironment(), stdio: ["ignore", "pipe", "pipe"] },
        );
        const timer = setTimeout(() => {
          child.kill("SIGTERM");
          finish(Error("MCP_AWS_TIMEOUT"));
        }, 30000);
        function finish(error, value) {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          if (error) reject(error);
          else resolve(value);
        }
        child.once("error", () => finish(Error("MCP_AWS_SPAWN_FAILED")));
        child.stdout.on("data", (b) => {
          stdout += b.toString();
          if (stdout.length > 4 * 1024 * 1024) {
            child.kill("SIGTERM");
            finish(Error("MCP_AWS_RESPONSE_TOO_LARGE"));
          }
        });
        child.stderr.on("data", (b) => {
          if (stderr.length < 65536) stderr += b.toString();
        });
        child.once("close", (code, signal) => {
          if (code !== 0 || signal) {
            const provider = stderr.match(
              /An error occurred \(([A-Za-z0-9_.-]{1,64})\)/,
            )?.[1];
            finish(Error("MCP_AWS_FAILED" + (provider ? "/" + provider : "")));
          } else
            try {
              finish(null, stdout.trim() ? JSON.parse(stdout) : null);
            } catch {
              finish(Error("MCP_AWS_JSON_INVALID"));
            }
        });
      }),
  );
}
export async function database(name, context) {
  const response = await localAws([
    "secretsmanager",
    "get-secret-value",
    "--secret-id",
    name,
  ]);
  let value;
  try {
    value = JSON.parse(response.SecretString);
  } catch {
    throw Error("MCP_SECRET_JSON_INVALID");
  }
  const instances = await localAws([
    "rds",
    "describe-db-instances",
    "--db-instance-identifier",
    context.dbIdentifier,
  ]);
  if (instances.DBInstances?.length !== 1)
    throw Error("MCP_RDS_INSTANCE_AMBIGUOUS");
  return {
    value,
    connection: checkedDatabase(value, context, instances.DBInstances[0]),
  };
}
export function safeCode(error) {
  return /^MCP_[A-Z0-9_]+(?:\/[A-Za-z0-9_.-]+)?$/.test(error?.message ?? "")
    ? error.message
    : "MCP_UNEXPECTED_ERROR";
}
