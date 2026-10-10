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
  checkedSourceTree,
} from "../localstack/github-pipeline-config.mjs";

const commit = "a".repeat(40),
  other = "b".repeat(40),
  id = "628c012e-f077-45c7-9596-6bd8f336fe7a";
const buildId = "cloudtasks-github-build:aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const delivery = { commit, executionId: id, codeBuildId: buildId };
const repositoryUri =
  "000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4566/cloudtasks";
const image = repositoryUri + ":pipeline-aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
const environment = {
  EXPECTED_SOURCE_COMMIT: commit,
  SOURCE_COMMIT_ID: commit,
  CODEBUILD_BUILD_ID: buildId,
  PIPELINE_EXECUTION_ID: id,
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
      output: {
        outputVariables: { CommitId: commit },
        executionResult: { externalExecutionId: commit },
      },
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
test("source receipt binds the pipeline execution even when the local agent build ID differs", () => {
  const receipt = sourceReceipt({
    ...environment,
    CODEBUILD_BUILD_ID: "local:00000000-0000-0000-0000-000000000000",
  });
  assert.equal(receipt.pipelineExecutionId, id);
  assert.equal(receipt.commit, commit);
});
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
test("native GitHub commit references and any supplied artifact revision must agree", () => {
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
  c.actions[0].output.executionResult.externalExecutionId = other;
  assert.throws(
    () => linkedExecution(c.execution, c.actions, commit),
    /GITHUB_NATIVE_REVISION_MISMATCH/,
  );
  const d = native();
  assert.equal(
    linkedExecution(d.execution, d.actions, commit).build.output.executionResult
      .externalExecutionId,
    buildId,
  );
});
test("an omitted artifactRevisions field still requires both exact native Source commit references", () => {
  const a = native();
  delete a.execution.artifactRevisions;
  assert.equal(
    linkedExecution(a.execution, a.actions, commit).source,
    a.actions[0],
  );
  for (const change of [
    (output) => {
      output.outputVariables.CommitId = other;
    },
    (output) => {
      delete output.executionResult.externalExecutionId;
    },
  ]) {
    const b = native();
    delete b.execution.artifactRevisions;
    change(b.actions[0].output);
    assert.throws(
      () => linkedExecution(b.execution, b.actions, commit),
      /GITHUB_NATIVE_REVISION_MISMATCH/,
    );
  }
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
function sourceTree() {
  return {
    commit,
    tree: {
      sha: other,
      truncated: false,
      tree: [
        { path: "api", type: "tree", sha: "c".repeat(40) },
        { path: "Dockerfile", type: "blob", sha: "d".repeat(40) },
        { path: "api/server.js", type: "blob", sha: "e".repeat(40) },
      ],
    },
  };
}
function sourceFiles() {
  return {
    files: sourceTree()
      .tree.tree.filter((file) => file.type === "blob")
      .map(({ path, sha }) => ({ path, sha })),
  };
}
test("Source ZIP must contain every GitHub blob exactly once with identical content hashes", () => {
  assert.deepEqual(checkedSourceTree(sourceTree(), sourceFiles(), commit), {
    tree: other,
    files: 2,
    allBlobHashesMatch: true,
  });
  for (const change of [
    (files) => {
      files[0].sha = other;
    },
    (files) => {
      files.pop();
    },
    (files) => {
      files.push({ path: "extra.js", sha: other });
    },
    (files) => {
      files[1] = structuredClone(files[0]);
    },
    (files) => {
      files[0].path = "../Dockerfile";
    },
  ]) {
    const actual = sourceFiles();
    change(actual.files);
    assert.throws(
      () => checkedSourceTree(sourceTree(), actual, commit),
      /GITHUB_SOURCE_TREE_MISMATCH/,
    );
  }
});
test("truncated or unrelated GitHub manifests cannot prove the Source ZIP", () => {
  for (const change of [
    (manifest) => {
      manifest.commit = other;
    },
    (manifest) => {
      manifest.tree.truncated = true;
    },
    (manifest) => {
      manifest.tree.sha = "8089357";
    },
    (manifest) => {
      manifest.tree.tree.push({ path: "module", type: "commit", sha: other });
    },
  ]) {
    const manifest = sourceTree();
    change(manifest);
    assert.throws(
      () => checkedSourceTree(manifest, sourceFiles(), commit),
      /GITHUB_SOURCE_TREE_INVALID/,
    );
  }
});
test("the build receipt must belong to the exact successful native build", () => {
  assert.throws(
    () =>
      checkedBuildArtifact(
        artifact(),
        { id: "cloudtasks-github-build:bbbbbbbb", buildStatus: "SUCCEEDED" },
        delivery,
        repositoryUri,
      ),
    /GITHUB_BUILD_RECEIPT_MISMATCH/,
  );
  assert.throws(
    () =>
      checkedBuildArtifact(
        artifact(),
        { id: buildId, buildStatus: "FAILED" },
        delivery,
        repositoryUri,
      ),
    /GITHUB_BUILD_RECEIPT_MISMATCH/,
  );
  assert.equal(
    checkedBuildArtifact(
      artifact(),
      { id: buildId, buildStatus: "SUCCEEDED" },
      delivery,
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
          delivery,
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
