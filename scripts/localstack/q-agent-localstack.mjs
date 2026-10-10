import { readFile, mkdir, writeFile } from "node:fs/promises";
import { spawn, execFile } from "node:child_process";
import { promisify, isDeepStrictEqual } from "node:util";
import { biaAgent } from "../mcp/mcp-config.mjs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  checkedRuntime,
  docker,
  runtimeRoot,
  LocalOperationError,
  safeErrorCode,
} from "./localstack-tools.mjs";
const execute = promisify(execFile),
  root = runtimeRoot(),
  qRoot = path.join(root, "amazon-q-cli"),
  projectRoot = path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "../..",
  );
const mode = process.argv[2],
  name = "cloudtasks-bia-agent";
async function run(args, interactive = false, tty = interactive) {
  const runtime = await checkedRuntime(),
    proof = JSON.parse(
      await readFile(path.join(qRoot, "preflight-evidence.json"), "utf8"),
    );
  if (
    proof.status !== "PASSED" ||
    proof.version !== "q 1.19.7" ||
    proof.localStackContainerId !== runtime.localStackContainerId ||
    !proof.externalDnsVerified
  )
    throw new LocalOperationError("Q_RUNTIME_NOT_VERIFIED");
  const [localStack] = JSON.parse(
    await docker(["inspect", "cloudtasks-localstack"]),
  );
  if (localStack.Image !== proof.runtimeImage)
    throw new LocalOperationError("Q_RUNTIME_IMAGE_CHANGED");
  if (
    (
      await docker([
        "ps",
        "--all",
        "--filter",
        "name=^/" + name + "$",
        "--format",
        "{{.ID}}",
      ])
    ).trim()
  )
    throw new LocalOperationError("Q_SESSION_ALREADY_RUNNING");
  await readFile(path.join(qRoot, "bin/q"));
  await readFile(path.join(qRoot, "bin/qchat"));
  const agent = JSON.parse(
    await readFile(
      path.join(projectRoot, ".amazonq/cli-agents/bia.json"),
      "utf8",
    ),
  );
  if (
    !isDeepStrictEqual(agent, biaAgent("host")) ||
    agent.name !== "bia" ||
    agent.useLegacyMcpJson !== false ||
    agent.tools?.length !== 2 ||
    !agent.tools.includes("@ecs/ecs_resource_management") ||
    !agent.tools.includes("@postgres/query")
  )
    throw new LocalOperationError("Q_AGENT_SCOPE_CHANGED");
  await mkdir(path.join(qRoot, "profile"), { recursive: true });
  const command = [
    "run",
    "--rm",
    ...(interactive ? [tty ? "-it" : "-i"] : []),
    "--name",
    name,
    "--label",
    "project=cloudtasks",
    "--label",
    "localstack=" + runtime.localStackContainerId,
    "--network",
    "cloudtasks-localstack-network",
    "--env",
    "PATH=/root/.local/bin:/usr/local/bin:/usr/bin:/bin",
    "--env",
    "AWS_CONFIG_FILE=/dev/null",
    "--env",
    "AWS_SHARED_CREDENTIALS_FILE=/dev/null",
    "--env",
    "AWS_EC2_METADATA_DISABLED=true",
    "--entrypoint",
    "/root/.local/bin/q",
    "--mount",
    "type=bind,source=" +
      path.join(qRoot, "bin") +
      ",target=/root/.local/bin,readonly",
    "--mount",
    "type=bind,source=" +
      path.join(qRoot, "profile") +
      ",target=/root/.local/share/amazon-q",
    "--mount",
    "type=bind,source=" +
      path.join(projectRoot, ".amazonq") +
      ",target=/work/.amazonq,readonly",
    "--mount",
    "type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock",
    "--workdir",
    "/work",
    proof.runtimeImage,
    ...args,
  ];
  if (interactive) {
    const child = spawn("docker", command, { stdio: "inherit" });
    const result = await new Promise((resolve, reject) => {
      child.once("error", () =>
        reject(new LocalOperationError("Q_COMMAND_SPAWN_FAILED")),
      );
      child.once("close", (exitCode, signal) => resolve({ exitCode, signal }));
    });
    if (result.exitCode !== 0 || result.signal)
      throw new LocalOperationError("Q_INTERACTIVE_COMMAND_FAILED");
    return { exitCode: 0 };
  }
  return await execute("docker", command, {
    timeout: 120000,
    maxBuffer: 1024 * 1024,
  })
    .then((r) => ({ exitCode: 0, stdout: r.stdout, stderr: r.stderr }))
    .catch((e) => ({
      exitCode: e.code,
      stdout: e.stdout ?? "",
      stderr: e.stderr ?? "",
    }));
}
try {
  if (mode === "validate") {
    const result = await run([
      "agent",
      "validate",
      "/work/.amazonq/cli-agents/bia.json",
    ]);
    if (result.exitCode !== 0)
      throw new LocalOperationError(
        /not.logged.in|please log in/i.test(result.stdout + result.stderr)
          ? "Q_AUTHENTICATION_REQUIRED"
          : "Q_AGENT_CONFIG_REJECTED",
      );
    const list = await run(["agent", "list"]);
    if (list.exitCode !== 0 || !list.stdout.includes("bia"))
      throw new LocalOperationError("Q_BIA_AGENT_NOT_DISCOVERED");
    const evidence = {
      schemaVersion: 1,
      status: "PASSED",
      version: "q 1.19.7",
      agentName: "bia",
      agentValidated: true,
      agentDiscovered: true,
      mcpServersConfigured: 2,
      qChatVerified: false,
      recordedAt: new Date().toISOString(),
    };
    await writeFile(
      path.join(root, "q-agent-evidence.json"),
      JSON.stringify(evidence, null, 2) + "\n",
    );
    console.log("Q_BIA_AGENT_VALIDATED_AND_DISCOVERED");
  } else if (mode === "status") {
    const result = await run(["whoami"]);
    if (
      result.exitCode !== 0 &&
      !/not.logged.in|login|log in|authenticate/i.test(
        result.stdout + result.stderr,
      )
    )
      throw new LocalOperationError("Q_AUTH_STATUS_UNDETERMINED");
    const authenticated =
      result.exitCode === 0 &&
      !/not.logged.in|login|log in|authenticate/i.test(
        result.stdout + result.stderr,
      );
    console.log(
      JSON.stringify({
        version: "q 1.19.7",
        agent: "bia",
        authenticated,
        qChatVerified: false,
      }),
    );
  } else if (mode === "login")
    await run(["login", "--license", "free", "--use-device-flow"], true, false);
  else if (mode === "chat") await run(["chat", "--agent", "bia"], true);
  else throw new LocalOperationError("Q_MODE_INVALID");
} catch (e) {
  if (e.code === "Q_AUTHENTICATION_REQUIRED")
    await writeFile(
      path.join(root, "q-agent-evidence.json"),
      JSON.stringify(
        {
          schemaVersion: 1,
          status: "BLOCKED",
          error: e.code,
          version: "q 1.19.7",
          agentName: "bia",
          agentValidated: false,
          agentDiscovered: false,
          mcpServersConfigured: 2,
          qChatVerified: false,
          recordedAt: new Date().toISOString(),
        },
        null,
        2,
      ) + "\n",
      { mode: 0o600 },
    );
  console.error("Q_LOCAL_FAILED=" + safeErrorCode(e));
  process.exitCode = 1;
}
