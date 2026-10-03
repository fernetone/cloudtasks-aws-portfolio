// External command fixture: tests exercise the real PowerShell/native boundary.
import fs from "node:fs";
const args = process.argv.slice(2);
const mode = process.env.CLOUDTASKS_TEST_CASE || "healthy";
const cluster = "cloudtasks-cluster-r20261001000000000";
const buildId = mode.includes("short-id")
  ? "cloudtasks-build:4a3385dc"
  : "cloudtasks-build:11111111-1111-4111-8111-111111111111";
const executionId = "22222222-2222-4222-8222-222222222222";
const taskDefinition =
  "arn:aws:ecs:us-east-1:000000000000:task-definition/cloudtasks:2";
const imageUri =
  "000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4566/cloudtasks:pipeline-" +
  "11111111-1111-4111-8111-111111111111";
const digest = "sha256:" + "1".repeat(64);
const repository = {
  repositoryName: "cloudtasks",
  registryId: "000000000000",
  repositoryArn: "arn:aws:ecr:us-east-1:000000000000:repository/cloudtasks",
  repositoryUri:
    "000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4566/cloudtasks",
  imageTagMutability: "IMMUTABLE",
  imageScanningConfiguration: { scanOnPush: true },
};
const json = (value) => process.stdout.write(JSON.stringify(value) + "\n");
const error = (code) => {
  process.stderr.write(
    `An error occurred (${code}) when calling the operation\n`,
  );
  process.exitCode = 7;
};

if (
  mode === "secret-provider-failure" &&
  (args.includes("get-secret-value") || args.includes("describe-secret"))
) {
  process.stderr.write(
    "Provider error contained " + process.env.CLOUDTASKS_TEST_DB_CANARY + "\n",
  );
  process.exitCode = 7;
} else if (args[0] === "inspect") {
  if (mode.startsWith("diagnostic-")) {
    json([
      {
        State: {
          Status: "exited",
          ExitCode: 0,
          OOMKilled: false,
          StartedAt: "2026-10-01T22:40:20.522311614Z",
          FinishedAt: "2026-10-01T22:40:47.803032894Z",
        },
        Mounts: [
          {
            Destination: "/var/lib/localstack",
            Type: "bind",
            Source: "/test/session",
          },
        ],
        Config: {
          Env: [
            "LOCAL_AGENT_IMAGE_NAME=localstack/aws-codebuild-local:2",
            "IMAGE_NAME=public.ecr.aws/codebuild/amazonlinux-x86_64-standard:5.0",
            "LOCALSTACK_AUTH_TOKEN=" + process.env.CLOUDTASKS_TEST_DB_CANARY,
            "IMAGE_NAME=https://registry.example.test/?credential=" +
              process.env.CLOUDTASKS_TEST_DB_CANARY,
          ],
        },
      },
    ]);
  } else if (mode.startsWith("acceptance-") && !args.includes("--format")) {
    json([
      {
        State: {
          Running: true,
          Health: {
            Status: mode === "acceptance-unhealthy" ? "unhealthy" : "healthy",
          },
        },
        Config: {
          Image:
            mode === "acceptance-image-alias"
              ? "sha256:" + "a".repeat(64)
              : imageUri,
        },
        Image: "sha256:" + "a".repeat(64),
      },
    ]);
  } else console.log("a".repeat(64));
} else if (
  args[0] === "image" &&
  args[1] === "inspect" &&
  args.includes("{{.Id}}")
) {
  if (
    args.at(-1) !== "public.ecr.aws/codebuild/amazonlinux-x86_64-standard:5.0"
  ) {
    error("UnexpectedImage");
  } else if (
    mode === "image-cached" ||
    (mode === "image-cold" &&
      fs.existsSync(process.env.CLOUDTASKS_TEST_COUNTER))
  ) {
    console.log("sha256:" + "3".repeat(64));
  } else error("ImageNotFound");
} else if (args[0] === "pull") {
  if (
    args.at(-1) !== "public.ecr.aws/codebuild/amazonlinux-x86_64-standard:5.0"
  ) {
    error("UnexpectedImage");
  } else if (mode === "image-cold") {
    fs.writeFileSync(process.env.CLOUDTASKS_TEST_COUNTER, "downloaded");
  } else if (mode === "image-pull-empty") {
    // A successful exit alone does not prove the requested image is available.
  } else {
    process.stderr.write(
      "TLS handshake timeout: https://registry.example.test/layer?X-Amz-Credential=" +
        process.env.CLOUDTASKS_TEST_DB_CANARY +
        "\n",
    );
    process.exitCode = 17;
  }
} else if (args[0] === "image" && args[1] === "inspect") {
  json([
    repository.repositoryUri +
      "@" +
      (mode === "acceptance-wrong-digest"
        ? "sha256:" + "2".repeat(64)
        : digest),
  ]);
} else if (args[0] === "ps") {
  if (args.includes("{{.Names}}")) {
    console.log("cloudtasks-localstack");
  } else if (mode !== "missing-container") {
    const id = args.some((arg) => arg.includes("task-two"))
      ? "bbbbbbbbbbbb"
      : "aaaaaaaaaaaa";
    console.log(
      args.includes("{{.ID}}|{{.Names}}|{{.Status}}")
        ? `${id}|ls-ecs-task|Up 2 minutes (healthy)`
        : id,
    );
    // A row arrives before the native command has actually finished.
    setTimeout(() => {
      process.exitCode = mode === "late-native-failure" ? 7 : 0;
    }, 200);
  }
} else if (args[0] === "cp") {
  if (args[1].startsWith("cloudtasks-localstack:"))
    fs.copyFileSync(args[1].includes("cloudtasks-build-artifact-") ? process.env.CLOUDTASKS_TEST_ARTIFACT_BYTES : process.env.CLOUDTASKS_TEST_SOURCE_BYTES, args[2]);
  else if (process.env.CLOUDTASKS_TEST_ZIP)
    fs.copyFileSync(args[1], process.env.CLOUDTASKS_TEST_ZIP);
} else if (args.includes("describe-clusters")) {
  json({
    clusters: [
      {
        clusterName: cluster,
        status: "ACTIVE",
        registeredContainerInstancesCount: 0,
      },
    ],
    failures: [],
  });
} else if (args.includes("describe-services")) {
  json({
    services: [
      {
        serviceName: "cloudtasks-service",
        status: "ACTIVE",
        desiredCount: 2,
        runningCount: mode === "incomplete-service" ? 1 : 2,
        pendingCount: 0,
        taskDefinition,
      },
    ],
    failures: [],
  });
} else if (args.includes("list-tasks")) {
  json({
    taskArns: ["task-one", "task-two"].map(
      (id) => `arn:aws:ecs:us-east-1:000000000000:task/${cluster}/${id}`,
    ),
  });
} else if (args.includes("describe-tasks")) {
  json({
    tasks: ["task-one", "task-two"].map((id) => ({
      taskArn: `arn:aws:ecs:us-east-1:000000000000:task/${cluster}/${id}`,
      lastStatus: "RUNNING",
      taskDefinitionArn:
        mode === "acceptance-old-task"
          ? taskDefinition.replace(":2", ":1")
          : taskDefinition,
      containers: [
        { name: "cloudtasks-app", image: imageUri, lastStatus: "RUNNING" },
      ],
    })),
    failures: [],
  });
} else if (args.includes("describe-task-definition")) {
  json({
    taskDefinition: {
      taskDefinitionArn: taskDefinition,
      containerDefinitions: [{ name: "cloudtasks-app", image: imageUri }],
    },
  });
} else if (args.includes("list-pipelines")) {
  json({ pipelines: [{ name: "cloudtasks-pipeline" }] });
} else if (args.includes("list-pipeline-executions")) {
  json({
    pipelineExecutionSummaries: [
      {
        pipelineExecutionId: executionId,
        status:
          mode === "diagnostic-candidate-short-id" ? "Failed" : "Succeeded",
        startTime: 1790892574.215145,
      },
    ],
  });
} else if (args.includes("list-builds-for-project")) {
  json({
    ids: [
      mode === "diagnostic-linked-short-id"
        ? "cloudtasks-build:deadbeef"
        : buildId,
    ],
  });
} else if (args.includes("get-pipeline")) {
  json({
    pipeline: {
      pipelineType: "V1",
      stages: ["Source", "Build", "Deploy"].map((name) => ({ name })),
    },
  });
} else if (args.includes("get-pipeline-execution")) {
  json({
    pipelineExecution: {
      pipelineExecutionId: executionId,
      status: "Succeeded",
      artifactRevisions: [
        {
          name: "SourceOutput",
          revisionId:
            mode === "source-variable" ? "etag-identity" : "source-version",
        },
      ],
    },
  });
} else if (args.includes("list-action-executions")) {
  json({
    actionExecutionDetails: ["SourceSnapshot", "BuildAndPush", "DeployECS"].map(
      (name, i) => ({
        pipelineExecutionId: executionId,
        actionName: name,
        stageName: ["Source", "Build", "Deploy"][i],
        status: mode === "failed-action" && i === 1 ? "Failed" : "Succeeded",
        output: {
          outputArtifacts: i === 1 ? [{name: "BuildOutput", s3location: {bucket: "cloudtasks-pipeline-artifacts", key: "cloudtasks-pipeline/BuildOutput/native-artifact"}}] : [],
          outputVariables:
            i === 0
              ? {
                  VersionId:
                    mode === "source-conflict"
                      ? "other-source-version"
                      : "source-version",
                }
              : {},
          executionResult: {
            externalExecutionId:
              i === 1
                ? mode === "diagnostic-candidate-short-id"
                  ? ""
                  : buildId
                : "source-version",
            errorDetails:
              mode === "diagnostic-candidate-short-id" && i === 1
                ? {
                    message:
                      "Build timed out: https://registry.example.test/?credential=" +
                      process.env.CLOUDTASKS_TEST_DB_CANARY,
                  }
                : {},
          },
        },
      }),
    ),
  });
} else if (args.includes("batch-get-builds")) {
  json({
    builds: [
      {
        id: buildId,
        artifacts: {location: "arn:aws:s3:::cloudtasks-pipeline-artifacts/cloudtasks-pipeline/BuildOutput/native-artifact"},
        buildStatus:
          mode === "failed-build"
            ? "FAILED"
            : mode === "diagnostic-candidate-short-id"
              ? "IN_PROGRESS"
              : "SUCCEEDED",
        startTime: 1790892574.356929,
      },
    ],
    buildsNotFound: [],
  });
} else if (args.includes("describe-repositories")) {
  if (mode === "ecr-race" && args.includes("--repository-names")) {
    const file = process.env.CLOUDTASKS_TEST_COUNTER;
    if (!fs.existsSync(file)) {
      fs.writeFileSync(file, "1");
      error("RepositoryNotFoundException");
    } else json({ repositories: [repository] });
  } else json({ repositories: mode === "ecr-race" ? [] : [repository] });
} else if (args.includes("create-repository")) {
  error("RepositoryAlreadyExistsException");
} else if (args.includes("describe-images")) {
  json({
    imageDetails: [
      {
        repositoryName: "cloudtasks",
        imageDigest: digest,
        imageTags: ["pipeline-11111111-1111-4111-8111-111111111111"],
      },
    ],
  });
} else if (args.includes("create-db-instance")) {
  const value = args[args.indexOf("--master-user-password") + 1];
  process.stderr.write(`InvalidParameterValue: supplied value ${value}\n`);
  process.exitCode = 7;
} else if (args.includes("list-buckets")) {
  json({ Buckets: [{ Name: "cloudtasks-pipeline-source" }] });
} else if (args.includes("put-bucket-versioning")) {
  json({});
} else if (args.includes("get-bucket-versioning")) {
  json({ Status: "Enabled" });
} else if (args.includes("get-secret-value")) {
  json({
    Name: "cloudtasks/database",
    SecretString: JSON.stringify({
      password:
        process.env.CLOUDTASKS_TEST_DB_CANARY || "fixture-only-database-value",
    }),
  });
} else if (args.includes("put-object")) {
  json({ VersionId: "source-upload-version", ETag: "fixture" });
} else if (args.includes("head-object")) {
  json({ VersionId: "source-newer-version" });
} else if (args.includes("get-object")) {
  json({ VersionId: "source-version" });
} else if (
  args.includes("rm") ||
  (args.includes("s3") && args.includes("cp"))
) {
  // Temporary cleanup / the old publisher's upload.
} else {
  process.stderr.write("Unexpected fixture operation\n");
  process.exitCode = 9;
}
