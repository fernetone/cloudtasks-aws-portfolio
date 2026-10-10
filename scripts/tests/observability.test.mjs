import assert from "node:assert/strict";
import test from "node:test";
import {
  metricData,
  productionAlarms,
  probeMeasurement,
  dashboardBody,
} from "../localstack/observability-config.mjs";
const sample = {
  service: "cloudtasks-service",
  physicalRunning: 2,
  verifiedHealthy: 2,
  probeUp: 1,
  probeLatencyMs: 12.5,
  time: "2026-10-10T09:40:00.000Z",
};
test("metrics contain only observed numeric fields and stable dimensions", () => {
  const data = metricData({ ...sample, password: "private-canary" });
  assert.deepEqual(
    data.map((d) => d.MetricName),
    ["RunningReplicas", "HealthyReplicas", "ProbeUp", "ProbeLatency"],
  );
  assert.deepEqual(
    data.map((d) => d.Value),
    [2, 2, 1, 12.5],
  );
  assert.ok(
    data.every(
      (d) =>
        d.Dimensions.length === 2 &&
        d.Dimensions.some(
          (x) => x.Name === "Environment" && x.Value === "localstack",
        ),
    ),
  );
  assert.ok(!JSON.stringify(data).includes("private-canary"));
});
test("invalid samples and namespaces fail before publishing", () => {
  for (const fields of [
    { physicalRunning: -1 },
    { verifiedHealthy: NaN },
    { probeUp: 2 },
    { probeLatencyMs: Infinity },
    { time: "invalid" },
    { service: "foreign-service" },
  ])
    assert.throws(() => metricData({ ...sample, ...fields }));
});
test("production alarms have missing-data semantics, 2/3 evaluation and no external actions", () => {
  const alarms = productionAlarms("cloudtasks-service");
  assert.equal(alarms.length, 2);
  for (const a of alarms) {
    assert.equal(a.Namespace, "CloudTasks/LocalStack");
    assert.equal(a.Period, 60);
    assert.equal(a.EvaluationPeriods, 3);
    assert.equal(a.DatapointsToAlarm, 2);
    assert.equal(a.TreatMissingData, "breaching");
    assert.deepEqual(a.AlarmActions, []);
    assert.deepEqual(a.OKActions, []);
  }
});
test("probe health requires a real successful database-aware response", async () => {
  const ok = await probeMeasurement(async () => ({
    status: 200,
    text: '{"status":"ok","database":"ok"}',
  }));
  assert.equal(ok.up, 1);
  assert.ok(ok.latencyMs >= 0);
  for (const response of [
    { status: 503, text: '{"status":"ok","database":"ok"}' },
    { status: 200, text: '{"status":"ok","database":"error"}' },
    { status: 200, text: "private-canary-invalid-json" },
  ]) {
    const r = await probeMeasurement(async () => response);
    assert.equal(r.up, 0);
    assert.ok(!JSON.stringify(r).includes("private-canary"));
  }
  const rejected = await probeMeasurement(async () => {
    throw Error("private-canary");
  });
  assert.equal(rejected.up, 0);
  assert.ok(!JSON.stringify(rejected).includes("private-canary"));
});
test("dashboard uses actual custom metrics and tail latency, without AWS namespace claims", () => {
  const body = dashboardBody("cloudtasks-service");
  assert.ok(body.widgets.length >= 3);
  const json = JSON.stringify(body);
  assert.ok(json.includes("CloudTasks/LocalStack"));
  assert.ok(json.includes("p99"));
  assert.ok(!json.includes("AWS/ECS"));
  assert.ok(!json.includes("requestId"));
});
