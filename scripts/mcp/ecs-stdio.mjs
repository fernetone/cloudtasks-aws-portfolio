import { spawn } from "node:child_process";
import { toolRoot, mcpEnvironment } from "./mcp-config.mjs";
import { runtime, safeCode } from "./mcp-runtime.mjs";
try {
  await runtime();
  const child = spawn(toolRoot + "/bin/ecs-mcp-server", [], {
    env: mcpEnvironment(),
    stdio: "inherit",
  });
  child.once("error", () => {
    console.error("MCP_ECS_SPAWN_FAILED");
    process.exitCode = 1;
  });
  child.once("close", (code, signal) => {
    process.exitCode = signal ? 1 : (code ?? 1);
  });
  process.once("SIGTERM", () => child.kill("SIGTERM"));
  process.once("SIGINT", () => child.kill("SIGINT"));
} catch (e) {
  console.error(safeCode(e));
  process.exitCode = 1;
}
