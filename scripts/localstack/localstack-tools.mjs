import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, writeFile, rm, readFile } from "node:fs/promises";
import { tmpdir, homedir } from "node:os";
import path from "node:path";
import { randomUUID, createHash } from "node:crypto";
import http from "node:http";
import https from "node:https";
import tls from "node:tls";

const execute = promisify(execFile);
export class LocalOperationError extends Error {
  constructor(code) {
    super(
      /^[A-Z0-9_/]{1,160}$/.test(code) ? code : "INVALID_OPERATION_ERROR_CODE",
    );
    this.code = this.message;
  }
}
export function safeErrorCode(error) {
  if (error instanceof LocalOperationError) return error.code;
  if (error instanceof SyntaxError) return "INVALID_JSON";
  if (["ENOENT", "EACCES", "EEXIST", "ENOSPC", "EIO"].includes(error?.code))
    return "LOCAL_FILESYSTEM_FAILED/" + error.code;
  return "UNEXPECTED_LOCAL_ERROR";
}
export const runtimeRoot = () => path.join(homedir(), ".cloudtasks");
export async function docker(args) {
  try {
    return (
      await execute("docker", args, {
        timeout: 40000,
        maxBuffer: 4 * 1024 * 1024,
      })
    ).stdout;
  } catch (error) {
    const code = Number.isInteger(error.code)
      ? error.code
      : ["ENOENT", "EACCES", "E2BIG"].includes(error.code)
        ? error.code
        : "UNKNOWN";
    const provider = String(error.stderr ?? "").match(
      /An error occurred \(([A-Za-z0-9_.-]{1,64})\)/,
    )?.[1];
    throw new LocalOperationError(
      "LOCAL_DOCKER_COMMAND_FAILED/" +
        args[0].toUpperCase() +
        "/" +
        code +
        (provider ? "/" + provider.toUpperCase() : ""),
    );
  }
}
export async function aws(args, input) {
  let directory, containerFile;
  try {
    if (input !== undefined) {
      directory = await mkdtemp(path.join(tmpdir(), "cloudtasks-input-"));
      const file = path.join(directory, "input.json");
      await writeFile(file, JSON.stringify(input), { mode: 0o600 });
      containerFile = "/tmp/cloudtasks-input-" + randomUUID() + ".json";
      await docker(["cp", file, "cloudtasks-localstack:" + containerFile]);
      args = [...args, "--cli-input-json", "file://" + containerFile];
    }
    const raw = await docker([
      "exec",
      "-e",
      "AWS_ACCESS_KEY_ID=test",
      "-e",
      "AWS_SECRET_ACCESS_KEY=test",
      "-e",
      "AWS_DEFAULT_REGION=us-east-1",
      "-e",
      "AWS_ENDPOINT_URL=http://127.0.0.1:4566",
      "cloudtasks-localstack",
      "env",
      "-u",
      "AWS_PROFILE",
      "-u",
      "AWS_SESSION_TOKEN",
      "awslocal",
      "--endpoint-url",
      "http://127.0.0.1:4566",
      ...args,
      "--output",
      "json",
    ]);
    return raw.trim() ? JSON.parse(raw) : null;
  } finally {
    if (containerFile)
      await docker([
        "exec",
        "cloudtasks-localstack",
        "rm",
        "-f",
        containerFile,
      ]);
    if (directory) await rm(directory, { recursive: true, force: true });
  }
}
export async function checkedRuntime() {
  const [container] = JSON.parse(
    await docker(["inspect", "cloudtasks-localstack"]),
  );
  if (
    container?.Name !== "/cloudtasks-localstack" ||
    !container.State?.Running ||
    !container.NetworkSettings?.Ports?.["4566/tcp"]?.some(
      (x) => x.HostPort === "4566",
    )
  )
    throw new LocalOperationError("LOCALSTACK_GATEWAY_NOT_OWNED");
  const context = JSON.parse(
    (
      await readFile(path.join(runtimeRoot(), "ecs-runtime.json"), "utf8")
    ).replace(/^\uFEFF/, ""),
  );
  if (
    context.localStackContainerId !== container.Id &&
    context.LocalStackContainerId !== container.Id
  )
    throw new LocalOperationError("ECS_RUNTIME_OWNERSHIP_MISMATCH");
  const cluster = context.clusterName ?? context.ClusterName,
    service = context.serviceName ?? context.ServiceName;
  if (
    !/^cloudtasks-cluster(?:-r\d{17})?$/.test(cluster) ||
    service !== "cloudtasks-service"
  )
    throw new LocalOperationError("ECS_RUNTIME_NAMESPACE_MISMATCH");
  return { localStackContainerId: container.Id, cluster, service };
}
export async function gatewayPin() {
  return new Promise((resolve, reject) => {
    const socket = tls.connect({
      host: "127.0.0.1",
      port: 4566,
      servername: "localhost.localstack.cloud",
      rejectUnauthorized: false,
    });
    socket.setTimeout(8000, () =>
      socket.destroy(new LocalOperationError("TLS_BOOTSTRAP_TIMEOUT")),
    );
    socket.once("error", reject);
    socket.once("secureConnect", () => {
      const certificate = socket.getPeerCertificate();
      if (!certificate.raw) {
        socket.destroy();
        reject(new LocalOperationError("TLS_CERTIFICATE_MISSING"));
        return;
      }
      resolve(createHash("sha256").update(certificate.raw).digest("hex"));
      socket.end();
    });
  });
}
export async function requestLocal(
  address,
  { method = "GET", body, pin } = {},
) {
  const url = new URL(address);
  if (
    !["http:", "https:"].includes(url.protocol) ||
    url.port !== "4566" ||
    !/(?:^|\.)localhost\.localstack\.cloud$/.test(url.hostname) ||
    url.username ||
    url.password
  )
    throw new LocalOperationError("LOCAL_HTTP_ENDPOINT_REQUIRED");
  const secure = url.protocol === "https:";
  if (secure && !/^[a-f0-9]{64}$/.test(pin ?? ""))
    throw new LocalOperationError("TLS_PIN_REQUIRED");
  let agent;
  if (secure) {
    agent = new https.Agent();
    agent.createConnection = (options, done) => {
      let finished = false;
      const finish = (error, socket) => {
        if (!finished) {
          finished = true;
          done(error, socket);
        }
      };
      const socket = tls.connect({
        ...options,
        servername: url.hostname,
        rejectUnauthorized: false,
      });
      socket.once("error", (e) => finish(e));
      socket.once("secureConnect", () => {
        const cert = socket.getPeerCertificate();
        if (
          !cert.raw ||
          createHash("sha256").update(cert.raw).digest("hex") !== pin
        ) {
          socket.destroy();
          finish(new LocalOperationError("TLS_PIN_MISMATCH"));
          return;
        }
        finish(null, socket);
      });
    };
  }
  const payload = body === undefined ? undefined : JSON.stringify(body),
    headers = { "Cache-Control": "no-cache" };
  if (payload) {
    headers["Content-Type"] = "application/json";
    headers["Content-Length"] = Buffer.byteLength(payload);
  }
  try {
    return await new Promise((resolve, reject) => {
      let settled = false,
        timer;
      const finish = (e, r) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (e) reject(e);
        else resolve(r);
      };
      const req = (secure ? https : http).request(
        url,
        { method, headers, agent },
        (res) => {
          const chunks = [];
          let size = 0;
          res.on("data", (chunk) => {
            size += chunk.length;
            if (size > 2 * 1024 * 1024) {
              finish(new LocalOperationError("HTTP_BODY_LIMIT"));
              req.destroy();
            } else chunks.push(chunk);
          });
          res.once("aborted", () =>
            finish(new LocalOperationError("HTTP_TRANSPORT")),
          );
          res.once("error", () =>
            finish(new LocalOperationError("HTTP_TRANSPORT")),
          );
          res.once("close", () => {
            if (!res.complete)
              finish(new LocalOperationError("HTTP_TRANSPORT"));
          });
          res.once("end", () => {
            if (!res.complete)
              finish(new LocalOperationError("HTTP_TRANSPORT"));
            else
              finish(null, {
                status: res.statusCode,
                text: Buffer.concat(chunks).toString("utf8"),
                headers: res.headers,
              });
          });
        },
      );
      timer = setTimeout(() => {
        finish(new LocalOperationError("HTTP_TIMEOUT"));
        req.destroy();
      }, 10000);
      req.once("error", () =>
        finish(new LocalOperationError("HTTP_TRANSPORT")),
      );
      req.end(payload);
    });
  } finally {
    agent?.destroy();
  }
}
