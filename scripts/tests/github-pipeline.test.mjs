import test from "node:test";
import assert from "node:assert/strict";
import {
  checkedCommit,
  sourceReceipt,
  linkedExecution,
  checkedBuildArtifact,
  pipelineDeclaration,
  roleName,
  checkedDeclaration,
} from "../localstack/github-pipeline-config.mjs";

const commit = "a".repeat(40),
  other = "b".repeat(40),
  id = "execution-a";
const buildId = "cloudtasks-github-build:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const repositoryUri =
  "000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4566/cloudtasks";
const image = repositoryUri + ":pipeline-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const environment = {
  EXPECTED_SOURCE_COMMIT: commit,
  SOURCE_COMMIT_ID: commit,
  CODEBUILD_BUILD_ID: buildId,
};
function native() {
  const execution = {
    pipelineExecutionId: id,
    status: "Succeeded",
    artifactRevisions: [{ name: "SourceOutput", revisionId: commit }],
  };
  const actions = [
    {
      pipelineExecutionId: id,
      stageName: "Source",
      actionName: "SourceGitHub",
      status: "Succeeded",
      output: { outputVariables: { CommitId: commit } },
    },
    {
      pipelineExecutionId: id,
      stageName: "Build",
      actionName: "BuildAndPush",
      status: "Succeeded",
      output: { executionResult: { externalExecutionId: buildId } },
    },
    {
      pipelineExecutionId: id,
      stageName: "Deploy",
      actionName: "DeployECS",
      status: "Succeeded",
    },
  ];
  return { execution, actions };
}
function artifact() {
  return {
    images: [{ name: "cloudtasks-app", imageUri: image }],
    receipt: sourceReceipt(environment),
    sha256: "c".repeat(64),
  };
}
test("rejects abbreviated, absent and injected commit values", () => {
  for (const v of [
    undefined,
    "8089357",
    commit + "\n",
    "https://example.com/" + commit,
    "a".repeat(39),
  ])
    assert.throws(() => checkedCommit(v), /GITHUB_COMMIT_REQUIRED/);
  assert.equal(checkedCommit(commit), commit);
});
test("source guard refuses a changed revision before producing a receipt", () => {
  assert.throws(
    () => sourceReceipt({ ...environment, SOURCE_COMMIT_ID: other }),
    /GITHUB_SOURCE_COMMIT_MISMATCH/,
  );
  assert.throws(
    () =>
      sourceReceipt({
        ...environment,
        SOURCE_COMMIT_ID: "#{SourceVariables.CommitId}",
      }),
    /GITHUB_SOURCE_COMMIT_MISMATCH/,
  );
  assert.deepEqual(sourceReceipt(environment), artifact().receipt);
});
test("successful actions from a different execution cannot prove this delivery", () => {
  const { execution, actions } = native();
  actions[1].pipelineExecutionId = "another-execution";
  assert.throws(
    () => linkedExecution(execution, actions, commit),
    /GITHUB_ACTION_NOT_LINKED_OR_SUCCEEDED/,
  );
});
test("both the native GitHub variable and artifact revision must identify the expected commit", () => {
  const a = native();
  a.actions[0].output.outputVariables.CommitId = other;
  assert.throws(
    () => linkedExecution(a.execution, a.actions, commit),
    /GITHUB_NATIVE_REVISION_MISMATCH/,
  );
  const b = native();
  b.execution.artifactRevisions[0].revisionId = other;
  assert.throws(
    () => linkedExecution(b.execution, b.actions, commit),
    /GITHUB_NATIVE_REVISION_MISMATCH/,
  );
  const c = native();
  assert.equal(
    linkedExecution(c.execution, c.actions, commit).build.output.executionResult
      .externalExecutionId,
    buildId,
  );
});
test("duplicate or failed actions are rejected even if the pipeline reports success", () => {
  const a = native();
  a.actions.push(structuredClone(a.actions[2]));
  assert.throws(
    () => linkedExecution(a.execution, a.actions, commit),
    /GITHUB_ACTION_NOT_LINKED_OR_SUCCEEDED/,
  );
  const b = native();
  b.actions[2].status = "Failed";
  assert.throws(
    () => linkedExecution(b.execution, b.actions, commit),
    /GITHUB_ACTION_NOT_LINKED_OR_SUCCEEDED/,
  );
});
test("the build receipt must belong to the exact successful native build", () => {
  assert.throws(
    () =>
      checkedBuildArtifact(
        artifact(),
        { id: "cloudtasks-github-build:bbbbbbbb", buildStatus: "SUCCEEDED" },
        commit,
        repositoryUri,
      ),
    /GITHUB_BUILD_RECEIPT_MISMATCH/,
  );
  assert.throws(
    () =>
      checkedBuildArtifact(
        artifact(),
        { id: buildId, buildStatus: "FAILED" },
        commit,
        repositoryUri,
      ),
    /GITHUB_BUILD_RECEIPT_MISMATCH/,
  );
  assert.equal(
    checkedBuildArtifact(
      artifact(),
      { id: buildId, buildStatus: "SUCCEEDED" },
      commit,
      repositoryUri,
    ),
    image,
  );
});
test("artifact image cannot name another container, mutable tag or external registry", () => {
  for (const images of [
    [{ name: "wrong", imageUri: image }],
    [{ name: "cloudtasks-app", imageUri: repositoryUri + ":latest" }],
    [
      {
        name: "cloudtasks-app",
        imageUri:
          "123456789012.dkr.ecr.us-east-1.amazonaws.com/cloudtasks:latest",
      },
    ],
    [],
  ]) {
    assert.throws(
      () =>
        checkedBuildArtifact(
          { ...artifact(), images },
          { id: buildId, buildStatus: "SUCCEEDED" },
          commit,
          repositoryUri,
        ),
      /GITHUB_BUILD_IMAGE_IDENTITY_INVALID/,
    );
  }
});
test("pipeline cannot target a real AWS connection, foreign role or unrelated ECS service", () => {
  const runtime = {
      cluster: "cloudtasks-cluster-r20261008153148448",
      service: "cloudtasks-service",
    },
    connection =
      "arn:aws:codeconnections:us-east-1:000000000000:connection/aaaaaaaa",
    role = "arn:aws:iam::000000000000:role/" + roleName;
  assert.throws(
    () =>
      pipelineDeclaration(
        runtime,
        connection.replace("000000000000", "123456789012"),
        role,
      ),
    /GITHUB_PIPELINE_SCOPE_INVALID/,
  );
  assert.throws(
    () =>
      pipelineDeclaration(
        { ...runtime, service: "another-service" },
        connection,
        role,
      ),
    /GITHUB_PIPELINE_SCOPE_INVALID/,
  );
  assert.throws(
    () => pipelineDeclaration(runtime, connection, role + "-foreign"),
    /GITHUB_PIPELINE_SCOPE_INVALID/,
  );
});
test("acceptance rejects substitution of S3 source, foreign region or removed commit namespace", () => {
  const expected = pipelineDeclaration(
    { cluster: "cloudtasks-cluster", service: "cloudtasks-service" },
    "arn:aws:codeconnections:us-east-1:000000000000:connection/aaaaaaaa",
    "arn:aws:iam::000000000000:role/" + roleName,
  );
  checkedDeclaration(structuredClone(expected), expected);
  for (const change of [
    (a) => {
      a.actionTypeId.provider = "S3";
    },
    (a) => {
      a.region = "eu-west-1";
    },
    (a) => {
      delete a.namespace;
    },
  ]) {
    const actual = structuredClone(expected);
    change(actual.stages[0].actions[0]);
    assert.throws(
      () => checkedDeclaration(actual, expected),
      /GITHUB_PIPELINE_DECLARATION_CHANGED/,
    );
  }
});
