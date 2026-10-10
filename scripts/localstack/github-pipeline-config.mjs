import { writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { isDeepStrictEqual } from "node:util";
import { LocalOperationError } from "./localstack-tools.mjs";

export const githubRepository = "fernetone/cloudtasks-aws-portfolio";
export const githubBranch = "docs/video-reference-20261008";
export const pipelineName = "cloudtasks-github-pipeline";
export const buildProjectName = "cloudtasks-github-build";
export const roleName = "cloudtasks-github-pipeline-role";
export const connectionName = "cloudtasks-github";
export const artifactBucket = "cloudtasks-pipeline-artifacts";
const requireValue = (value, code) => {
  if (!value) throw new LocalOperationError(code);
};
export function checkedCommit(value) {
  requireValue(/^[a-f0-9]{40}$/.test(value ?? ""), "GITHUB_COMMIT_REQUIRED");
  return value;
}
export function sourceReceipt(environment) {
  const expected = checkedCommit(environment.EXPECTED_SOURCE_COMMIT);
  requireValue(
    environment.SOURCE_COMMIT_ID === expected,
    "GITHUB_SOURCE_COMMIT_MISMATCH",
  );
  requireValue(
    /^cloudtasks-github-build:[a-f0-9-]+$/.test(
      environment.CODEBUILD_BUILD_ID ?? "",
    ),
    "GITHUB_BUILD_ID_INVALID",
  );
  return {
    repository: githubRepository,
    branch: githubBranch,
    commit: expected,
    codeBuildId: environment.CODEBUILD_BUILD_ID,
    provider: "CodeStarSourceConnection",
  };
}
export function pipelineDeclaration(runtime, connectionArn, roleArn) {
  requireValue(
    /^cloudtasks-cluster(?:-r\d{17})?$/.test(runtime.cluster) &&
      runtime.service === "cloudtasks-service" &&
      /^arn:aws:(?:codeconnections|codestar-connections):us-east-1:000000000000:connection\/[a-f0-9-]+$/.test(
        connectionArn,
      ) &&
      roleArn === "arn:aws:iam::000000000000:role/" + roleName,
    "GITHUB_PIPELINE_SCOPE_INVALID",
  );
  const action = (
    name,
    category,
    provider,
    configuration,
    inputArtifacts,
    outputArtifacts,
  ) => ({
    name,
    actionTypeId: { category, owner: "AWS", provider, version: "1" },
    runOrder: 1,
    configuration,
    inputArtifacts: inputArtifacts.map((name) => ({ name })),
    outputArtifacts: outputArtifacts.map((name) => ({ name })),
  });
  return {
    name: pipelineName,
    roleArn,
    artifactStore: { type: "S3", location: artifactBucket },
    stages: [
      {
        name: "Source",
        actions: [
          {
            ...action(
              "SourceGitHub",
              "Source",
              "CodeStarSourceConnection",
              {
                ConnectionArn: connectionArn,
                FullRepositoryId: githubRepository,
                BranchName: githubBranch,
                OutputArtifactFormat: "CODE_ZIP",
                DetectChanges: "false",
              },
              [],
              ["SourceOutput"],
            ),
            namespace: "SourceVariables",
          },
        ],
      },
      {
        name: "Build",
        actions: [
          action(
            "BuildAndPush",
            "Build",
            "CodeBuild",
            {
              ProjectName: buildProjectName,
              EnvironmentVariables: JSON.stringify([
                {
                  name: "SOURCE_COMMIT_ID",
                  value: "#{SourceVariables.CommitId}",
                  type: "PLAINTEXT",
                },
              ]),
            },
            ["SourceOutput"],
            ["BuildOutput"],
          ),
        ],
      },
      {
        name: "Deploy",
        actions: [
          action(
            "DeployECS",
            "Deploy",
            "ECS",
            {
              ClusterName: runtime.cluster,
              ServiceName: runtime.service,
              FileName: "imagedefinitions.json",
            },
            ["BuildOutput"],
            [],
          ),
        ],
      },
    ],
    version: 1,
    executionMode: "SUPERSEDED",
    pipelineType: "V1",
  };
}
export function linkedExecution(execution, actions, expectedCommit) {
  checkedCommit(expectedCommit);
  requireValue(
    execution.status === "Succeeded",
    "GITHUB_PIPELINE_NOT_SUCCEEDED",
  );
  const pick = (stage, name) => {
    const selected = actions.filter(
      (a) =>
        a.pipelineExecutionId === execution.pipelineExecutionId &&
        a.stageName === stage &&
        a.actionName === name,
    );
    requireValue(
      selected.length === 1 && selected[0].status === "Succeeded",
      "GITHUB_ACTION_NOT_LINKED_OR_SUCCEEDED",
    );
    return selected[0];
  };
  const source = pick("Source", "SourceGitHub"),
    build = pick("Build", "BuildAndPush"),
    deploy = pick("Deploy", "DeployECS");
  const revision =
    execution.artifactRevisions?.filter((x) => x.name === "SourceOutput") ?? [];
  requireValue(
    source.output?.outputVariables?.CommitId === expectedCommit &&
      revision.length === 1 &&
      revision[0].revisionId === expectedCommit,
    "GITHUB_NATIVE_REVISION_MISMATCH",
  );
  requireValue(
    /^cloudtasks-github-build:[a-f0-9-]+$/.test(
      build.output?.executionResult?.externalExecutionId ?? "",
    ),
    "GITHUB_NATIVE_BUILD_ID_MISSING",
  );
  return { source, build, deploy };
}
export function checkedDeclaration(actual, expected) {
  const stages = (pipeline) =>
    pipeline.stages?.map((stage) => ({
      name: stage.name,
      actions: stage.actions?.map((a) => ({
        name: a.name,
        actionTypeId: a.actionTypeId,
        runOrder: a.runOrder,
        namespace: a.namespace,
        region: a.region ?? "us-east-1",
        configuration: a.configuration,
        inputArtifacts: a.inputArtifacts,
        outputArtifacts: a.outputArtifacts,
      })),
    }));
  requireValue(
    actual.name === expected.name &&
      actual.roleArn === expected.roleArn &&
      actual.pipelineType === "V1" &&
      isDeepStrictEqual(actual.artifactStore, expected.artifactStore) &&
      isDeepStrictEqual(stages(actual), stages(expected)),
    "GITHUB_PIPELINE_DECLARATION_CHANGED",
  );
}
export function checkedBuildArtifact(
  artifact,
  build,
  expectedCommit,
  repositoryUri,
) {
  const images = artifact.images;
  requireValue(
    artifact.receipt?.commit === checkedCommit(expectedCommit) &&
      artifact.receipt.repository === githubRepository &&
      artifact.receipt.branch === githubBranch &&
      artifact.receipt.provider === "CodeStarSourceConnection" &&
      artifact.receipt.codeBuildId === build.id &&
      build.buildStatus === "SUCCEEDED",
    "GITHUB_BUILD_RECEIPT_MISMATCH",
  );
  requireValue(
    Array.isArray(images) &&
      images.length === 1 &&
      images[0].name === "cloudtasks-app" &&
      repositoryUri ===
        "000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4566/cloudtasks" &&
      images[0].imageUri.startsWith(repositoryUri + ":pipeline-") &&
      /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(
        images[0].imageUri.slice((repositoryUri + ":pipeline-").length),
      ) &&
      /^[a-f0-9]{64}$/.test(artifact.sha256 ?? ""),
    "GITHUB_BUILD_IMAGE_IDENTITY_INVALID",
  );
  return images[0].imageUri;
}
if (
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    requireValue(
      process.argv[2] === "source-guard",
      "GITHUB_CONFIG_MODE_INVALID",
    );
    await writeFile(
      "source-receipt.json",
      JSON.stringify(sourceReceipt(process.env)) + "\n",
      { flag: "wx" },
    );
    console.log("GITHUB_SOURCE_COMMIT_VERIFIED");
  } catch (error) {
    console.error(
      error instanceof LocalOperationError
        ? error.code
        : "GITHUB_SOURCE_GUARD_FAILED",
    );
    process.exitCode = 1;
  }
}
