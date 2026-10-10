import { LocalOperationError, safeErrorCode } from "./localstack-tools.mjs";
const requireValue = (v, c) => {
  if (!v) throw new LocalOperationError(c);
};
export const namespace = "CloudTasks/LocalStack";
export function dimensions(service) {
  requireValue(
    service === "cloudtasks-service",
    "OBSERVABILITY_SERVICE_MISMATCH",
  );
  return [
    { Name: "ServiceName", Value: service },
    { Name: "Environment", Value: "localstack" },
  ];
}
export function metricData(sample) {
  requireValue(
    Number.isInteger(sample.physicalRunning) &&
      sample.physicalRunning >= 0 &&
      Number.isInteger(sample.verifiedHealthy) &&
      sample.verifiedHealthy >= 0 &&
      sample.verifiedHealthy <= sample.physicalRunning &&
      (sample.probeUp === 0 || sample.probeUp === 1) &&
      Number.isFinite(sample.probeLatencyMs) &&
      sample.probeLatencyMs >= 0 &&
      Number.isFinite(Date.parse(sample.time)),
    "INVALID_OBSERVED_SAMPLE",
  );
  const dims = dimensions(sample.service);
  return [
    ["RunningReplicas", sample.physicalRunning, "Count"],
    ["HealthyReplicas", sample.verifiedHealthy, "Count"],
    ["ProbeUp", sample.probeUp, "Count"],
    ["ProbeLatency", sample.probeLatencyMs, "Milliseconds"],
  ].map(([MetricName, Value, Unit]) => ({
    MetricName,
    Value,
    Unit,
    Dimensions: dims,
    Timestamp: sample.time,
  }));
}
export function productionAlarms(service) {
  return [
    ["cloudtasks-healthy-replicas", "HealthyReplicas", 2],
    ["cloudtasks-health-probe", "ProbeUp", 1],
  ].map(([AlarmName, MetricName, Threshold]) => ({
    AlarmName,
    AlarmDescription:
      "Measured Docker/ALB/health in LocalStack; no AWS native metrics claim",
    Namespace: namespace,
    MetricName,
    Dimensions: dimensions(service),
    Statistic: "Minimum",
    Period: 60,
    EvaluationPeriods: 3,
    DatapointsToAlarm: 2,
    Threshold,
    ComparisonOperator: "LessThanThreshold",
    TreatMissingData: "breaching",
    ActionsEnabled: false,
    AlarmActions: [],
    OKActions: [],
    InsufficientDataActions: [],
  }));
}
export async function probeMeasurement(request) {
  const started = performance.now();
  let up = 0,
    error;
  try {
    const response = await request();
    const body = JSON.parse(response.text);
    up =
      response.status === 200 && body.status === "ok" && body.database === "ok"
        ? 1
        : 0;
  } catch (e) {
    error = safeErrorCode(e);
  }
  return {
    up,
    latencyMs: performance.now() - started,
    ...(error ? { error } : {}),
  };
}
export function dashboardBody(service) {
  const metric = (name, stat) => ({
    type: "metric",
    width: 12,
    height: 6,
    properties: {
      title: name + " — observed locally",
      region: "us-east-1",
      period: 60,
      stat,
      metrics: [
        [
          namespace,
          name,
          ...dimensions(service).flatMap((d) => [d.Name, d.Value]),
        ],
      ],
      yAxis: { left: { min: 0 } },
    },
  });
  return {
    widgets: [
      metric("HealthyReplicas", "Minimum"),
      metric("RunningReplicas", "Maximum"),
      metric("ProbeUp", "Minimum"),
      metric("ProbeLatency", "p99"),
    ],
  };
}
