import { writeFile, mkdir, mkdtemp, rm, rename, stat } from "node:fs/promises";
import { createReadStream, createWriteStream } from "node:fs";
import { createHash, randomUUID } from "node:crypto";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import {
  checkedRuntime,
  docker,
  runtimeRoot,
  LocalOperationError,
  safeErrorCode,
} from "./localstack-tools.mjs";
const execute = promisify(execFile),
  root = path.join(runtimeRoot(), "amazon-q-cli"),
  url =
    "https://desktop-release.q.us-east-1.amazonaws.com/1.19.7/q-x86_64-linux.zip",
  expectedArchive =
    "b935501672c0dfa3b44024d127248e25d6546863182c18eb17188f6dd22e97f6";
const hash = async (file) => {
  const digest = createHash("sha256");
  for await (const data of createReadStream(file)) digest.update(data);
  return digest.digest("hex");
};
let temporary;
try {
  if (process.platform !== "win32")
    throw new LocalOperationError("Q_INSTALL_REQUIRES_WINDOWS_HOST");
  const runtime = await checkedRuntime();
  await mkdir(root, { recursive: true });
  const archive = path.join(root, "amazon-q-1.19.7.zip");
  try {
    await stat(archive);
  } catch (e) {
    if (e.code !== "ENOENT") throw e;
    const partial = archive + "." + randomUUID() + ".partial";
    try {
      const response = await fetch(url, {
        signal: AbortSignal.timeout(180000),
      });
      if (
        response.status !== 200 ||
        new URL(response.url).hostname !==
          "desktop-release.q.us-east-1.amazonaws.com"
      )
        throw new LocalOperationError("Q_OFFICIAL_DOWNLOAD_REJECTED");
      await pipeline(
        Readable.fromWeb(response.body),
        createWriteStream(partial, { flags: "wx", mode: 0o600 }),
      );
      if ((await hash(partial)) !== expectedArchive)
        throw new LocalOperationError("Q_ARCHIVE_HASH_MISMATCH");
      await rename(partial, archive);
    } finally {
      await rm(partial, { force: true });
    }
  }
  if ((await hash(archive)) !== expectedArchive)
    throw new LocalOperationError("Q_ARCHIVE_HASH_MISMATCH");
  temporary = await mkdtemp(path.join(root, "extract-"));
  const extractor = path.join(temporary, "extract.ps1");
  await writeFile(
    extractor,
    `param([string]$ZipPath,[string]$Target)\n$ErrorActionPreference='Stop'\nAdd-Type -AssemblyName System.IO.Compression\nAdd-Type -AssemblyName System.IO.Compression.FileSystem\n$zip=[IO.Compression.ZipFile]::OpenRead($ZipPath)\ntry{foreach($name in @('q','qchat')){$entry=$zip.GetEntry('q/bin/'+$name);if($null -eq $entry){throw 'Q_ENTRY_MISSING'};$source=$entry.Open();$dest=[IO.File]::Open((Join-Path $Target $name),[IO.FileMode]::CreateNew);try{$source.CopyTo($dest)}finally{$dest.Dispose();$source.Dispose()}}}finally{$zip.Dispose()}\n`,
  );
  await execute(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      extractor,
      "-ZipPath",
      archive,
      "-Target",
      temporary,
    ],
    { timeout: 180000, maxBuffer: 65536 },
  );
  await mkdir(path.join(root, "bin"), { recursive: true });
  const binaries = [];
  for (const name of ["q", "qchat"]) {
    const extracted = path.join(temporary, name),
      destination = path.join(root, "bin", name),
      sha256 = await hash(extracted);
    try {
      await stat(destination);
      if ((await hash(destination)) !== sha256)
        throw new LocalOperationError("Q_INSTALLED_BINARY_CHANGED");
    } catch (e) {
      if (e.code !== "ENOENT") throw e;
      await rename(extracted, destination);
    }
    binaries.push({ name, sha256 });
  }
  const [localStack] = JSON.parse(
    await docker(["inspect", "cloudtasks-localstack"]),
  );
  const [image] = JSON.parse(
    await docker(["image", "inspect", localStack.Image]),
  );
  if (
    (image.Config.Env ?? []).some(
      (e) =>
        /^LOCALSTACK_AUTH_TOKEN=|^AWS_SESSION_TOKEN=/.test(e) ||
        (/^AWS_SECRET_ACCESS_KEY=/.test(e) &&
          e !== "AWS_SECRET_ACCESS_KEY=test"),
    )
  )
    throw new LocalOperationError("Q_BASE_IMAGE_CONTAINS_CREDENTIAL_ENV");
  const args = [
    "run",
    "--rm",
    "--name",
    "cloudtasks-q-install-" + randomUUID().slice(0, 8),
    "--network",
    "cloudtasks-localstack-network",
    "--env",
    "PATH=/root/.local/bin:/usr/local/bin:/usr/bin:/bin",
    "--entrypoint",
    "/root/.local/bin/q",
    "--mount",
    "type=bind,source=" +
      path.join(root, "bin") +
      ",target=/root/.local/bin,readonly",
    localStack.Image,
    "--version",
  ];
  const version = (
    await execute("docker", args, { timeout: 60000, maxBuffer: 65536 })
  ).stdout.trim();
  if (version !== "q 1.19.7")
    throw new LocalOperationError("Q_VERSION_NOT_PINNED");
  const dns = JSON.parse(
    (
      await execute(
        "docker",
        [
          "run",
          "--rm",
          "--name",
          "cloudtasks-q-dns-" + randomUUID().slice(0, 8),
          "--network",
          "cloudtasks-localstack-network",
          "--entrypoint",
          "python",
          localStack.Image,
          "-c",
          "import socket,json;print(json.dumps({'addresses':sorted(set(r[4][0] for r in socket.getaddrinfo('desktop-release.q.us-east-1.amazonaws.com',443)))}))",
        ],
        { timeout: 30000, maxBuffer: 65536 },
      )
    ).stdout,
  );
  const internal = Object.values(localStack.NetworkSettings.Networks).map(
    (n) => n.IPAddress,
  );
  if (
    !dns.addresses.length ||
    dns.addresses.some((ip) => ip === "127.0.0.1" || internal.includes(ip))
  )
    throw new LocalOperationError("Q_EXTERNAL_DNS_NOT_VERIFIED");
  const proof = {
    schemaVersion: 1,
    status: "PASSED",
    version,
    ...runtime,
    runtimeImage: localStack.Image,
    downloadURL: url,
    archiveSha256: expectedArchive,
    archiveIntegrityVerified: true,
    binaries,
    externalDnsVerified: true,
    dns,
    qChatVerified: false,
    recordedAt: new Date().toISOString(),
  };
  await writeFile(
    path.join(root, "preflight-evidence.json"),
    JSON.stringify(proof, null, 2) + "\n",
  );
  console.log("Q_1_19_7_BINARIES_INTEGRITY_AND_EXTERNAL_DNS_ACCEPTED");
} catch (e) {
  console.error("Q_INSTALL_FAILED=" + safeErrorCode(e));
  process.exitCode = 1;
} finally {
  if (temporary) await rm(temporary, { recursive: true, force: true });
}
