import { readFile, writeFile, rename, unlink, open } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";
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
  checkedCommit,
  pipelineDeclaration,
  linkedExecution,
  checkedBuildArtifact,
  checkedDeclaration,
  githubRepository,
  githubBranch,
  pipelineName,
  buildProjectName,
  roleName,
  connectionName,
  artifactBucket,
} from "./github-pipeline-config.mjs";
import { toolRoot } from "../mcp/mcp-config.mjs";

const root = runtimeRoot(),
  metadataFile = path.join(root, "github-pipeline-runtime.json"),
  evidenceFile = path.join(root, "github-pipeline-evidence.json"),
  lockFile = path.join(root, "github-pipeline.lock");
const projectRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../..",
);
const mode = process.argv[2];
const requireValue = (value, code) => {
  if (!value) throw new LocalOperationError(code);
};
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
let phase = "preflight",
  proof,
  lock;
async function optional(file) {
  try {
    return JSON.parse((await readFile(file, "utf8")).replace(/^\uFEFF/, ""));
  } catch (e) {
    if (e.code === "ENOENT") return null;
    throw e;
  }
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
const tags = (runtime) => [
  { Key: "Project", Value: "cloudtasks" },
  { Key: "LocalStackId", Value: runtime.localStackContainerId },
];
function ownedTags(values, runtime) {
  return tags(runtime).every((t) =>
    values?.some(
      (v) => (v.Key ?? v.key) === t.Key && (v.Value ?? v.value) === t.Value,
    ),
  );
}
async function noActiveExecution() {
  for (const name of ["cloudtasks-pipeline", pipelineName]) {
    const exists = (
      await aws(["codepipeline", "list-pipelines"])
    ).pipelines?.some((p) => p.name === name);
    if (!exists) continue;
    const list = await aws([
      "codepipeline",
      "list-pipeline-executions",
      "--pipeline-name",
      name,
    ]);
    requireValue(
      !list.pipelineExecutionSummaries?.some((e) =>
        ["InProgress", "Stopping"].includes(e.status),
      ),
      "GITHUB_CONCURRENT_PIPELINE_EXECUTION",
    );
  }
}
async function service(runtime) {
  const result = await aws([
    "ecs",
    "describe-services",
    "--cluster",
    runtime.cluster,
    "--services",
    runtime.service,
  ]);
  requireValue(
    result.services?.length === 1 && !result.failures?.length,
    "GITHUB_ECS_SERVICE_MISSING",
  );
  return result.services[0];
}
async function snapshot() {
  await docker([
    "cp",
    path.join(projectRoot, "scripts/mcp/pipeline-database-snapshot.mjs"),
    "cloudtasks-localstack:" +
      toolRoot +
      "/project/scripts/mcp/pipeline-database-snapshot.mjs",
  ]);
  const result = JSON.parse(
    await docker([
      "exec",
      "cloudtasks-localstack",
      "node",
      toolRoot + "/project/scripts/mcp/pipeline-database-snapshot.mjs",
    ]),
  );
  requireValue(
    Number.isInteger(result.count) &&
      /^[a-f0-9]{32}$/.test(result.fingerprint ?? ""),
    "GITHUB_DATABASE_SNAPSHOT_INVALID",
  );
  return result;
}
async function configure(runtime, expectedCommit, previous) {
  await noActiveExecution();
  const current = await service(runtime);
  requireValue(
    current.desiredCount === 2 &&
      current.runningCount === 2 &&
      current.pendingCount === 0 &&
      current.deploymentController?.type === "ECS",
    "GITHUB_ECS_PREFLIGHT_NOT_READY",
  );
  const meta = previous ?? {
    schemaVersion: 1,
    runtime,
    repository: githubRepository,
    branch: githubBranch,
    pipelineName,
    buildProjectName,
  };
  meta.expectedCommit = checkedCommit(expectedCommit);
  meta.before = await snapshot();
  meta.previousTaskDefinition = current.taskDefinition;
  await saved(metadataFile, meta);
  const base = (
    await aws([
      "codebuild",
      "batch-get-projects",
      "--names",
      "cloudtasks-build",
    ])
  ).projects?.[0];
  requireValue(
    base?.name === "cloudtasks-build" &&
      base.source?.type === "CODEPIPELINE" &&
      base.source.buildspec === "buildspec.localstack.yml" &&
      base.environment?.image ===
        "public.ecr.aws/codebuild/amazonlinux-x86_64-standard:5.0" &&
      base.serviceRole ===
        "arn:aws:iam::000000000000:role/cloudtasks-codebuild-role",
    "GITHUB_BASE_BUILD_SCOPE_INVALID",
  );
  const repositories = (
    await aws([
      "ecr",
      "describe-repositories",
      "--repository-names",
      "cloudtasks",
    ])
  ).repositories;
  requireValue(
    repositories?.length === 1 &&
      repositories[0].imageTagMutability === "IMMUTABLE",
    "GITHUB_ECR_NOT_IMMUTABLE",
  );
  const connections =
    (await aws(["codeconnections", "list-connections"])).Connections?.filter(
      (c) => c.ConnectionName === connectionName,
    ) ?? [];
  requireValue(connections.length <= 1, "GITHUB_CONNECTION_AMBIGUOUS");
  if (connections.length) {
    const c = connections[0],
      existingTags = (
        await aws([
          "codeconnections",
          "list-tags-for-resource",
          "--resource-arn",
          c.ConnectionArn,
        ])
      ).Tags;
    requireValue(
      ownedTags(existingTags, runtime),
      "GITHUB_CONNECTION_NOT_OWNED",
    );
    meta.connectionArn = c.ConnectionArn;
  } else {
    phase = "create-connection";
    const c = await aws(["codeconnections", "create-connection"], {
      ConnectionName: connectionName,
      ProviderType: "GitHub",
      Tags: tags(runtime),
    });
    meta.connectionArn = c.ConnectionArn;
    await saved(metadataFile, meta);
    // This provider drops CreateConnection.Tags; TagResource persists them.
    await aws(["codeconnections", "tag-resource"], {
      ResourceArn: meta.connectionArn,
      Tags: tags(runtime),
    });
    const persistedTags = (
      await aws([
        "codeconnections",
        "list-tags-for-resource",
        "--resource-arn",
        meta.connectionArn,
      ])
    ).Tags;
    requireValue(
      ownedTags(persistedTags, runtime),
      "GITHUB_CONNECTION_TAGS_NOT_PERSISTED",
    );
  }
  const connection = (
    await aws([
      "codeconnections",
      "get-connection",
      "--connection-arn",
      meta.connectionArn,
    ])
  ).Connection;
  requireValue(
    connection?.ProviderType === "GitHub" &&
      connection.ConnectionStatus === "AVAILABLE",
    "GITHUB_CONNECTION_NOT_AVAILABLE",
  );
  phase = "configure-build";
  const existing =
    (
      await aws([
        "codebuild",
        "batch-get-projects",
        "--names",
        buildProjectName,
      ])
    ).projects ?? [];
  if (existing.length)
    requireValue(
      ownedTags(existing[0].tags, runtime),
      "GITHUB_BUILD_NOT_OWNED",
    );
  const allowed = new Set([
    "IMAGE_REPO_NAME",
    "CONTAINER_NAME",
    "AWS_DEFAULT_REGION",
    "AWS_ENDPOINT_URL",
    "DOCKER_HOST",
  ]);
  const environmentVariables = base.environment.environmentVariables.filter(
    (v) => allowed.has(v.name),
  );
  requireValue(
    environmentVariables.length === 5 &&
      environmentVariables.find((v) => v.name === "AWS_ENDPOINT_URL")?.value ===
        "http://cloudtasks-localstack:4566",
    "GITHUB_BUILD_ENDPOINT_INVALID",
  );
  const project = {
    name: buildProjectName,
    description:
      "BIA video reference: native public GitHub source and ECS standard deploy",
    source: {
      type: "CODEPIPELINE",
      buildspec: "buildspec.github.localstack.yml",
    },
    artifacts: { type: "CODEPIPELINE" },
    environment: {
      type: base.environment.type,
      image: base.environment.image,
      computeType: base.environment.computeType,
      privilegedMode: true,
      environmentVariables: [
        ...environmentVariables,
        {
          name: "EXPECTED_SOURCE_COMMIT",
          value: meta.expectedCommit,
          type: "PLAINTEXT",
        },
      ],
    },
    serviceRole: base.serviceRole,
    timeoutInMinutes: 30,
    tags: tags(runtime).map((t) => ({ key: t.Key, value: t.Value })),
  };
  await aws(
    ["codebuild", existing.length ? "update-project" : "create-project"],
    project,
  );
  phase = "configure-pipeline-role";
  const roles =
    (await aws(["iam", "list-roles"])).Roles?.filter(
      (r) => r.RoleName === roleName,
    ) ?? [];
  if (roles.length) {
    const role = (await aws(["iam", "get-role", "--role-name", roleName])).Role;
    requireValue(
      ownedTags(role.Tags, runtime),
      "GITHUB_PIPELINE_ROLE_NOT_OWNED",
    );
    meta.roleArn = role.Arn;
  } else {
    const role = await aws(["iam", "create-role"], {
      RoleName: roleName,
      Tags: tags(runtime),
      AssumeRolePolicyDocument: JSON.stringify({
        Version: "2012-10-17",
        Statement: [
          {
            Effect: "Allow",
            Principal: { Service: "codepipeline.amazonaws.com" },
            Action: "sts:AssumeRole",
          },
        ],
      }),
    });
    meta.roleArn = role.Role.Arn;
    await saved(metadataFile, meta);
  }
  const definition = (
    await aws([
      "ecs",
      "describe-task-definition",
      "--task-definition",
      current.taskDefinition,
    ])
  ).taskDefinition;
  const taskRoles = [
    definition.executionRoleArn,
    definition.taskRoleArn,
  ].filter(Boolean);
  requireValue(
    taskRoles.every((a) =>
      /^arn:aws:iam::000000000000:role\/cloudtasks/.test(a),
    ),
    "GITHUB_ECS_ROLE_SCOPE_INVALID",
  );
  const statement = [
    {
      Effect: "Allow",
      Action: ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"],
      Resource: "arn:aws:s3:::" + artifactBucket + "/*",
    },
    {
      Effect: "Allow",
      Action: ["s3:GetBucketVersioning"],
      Resource: "arn:aws:s3:::" + artifactBucket,
    },
    {
      Effect: "Allow",
      Action: [
        "codeconnections:UseConnection",
        "codestar-connections:UseConnection",
      ],
      Resource: meta.connectionArn,
    },
    {
      Effect: "Allow",
      Action: ["codebuild:StartBuild", "codebuild:BatchGetBuilds"],
      Resource:
        "arn:aws:codebuild:us-east-1:000000000000:project/" + buildProjectName,
    },
    {
      Effect: "Allow",
      Action: ["ecs:DescribeServices", "ecs:UpdateService"],
      Resource:
        "arn:aws:ecs:us-east-1:000000000000:service/" +
        runtime.cluster +
        "/" +
        runtime.service,
    },
    {
      Effect: "Allow",
      Action: ["ecs:DescribeTaskDefinition"],
      Resource:
        "arn:aws:ecs:us-east-1:000000000000:task-definition/cloudtasks:*",
    },
    {
      Effect: "Allow",
      Action: [
        "ecs:RegisterTaskDefinition",
        "ecs:ListTasks",
        "ecs:DescribeTasks",
      ],
      Resource: "*",
    },
  ];
  if (taskRoles.length)
    statement.push({
      Effect: "Allow",
      Action: "iam:PassRole",
      Resource: taskRoles,
      Condition: {
        StringEquals: { "iam:PassedToService": "ecs-tasks.amazonaws.com" },
      },
    });
  await aws(["iam", "put-role-policy"], {
    RoleName: roleName,
    PolicyName: "cloudtasks-github-pipeline",
    PolicyDocument: JSON.stringify({
      Version: "2012-10-17",
      Statement: statement,
    }),
  });
  phase = "create-or-start-pipeline";
  const declaration = pipelineDeclaration(
    runtime,
    meta.connectionArn,
    meta.roleArn,
  );
  const exists = (
    await aws(["codepipeline", "list-pipelines"])
  ).pipelines?.some((p) => p.name === pipelineName);
  if (exists) {
    const currentDeclaration = (
      await aws(["codepipeline", "get-pipeline", "--name", pipelineName])
    ).pipeline;
    const pipelineTags = (
      await aws([
        "codepipeline",
        "list-tags-for-resource",
        "--resource-arn",
        "arn:aws:codepipeline:us-east-1:000000000000:" + pipelineName,
      ])
    ).tags;
    requireValue(
      ownedTags(pipelineTags, runtime) &&
        currentDeclaration.roleArn === meta.roleArn,
      "GITHUB_PIPELINE_NOT_OWNED",
    );
    await aws(["codepipeline", "update-pipeline"], { pipeline: declaration });
    meta.executionId = (
      await aws([
        "codepipeline",
        "start-pipeline-execution",
        "--name",
        pipelineName,
      ])
    ).pipelineExecutionId;
  } else {
    await aws(["codepipeline", "create-pipeline"], {
      pipeline: declaration,
      tags: tags(runtime).map((t) => ({ key: t.Key, value: t.Value })),
    });
    for (let i = 0; i < 20; i++) {
      const executions =
        (
          await aws([
            "codepipeline",
            "list-pipeline-executions",
            "--pipeline-name",
            pipelineName,
          ])
        ).pipelineExecutionSummaries ?? [];
      requireValue(executions.length <= 1, "GITHUB_CREATE_EXECUTION_AMBIGUOUS");
      if (executions.length === 1) {
        meta.executionId = executions[0].pipelineExecutionId;
        break;
      }
      await delay(1000);
    }
    requireValue(meta.executionId, "GITHUB_CREATE_EXECUTION_MISSING");
  }
  meta.createdAt = new Date().toISOString();
  await saved(metadataFile, meta);
  return meta;
}
async function artifact(action, name, receipt = false) {
  const outputs =
    action.output?.outputArtifacts?.filter((a) => a.name === name) ?? [];
  requireValue(
    outputs.length === 1 &&
      outputs[0].s3location?.bucket === artifactBucket &&
      typeof outputs[0].s3location.key === "string",
    "GITHUB_NATIVE_ARTIFACT_MISSING",
  );
  const location = outputs[0].s3location,
    remote = "/tmp/cloudtasks-github-artifact-" + randomUUID() + ".zip";
  try {
    await aws([
      "s3api",
      "get-object",
      "--bucket",
      location.bucket,
      "--key",
      location.key,
      remote,
    ]);
    const script = `import sys,json,hashlib,zipfile,os\np=sys.argv[1]\nassert os.path.getsize(p)<33554432\nz=zipfile.ZipFile(p)\nassert len(z.infolist())<2048\nresult={'sha256':hashlib.sha256(open(p,'rb').read()).hexdigest(),'entries':len(z.infolist())}\nif sys.argv[2]=='receipt':\n for f,k in [('imagedefinitions.json','images'),('source-receipt.json','receipt')]:\n  e=[i for i in z.infolist() if i.filename==f]\n  assert len(e)==1 and e[0].file_size<16384\n  result[k]=json.loads(z.read(e[0]))\nprint(json.dumps(result))`;
    return {
      ...JSON.parse(
        await docker([
          "exec",
          "cloudtasks-localstack",
          "python",
          "-c",
          script,
          remote,
          receipt ? "receipt" : "source",
        ]),
      ),
      bucket: location.bucket,
      key: location.key,
    };
  } finally {
    await docker(["exec", "cloudtasks-localstack", "rm", "-f", remote]);
  }
}
async function accept(meta) {
  phase = "native-execution";
  const actual = (
    await aws(["codepipeline", "get-pipeline", "--name", pipelineName])
  ).pipeline;
  const expected = pipelineDeclaration(
    meta.runtime,
    meta.connectionArn,
    meta.roleArn,
  );
  checkedDeclaration(actual, expected);
  const execution = (
    await aws([
      "codepipeline",
      "get-pipeline-execution",
      "--pipeline-name",
      pipelineName,
      "--pipeline-execution-id",
      meta.executionId,
    ])
  ).pipelineExecution;
  const actions =
    (
      await aws([
        "codepipeline",
        "list-action-executions",
        "--pipeline-name",
        pipelineName,
        "--filter",
        "pipelineExecutionId=" + meta.executionId,
      ])
    ).actionExecutionDetails ?? [];
  const linked = linkedExecution(execution, actions, meta.expectedCommit);
  const buildId = linked.build.output.executionResult.externalExecutionId;
  const build = (await aws(["codebuild", "batch-get-builds", "--ids", buildId]))
    .builds?.[0];
  requireValue(
    build?.id === buildId && build.buildStatus === "SUCCEEDED",
    "GITHUB_LINKED_BUILD_NOT_SUCCEEDED",
  );
  phase = "native-artifacts";
  const sourceArtifact = await artifact(linked.source, "SourceOutput"),
    buildArtifact = await artifact(linked.build, "BuildOutput", true);
  requireValue(
    build.artifacts?.location ===
      "arn:aws:s3:::" + buildArtifact.bucket + "/" + buildArtifact.key,
    "GITHUB_BUILD_ARTIFACT_LOCATION_MISMATCH",
  );
  const repository = (
    await aws([
      "ecr",
      "describe-repositories",
      "--repository-names",
      "cloudtasks",
    ])
  ).repositories?.[0];
  requireValue(
    repository?.imageTagMutability === "IMMUTABLE",
    "GITHUB_ECR_NOT_IMMUTABLE",
  );
  const image = checkedBuildArtifact(
      buildArtifact,
      build,
      {
        commit: meta.expectedCommit,
        executionId: meta.executionId,
        codeBuildId: buildId,
      },
      repository.repositoryUri,
    ),
    tag = image.slice(image.lastIndexOf(":") + 1);
  const images = (
    await aws([
      "ecr",
      "describe-images",
      "--repository-name",
      "cloudtasks",
      "--image-ids",
      "imageTag=" + tag,
    ])
  ).imageDetails;
  requireValue(
    images?.length === 1 && /^sha256:[a-f0-9]{64}$/.test(images[0].imageDigest),
    "GITHUB_ECR_DIGEST_INVALID",
  );
  phase = "physical-ecs";
  const current = await service(meta.runtime),
    definition = (
      await aws([
        "ecs",
        "describe-task-definition",
        "--task-definition",
        current.taskDefinition,
      ])
    ).taskDefinition;
  requireValue(
    current.desiredCount === 2 &&
      current.runningCount === 2 &&
      current.pendingCount === 0 &&
      current.taskDefinition !== meta.previousTaskDefinition &&
      definition.containerDefinitions?.find((c) => c.name === "cloudtasks-app")
        ?.image === image,
    "GITHUB_ECS_IMAGE_OR_REPLICAS_MISMATCH",
  );
  const arns = (
    await aws([
      "ecs",
      "list-tasks",
      "--cluster",
      meta.runtime.cluster,
      "--service-name",
      meta.runtime.service,
      "--desired-status",
      "RUNNING",
    ])
  ).taskArns;
  requireValue(arns?.length === 2, "GITHUB_ECS_TASK_COUNT_INVALID");
  const tasks = (
    await aws([
      "ecs",
      "describe-tasks",
      "--cluster",
      meta.runtime.cluster,
      "--tasks",
      ...arns,
    ])
  ).tasks;
  const physical = [];
  for (const task of tasks ?? []) {
    requireValue(
      task.lastStatus === "RUNNING" &&
        task.taskDefinitionArn === current.taskDefinition,
      "GITHUB_TASK_REVISION_MISMATCH",
    );
    const id = task.taskArn.split("/").at(-1),
      prefix = "ls-ecs-" + meta.runtime.cluster + "-" + id + "-";
    requireValue(/^[a-f0-9-]{36}$/.test(id), "GITHUB_TASK_ID_INVALID");
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
      .filter((r) => r.Names.startsWith(prefix));
    requireValue(rows.length === 1, "GITHUB_PHYSICAL_TASK_AMBIGUOUS");
    const [container] = JSON.parse(await docker(["inspect", rows[0].ID])),
      [physicalImage] = JSON.parse(
        await docker(["image", "inspect", container.Image]),
      );
    requireValue(
      container.State.Running &&
        container.State.Health?.Status === "healthy" &&
        container.Config.Image === image &&
        physicalImage.RepoDigests?.some((d) =>
          d.endsWith("@" + images[0].imageDigest),
        ),
      "GITHUB_PHYSICAL_IMAGE_OR_HEALTH_MISMATCH",
    );
    physical.push({
      taskArn: task.taskArn,
      containerId: container.Id,
      ip: container.NetworkSettings.Networks?.["cloudtasks-localstack-network"]
        ?.IPAddress,
      health: container.State.Health.Status,
    });
  }
  requireValue(
    physical.length === 2 &&
      new Set(physical.map((c) => c.containerId)).size === 2,
    "GITHUB_PHYSICAL_REPLICA_COUNT_INVALID",
  );
  const running = (
    await docker([
      "ps",
      "--no-trunc",
      "--filter",
      "name=ls-ecs-" + meta.runtime.cluster + "-",
      "--format",
      "{{json .}}",
    ])
  )
    .trim()
    .split("\n")
    .filter(Boolean)
    .map(JSON.parse)
    .filter((c) => c.Names.startsWith("ls-ecs-" + meta.runtime.cluster + "-"));
  requireValue(
    running.length === 2 &&
      running.every((c) => physical.some((p) => p.containerId === c.ID)),
    "GITHUB_EXTRA_PHYSICAL_REPLICAS",
  );
  phase = "alb-and-database";
  const group = (
    await aws(["elbv2", "describe-target-groups", "--names", "cloudtasks-tg"])
  ).TargetGroups?.[0];
  const targets = (
    await aws([
      "elbv2",
      "describe-target-health",
      "--target-group-arn",
      group.TargetGroupArn,
    ])
  ).TargetHealthDescriptions;
  requireValue(
    targets?.length === 2 &&
      physical.every((c) =>
        targets.some(
          (t) =>
            t.Target.Id === c.ip &&
            t.Target.Port === 3000 &&
            t.TargetHealth.State === "healthy",
        ),
      ),
    "GITHUB_ALB_CURRENT_TARGETS_MISMATCH",
  );
  const pin = await gatewayPin(),
    health = await requestLocal(
      "https://cloudtasks-alb.elb.localhost.localstack.cloud:4566/health",
      { pin },
    ),
    release = await requestLocal(
      "https://cloudtasks-alb.elb.localhost.localstack.cloud:4566/release.json",
      { pin },
    );
  requireValue(
    health.status === 200 &&
      JSON.parse(health.text).database === "ok" &&
      release.status === 200 &&
      JSON.parse(release.text).releaseId === tag,
    "GITHUB_HTTPS_RELEASE_OR_DATABASE_MISMATCH",
  );
  const after = await snapshot();
  requireValue(
    JSON.stringify(meta.before) === JSON.stringify(after),
    "GITHUB_TASK_DATA_CHANGED",
  );
  proof = {
    schemaVersion: 1,
    status: "PASSED",
    scope:
      "native public GitHub source → CodeBuild → ECR → ECS standard → ALB HTTPS/RDS in LocalStack",
    runtime: meta.runtime,
    repository: meta.repository,
    branch: meta.branch,
    commit: meta.expectedCommit,
    connectionArn: meta.connectionArn,
    executionId: meta.executionId,
    codeBuildId: buildId,
    providers: ["CodeStarSourceConnection", "CodeBuild", "ECS"],
    sourceArtifact,
    buildArtifact: {
      sha256: buildArtifact.sha256,
      bucket: buildArtifact.bucket,
      key: buildArtifact.key,
      receipt: buildArtifact.receipt,
    },
    image,
    digest: images[0].imageDigest,
    previousTaskDefinition: meta.previousTaskDefinition,
    taskDefinition: current.taskDefinition,
    physicalTasks: physical,
    tlsPin: pin,
    httpsDatabaseHealth: true,
    deliveredRelease: tag,
    data: { before: meta.before, after, unchanged: true },
    autoPushTriggerVerified: false,
    githubAppOAuthVerified: false,
    recordedAt: new Date().toISOString(),
  };
  await saved(evidenceFile, proof);
  console.log(JSON.stringify(proof));
}
try {
  requireValue(
    ["create", "status", "test"].includes(mode),
    "GITHUB_PIPELINE_MODE_INVALID",
  );
  const runtime = await checkedRuntime();
  let meta = await optional(metadataFile);
  if (meta)
    requireValue(
      JSON.stringify(meta.runtime) === JSON.stringify(runtime) &&
        meta.repository === githubRepository &&
        meta.branch === githubBranch,
      "GITHUB_RUNTIME_OWNERSHIP_MISMATCH",
    );
  if (mode === "status") {
    requireValue(meta?.executionId, "GITHUB_PIPELINE_NOT_CONFIGURED");
    const execution = (
      await aws([
        "codepipeline",
        "get-pipeline-execution",
        "--pipeline-name",
        pipelineName,
        "--pipeline-execution-id",
        meta.executionId,
      ])
    ).pipelineExecution;
    console.log(
      JSON.stringify({
        pipelineName,
        executionId: meta.executionId,
        expectedCommit: meta.expectedCommit,
        status: execution.status,
        recordedAt: new Date().toISOString(),
      }),
    );
  } else {
    lock = await open(lockFile, "wx", 0o600);
    await lock.writeFile(JSON.stringify({ runtime, pid: process.pid, mode }));
    if (mode === "create") {
      meta = await configure(runtime, process.argv[3], meta);
      console.log(
        JSON.stringify({
          pipelineName,
          executionId: meta.executionId,
          expectedCommit: meta.expectedCommit,
          status: "STARTED",
        }),
      );
    } else {
      requireValue(meta?.executionId, "GITHUB_PIPELINE_NOT_CONFIGURED");
      await accept(meta);
    }
  }
} catch (e) {
  const failure = {
    schemaVersion: 1,
    status: "FAILED",
    phase,
    code: safeErrorCode(e),
    recordedAt: new Date().toISOString(),
  };
  if (mode !== "status")
    await saved(
      path.join(root, "github-pipeline-failed-" + randomUUID() + ".json"),
      failure,
    );
  console.error(JSON.stringify(failure));
  process.exitCode = 1;
} finally {
  if (lock) {
    await lock.close();
    await unlink(lockFile);
  }
}
