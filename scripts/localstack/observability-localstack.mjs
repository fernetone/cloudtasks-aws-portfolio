import { readFile, writeFile, open, unlink, rename } from "node:fs/promises";
import { openSync, closeSync } from "node:fs";
import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import { fileURLToPath } from "node:url";
import http from "node:http";
import { randomUUID } from "node:crypto";
import {
  aws,
  docker,
  checkedRuntime,
  gatewayPin,
  requestLocal,
  runtimeRoot,
  LocalOperationError,
  safeErrorCode,
} from "./localstack-tools.mjs";
import {
  namespace,
  dimensions,
  metricData,
  productionAlarms,
  probeMeasurement,
  dashboardBody,
} from "./observability-config.mjs";

const requireValue = (v, c) => {
  if (!v) throw new LocalOperationError(c);
};
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const root = runtimeRoot(),
  metadataFile = path.join(root, "observability-runtime.json"),
  pidFile = path.join(root, "observability-monitor.pid.json"),
  heartbeatFile = path.join(root, "observability-heartbeat.json"),
  evidenceFile = path.join(root, "observability-evidence.json");
const moduleFile = fileURLToPath(import.meta.url),
  execute = promisify(execFile);
const mode = process.argv[2],
  logGroup = "/cloudtasks/observability";
async function jsonFile(file) {
  return JSON.parse((await readFile(file, "utf8")).replace(/^\uFEFF/, ""));
}
async function saved(file, value) {
  const temporary = file + "." + randomUUID() + ".tmp";
  try {
    await writeFile(temporary, JSON.stringify(value, null, 2) + "\n", {
      flag: "wx",
      mode: 0o600,
    });
    await rename(temporary, file);
  } finally {
    await unlink(temporary).catch((e) => {
      if (e.code !== "ENOENT") throw e;
    });
  }
}
async function optional(file) {
  try {
    return await jsonFile(file);
  } catch (e) {
    if (e.code === "ENOENT") return null;
    throw e;
  }
}
async function collect(runtime) {
  const arns =
    (
      await aws([
        "ecs",
        "list-tasks",
        "--cluster",
        runtime.cluster,
        "--service-name",
        runtime.service,
        "--desired-status",
        "RUNNING",
      ])
    ).taskArns ?? [];
  const tasks = [];
  for (const arn of arns) {
    const id = arn.split("/").at(-1);
    requireValue(/^[a-f0-9-]{36}$/.test(id), "OBSERVABILITY_TASK_ID_INVALID");
    const prefix = "ls-ecs-" + runtime.cluster + "-" + id + "-";
    const rows = (
      await docker([
        "ps",
        "--all",
        "--no-trunc",
        "--filter",
        "name=" + prefix,
        "--format",
        "{{json .}}",
      ])
    )
      .trim()
      .split("\n")
      .filter(Boolean)
      .map(JSON.parse)
      .filter((x) => x.Names.startsWith(prefix));
    requireValue(rows.length === 1, "OBSERVABILITY_PHYSICAL_TASK_AMBIGUOUS");
    const [physical] = JSON.parse(await docker(["inspect", rows[0].ID]));
    const ip =
      physical.NetworkSettings.Networks?.["cloudtasks-localstack-network"]
        ?.IPAddress;
    tasks.push({
      taskArn: arn,
      containerId: physical.Id,
      ip,
      running: physical.State.Running === true,
      healthy:
        physical.State.Running === true &&
        physical.State.Health?.Status === "healthy",
    });
  }
  const group = (
    await aws(["elbv2", "describe-target-groups", "--names", "cloudtasks-tg"])
  ).TargetGroups?.[0];
  requireValue(group?.TargetGroupArn, "OBSERVABILITY_TARGET_GROUP_MISSING");
  const targets =
    (
      await aws([
        "elbv2",
        "describe-target-health",
        "--target-group-arn",
        group.TargetGroupArn,
      ])
    ).TargetHealthDescriptions ?? [];
  const verified = new Set(
    targets
      .filter(
        (t) =>
          t.TargetHealth.State === "healthy" &&
          t.Target.Port === 3000 &&
          tasks.some((x) => x.running && x.healthy && x.ip === t.Target.Id),
      )
      .map((t) => t.Target.Id),
  );
  const probe = await probeMeasurement(async () =>
    requestLocal(
      "https://cloudtasks-alb.elb.localhost.localstack.cloud:4566/health",
      { pin: await gatewayPin() },
    ),
  );
  return {
    scope:
      "observed Docker tasks, ALB targets and real database-aware HTTP health",
    sampleId: randomUUID(),
    ...runtime,
    physicalRunning: tasks.filter((t) => t.running).length,
    verifiedHealthy: verified.size,
    probeUp: probe.up,
    probeLatencyMs: probe.latencyMs,
    ...(probe.error ? { probeError: probe.error } : {}),
    tasks,
    time: new Date().toISOString(),
  };
}
async function publish(sample, stream) {
  await aws(["cloudwatch", "put-metric-data"], {
    Namespace: namespace,
    MetricData: metricData(sample),
  });
  await aws(["logs", "put-log-events"], {
    logGroupName: logGroup,
    logStreamName: stream,
    logEvents: [
      {
        timestamp: Date.now(),
        message: JSON.stringify({
          sampleId: sample.sampleId,
          service: sample.service,
          physicalRunning: sample.physicalRunning,
          verifiedHealthy: sample.verifiedHealthy,
          probeUp: sample.probeUp,
          probeLatencyMs: sample.probeLatencyMs,
          time: sample.time,
        }),
      },
    ],
  });
}
async function monitorIdentity(pid) {
  if (!Number.isInteger(pid) || pid < 1) return false;
  try {
    process.kill(pid, 0);
  } catch {
    return false;
  }
  if (process.platform === "win32") {
    const cmd =
      '$p=Get-CimInstance Win32_Process -Filter "ProcessId=' +
      pid +
      '"; if ($null -ne $p) { $p.CommandLine }';
    const { stdout } = await execute(
      "powershell.exe",
      ["-NoProfile", "-Command", cmd],
      { timeout: 10000, maxBuffer: 32768 },
    );
    return stdout.includes(moduleFile) && stdout.includes("monitor");
  }
  try {
    const cmd = await readFile("/proc/" + pid + "/cmdline", "utf8");
    return cmd.includes(moduleFile) && cmd.split("\0").includes("monitor");
  } catch {
    return false;
  }
}
async function startMonitor(runtime) {
  const old = await optional(pidFile);
  if (old) {
    if (await monitorIdentity(old.pid)) {
      requireValue(
        old.localStackContainerId === runtime.localStackContainerId,
        "MONITOR_RUNTIME_MISMATCH",
      );
      return old.pid;
    }
    try {
      process.kill(old.pid, 0);
      throw new LocalOperationError("MONITOR_PID_BELONGS_TO_ANOTHER_PROCESS");
    } catch (e) {
      if (e instanceof LocalOperationError) throw e;
      if (e.code !== "ESRCH") throw e;
    }
    await saved(pidFile + ".stale-" + Date.now(), old);
    await unlink(pidFile);
  }
  const out = openSync(path.join(root, "observability-monitor.out.log"), "a"),
    err = openSync(
      path.join(root, "observability-monitor.private.err.log"),
      "a",
    );
  const child = spawn(process.execPath, [moduleFile, "monitor"], {
    detached: true,
    windowsHide: true,
    stdio: ["ignore", out, err],
  });
  closeSync(out);
  closeSync(err);
  await new Promise((resolve, reject) => {
    child.once("spawn", resolve);
    child.once("error", () =>
      reject(new LocalOperationError("MONITOR_SPAWN_FAILED")),
    );
  });
  child.unref();
  for (let i = 0; i < 40; i++) {
    let lock;
    try {
      lock = await optional(pidFile);
    } catch (e) {
      if (!(e instanceof SyntaxError)) throw e;
    }
    const beat = await optional(heartbeatFile);
    if (lock?.pid === child.pid && beat?.pid === child.pid) return child.pid;
    await delay(500);
  }
  throw new LocalOperationError("MONITOR_STARTUP_NOT_VERIFIED");
}
async function configured(runtime) {
  const meta = await jsonFile(metadataFile);
  requireValue(
    meta.localStackContainerId === runtime.localStackContainerId &&
      meta.service === runtime.service,
    "OBSERVABILITY_RUNTIME_OWNERSHIP_MISMATCH",
  );
  return meta;
}
async function configure(runtime) {
  let meta = await optional(metadataFile);
  if (meta)
    requireValue(
      meta.localStackContainerId === runtime.localStackContainerId,
      "OBSERVABILITY_RUNTIME_OWNERSHIP_MISMATCH",
    );
  const dashboardName =
      "cloudtasks-" + runtime.localStackContainerId.slice(0, 12),
    stream = "monitor-" + runtime.localStackContainerId.slice(0, 12),
    tags = { project: "cloudtasks", runtime: runtime.localStackContainerId };
  const groups =
    (
      await aws([
        "logs",
        "describe-log-groups",
        "--log-group-name-prefix",
        logGroup,
      ])
    ).logGroups ?? [];
  const group = groups.find((g) => g.logGroupName === logGroup);
  if (group) {
    const existing =
      (await aws(["logs", "list-tags-log-group", "--log-group-name", logGroup]))
        .tags ?? {};
    requireValue(
      existing.project === "cloudtasks" &&
        existing.runtime === runtime.localStackContainerId,
      "OBSERVABILITY_LOG_GROUP_FOREIGN",
    );
  } else
    await aws(["logs", "create-log-group"], { logGroupName: logGroup, tags });
  await aws(["logs", "put-retention-policy"], {
    logGroupName: logGroup,
    retentionInDays: 7,
  });
  const streams =
    (
      await aws([
        "logs",
        "describe-log-streams",
        "--log-group-name",
        logGroup,
        "--log-stream-name-prefix",
        stream,
      ])
    ).logStreams ?? [];
  if (!streams.some((s) => s.logStreamName === stream))
    await aws(["logs", "create-log-stream"], {
      logGroupName: logGroup,
      logStreamName: stream,
    });
  const alarmTags = Object.entries(tags).map(([Key, Value]) => ({
    Key,
    Value,
  }));
  for (const alarm of productionAlarms(runtime.service)) {
    const existing = (
      await aws([
        "cloudwatch",
        "describe-alarms",
        "--alarm-names",
        alarm.AlarmName,
      ])
    ).MetricAlarms?.[0];
    if (existing) {
      const t =
        (
          await aws([
            "cloudwatch",
            "list-tags-for-resource",
            "--resource-arn",
            existing.AlarmArn,
          ])
        ).Tags ?? [];
      requireValue(
        t.some((x) => x.Key === "project" && x.Value === "cloudtasks") &&
          t.some(
            (x) =>
              x.Key === "runtime" && x.Value === runtime.localStackContainerId,
          ),
        "OBSERVABILITY_ALARM_FOREIGN",
      );
    }
    await aws(["cloudwatch", "put-metric-alarm"], {
      ...alarm,
      Tags: alarmTags,
    });
  }
  const dashboards =
    (
      await aws([
        "cloudwatch",
        "list-dashboards",
        "--dashboard-name-prefix",
        dashboardName,
      ])
    ).DashboardEntries ?? [];
  requireValue(
    meta || !dashboards.some((d) => d.DashboardName === dashboardName),
    "OBSERVABILITY_DASHBOARD_FOREIGN",
  );
  meta = {
    schemaVersion: 1,
    ...runtime,
    dashboardName,
    stream,
    namespace,
    logGroup,
    alarms: productionAlarms(runtime.service).map((a) => a.AlarmName),
    executionScope: "Docker/LocalStack only",
    createdAt: new Date().toISOString(),
  };
  await saved(metadataFile, meta);
  const result = await aws(["cloudwatch", "put-dashboard"], {
    DashboardName: dashboardName,
    DashboardBody: JSON.stringify(dashboardBody(runtime.service)),
  });
  requireValue(
    !result?.DashboardValidationMessages?.length,
    "OBSERVABILITY_DASHBOARD_INVALID",
  );
  const sample = await collect(runtime);
  await publish(sample, stream);
  await saved(path.join(root, "observability-sample.json"), sample);
  const pid = await startMonitor(runtime);
  return { meta, sample, monitorPid: pid };
}
async function isolatedAlarmTest(runtime) {
  const name =
      "cloudtasks-isolated-probe-" +
      runtime.localStackContainerId.slice(0, 12) +
      "-" +
      randomUUID().slice(0, 8),
    dims = [
      ...dimensions(runtime.service),
      { Name: "ProbeName", Value: "isolated-http-self-test" },
    ];
  const alarm = {
    AlarmName: name,
    AlarmDescription:
      "Isolated local HTTP probe test; no application outage induced",
    Namespace: namespace,
    MetricName: "IsolatedProbeUp",
    Dimensions: dims,
    Statistic: "Minimum",
    Period: 10,
    EvaluationPeriods: 1,
    DatapointsToAlarm: 1,
    Threshold: 1,
    ComparisonOperator: "LessThanThreshold",
    TreatMissingData: "ignore",
    ActionsEnabled: false,
    AlarmActions: [],
    OKActions: [],
    InsufficientDataActions: [],
    Tags: [
      { Key: "project", Value: "cloudtasks" },
      { Key: "runtime", Value: runtime.localStackContainerId },
    ],
  };
  const old = (
    await aws(["cloudwatch", "describe-alarms", "--alarm-names", name])
  ).MetricAlarms?.[0];
  requireValue(!old, "ISOLATED_ALARM_TEST_ALREADY_EXISTS");
  await aws(["cloudwatch", "put-metric-alarm"], alarm);
  let healthy = true;
  const server = http.createServer((_req, res) => {
    res.writeHead(healthy ? 200 : 503, { "Content-Type": "application/json" });
    res.end(
      JSON.stringify({
        status: healthy ? "ok" : "error",
        database: healthy ? "ok" : "controlled-test",
      }),
    );
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const url = "http://127.0.0.1:" + server.address().port + "/health",
    transitions = [],
    samples = [];
  const sample = async () => {
    const measured = await probeMeasurement(async () => {
      const r = await fetch(url, { signal: AbortSignal.timeout(5000) });
      return { status: r.status, text: await r.text() };
    });
    samples.push({ up: measured.up, time: new Date().toISOString() });
    await aws(["cloudwatch", "put-metric-data"], {
      Namespace: namespace,
      MetricData: [
        {
          MetricName: "IsolatedProbeUp",
          Dimensions: dims,
          Value: measured.up,
          Unit: "Count",
          StorageResolution: 1,
          Timestamp: new Date().toISOString(),
        },
      ],
    });
    return measured;
  };
  async function until(expected, phase) {
    const deadline = Date.now() + 180000;
    while (Date.now() < deadline) {
      await sample();
      const current = (
        await aws(["cloudwatch", "describe-alarms", "--alarm-names", name])
      ).MetricAlarms?.[0];
      if (transitions.at(-1)?.state !== current?.StateValue)
        transitions.push({
          phase,
          state: current?.StateValue,
          time: new Date().toISOString(),
        });
      console.log("ISOLATED_ALARM_WAIT " + phase + " " + current?.StateValue);
      if (current?.StateValue === expected) return;
      await delay(5000);
    }
    throw new LocalOperationError("ISOLATED_ALARM_TRANSITION_TIMEOUT");
  }
  try {
    await until("OK", "healthy");
    healthy = false;
    await until("ALARM", "failed-http-probe");
    healthy = true;
    await until("OK", "recovered-http-probe");
    return {
      scope:
        "real isolated HTTP 200/503/200; provider evaluates published measurements, no SetAlarmState; production was kept available",
      alarmName: name,
      transitions,
      samples,
      setAlarmStateUsed: false,
      productionOutageInduced: false,
      serverClosed: true,
    };
  } finally {
    healthy = true;
    try {
      await sample();
    } finally {
      await new Promise((resolve) => server.close(resolve));
    }
  }
}

let runtime;
try {
  requireValue(
    ["create", "sample", "status", "monitor", "test"].includes(mode),
    "OBSERVABILITY_MODE_INVALID",
  );
  runtime = await checkedRuntime();
  if (mode === "create") {
    const result = await configure(runtime);
    console.log(
      JSON.stringify({
        observabilityCreated: true,
        monitorPid: result.monitorPid,
        physicalRunning: result.sample.physicalRunning,
        verifiedHealthy: result.sample.verifiedHealthy,
        probeUp: result.sample.probeUp,
      }),
    );
  } else if (mode === "monitor") {
    const meta = await configured(runtime),
      lock = await open(pidFile, "wx");
    await lock.writeFile(
      JSON.stringify({
        ...runtime,
        pid: process.pid,
        moduleFile,
        time: new Date().toISOString(),
      }),
    );
    await lock.close();
    const stop = async () => {
      try {
        const current = await jsonFile(pidFile);
        if (current.pid === process.pid) await unlink(pidFile);
      } finally {
        process.exit();
      }
    };
    process.once("SIGTERM", () => void stop());
    process.once("SIGINT", () => void stop());
    while (true) {
      try {
        const current = await checkedRuntime();
        requireValue(
          current.localStackContainerId === runtime.localStackContainerId,
          "MONITOR_RUNTIME_CHANGED",
        );
        const sample = await collect(current);
        await publish(sample, meta.stream);
        await saved(heartbeatFile, {
          pid: process.pid,
          sample,
          recordedAt: new Date().toISOString(),
        });
        console.log("OBSERVABILITY_SAMPLE_PUBLISHED " + sample.sampleId);
      } catch (e) {
        console.error("OBSERVABILITY_SAMPLE_FAILED=" + safeErrorCode(e));
      }
      await delay(30000);
    }
  } else {
    const meta = await configured(runtime);
    if (mode === "sample") {
      const sample = await collect(runtime);
      await publish(sample, meta.stream);
      await saved(path.join(root, "observability-sample.json"), sample);
      console.log(
        JSON.stringify({
          physicalRunning: sample.physicalRunning,
          verifiedHealthy: sample.verifiedHealthy,
          probeUp: sample.probeUp,
        }),
      );
    } else if (mode === "status") {
      const beat = await jsonFile(heartbeatFile),
        pid = await jsonFile(pidFile);
      requireValue(
        await monitorIdentity(pid.pid),
        "MONITOR_PROCESS_NOT_VERIFIED",
      );
      requireValue(
        Date.now() - Date.parse(beat.recordedAt) < 120000 &&
          beat.pid === pid.pid,
        "MONITOR_HEARTBEAT_STALE",
      );
      console.log(
        JSON.stringify({
          monitorAlive: true,
          heartbeatAgeSeconds: Math.round(
            (Date.now() - Date.parse(beat.recordedAt)) / 1000,
          ),
          sample: beat.sample,
          alarms: (
            await aws([
              "cloudwatch",
              "describe-alarms",
              "--alarm-names",
              ...meta.alarms,
            ])
          ).MetricAlarms?.map((a) => ({
            name: a.AlarmName,
            state: a.StateValue,
          })),
        }),
      );
    } else {
      const sample = await collect(runtime);
      await publish(sample, meta.stream);
      requireValue(
        sample.physicalRunning === 2 &&
          sample.verifiedHealthy === 2 &&
          sample.probeUp === 1,
        "OBSERVABILITY_CURRENT_APPLICATION_NOT_HEALTHY",
      );
      const dashboard = await aws([
        "cloudwatch",
        "get-dashboard",
        "--dashboard-name",
        meta.dashboardName,
      ]);
      requireValue(
        JSON.parse(dashboard.DashboardBody).widgets.length === 4,
        "OBSERVABILITY_DASHBOARD_NOT_READ_BACK",
      );
      const data = await aws(["cloudwatch", "get-metric-statistics"], {
        Namespace: namespace,
        MetricName: "ProbeUp",
        Dimensions: dimensions(runtime.service),
        StartTime: new Date(Date.now() - 900000).toISOString(),
        EndTime: new Date(Date.now() + 1000).toISOString(),
        Period: 60,
        Statistics: ["Minimum"],
        Unit: "Count",
      });
      requireValue(
        data.Datapoints?.some((d) => d.Minimum === 1),
        "OBSERVED_METRICS_NOT_READ_BACK",
      );
      const logs = await aws(["logs", "get-log-events"], {
        logGroupName: logGroup,
        logStreamName: meta.stream,
        limit: 20,
      });
      requireValue(
        logs.events?.some((e) => {
          try {
            return JSON.parse(e.message).sampleId === sample.sampleId;
          } catch {
            return false;
          }
        }),
        "OBSERVED_LOG_NOT_READ_BACK",
      );
      const isolated = await isolatedAlarmTest(runtime),
        beat = await jsonFile(heartbeatFile),
        pid = await jsonFile(pidFile);
      requireValue(
        (await monitorIdentity(pid.pid)) &&
          beat.pid === pid.pid &&
          Date.now() - Date.parse(beat.recordedAt) < 120000,
        "MONITOR_NOT_ALIVE_AFTER_TEST",
      );
      const proof = {
        schemaVersion: 1,
        status: "PASSED",
        scope:
          "actual custom metrics/logs/dashboard and isolated evaluated alarm in LocalStack; not AWS native ECS telemetry",
        ...runtime,
        sample,
        dashboardName: meta.dashboardName,
        dashboardWidgetsReadBack: 4,
        metricsReadBack: true,
        logSampleReadBack: true,
        monitorPid: pid.pid,
        continuousMonitoringVerified: true,
        heartbeat: beat,
        isolatedAlarm: isolated,
        externalNotificationsConfigured: false,
        recordedAt: new Date().toISOString(),
      };
      await saved(evidenceFile, proof);
      console.log("OBSERVABILITY_LIVE_METRICS_LOGS_DASHBOARD_ALARM_ACCEPTED");
    }
  }
} catch (e) {
  const code = safeErrorCode(e);
  if (runtime && mode !== "monitor")
    await saved(evidenceFile, {
      status: "FAILED",
      scope: "LocalStack observability",
      ...runtime,
      mode,
      error: code,
      recordedAt: new Date().toISOString(),
    });
  console.error("OBSERVABILITY_FAILED=" + code);
  process.exitCode = 1;
}
