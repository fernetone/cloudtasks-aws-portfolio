import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { randomUUID, createHash } from "node:crypto";
import {
  distributionConfig,
  assertOwnedDistribution,
  withEnabledDistribution,
} from "./cloudfront-config.mjs";
import {
  aws,
  checkedRuntime,
  gatewayPin,
  requestLocal,
  runtimeRoot,
  LocalOperationError,
  safeErrorCode,
} from "./localstack-tools.mjs";

const requireValue = (v, c) => {
  if (!v) throw new LocalOperationError(c);
};
const metadataFile = path.join(runtimeRoot(), "cloudfront-runtime.json");
const evidenceFile = path.join(runtimeRoot(), "cloudfront-evidence.json");
const hash = (text) => createHash("sha256").update(text).digest("hex");
const mode = process.argv[2];
const proof = {
  scope:
    "functional CloudFront proxy in Docker/LocalStack; AWS edge caching and AWS certificate parity not certified",
  cacheHitsCertified: false,
  checks: [],
  recordedAt: new Date().toISOString(),
};
let runtime;
try {
  requireValue(
    ["create", "status", "test"].includes(mode),
    "USE_CREATE_STATUS_OR_TEST",
  );
  runtime = await checkedRuntime();
  const owner = {
    origin: "cloudtasks-alb.elb.localhost.localstack.cloud",
    alias: "cloudtasks-cdn.localhost.localstack.cloud",
    callerReference:
      "cloudtasks-cdn-" + runtime.localStackContainerId.slice(0, 12),
  };
  const alb = (
    await aws(["elbv2", "describe-load-balancers", "--names", "cloudtasks-alb"])
  ).LoadBalancers?.[0];
  requireValue(
    alb?.DNSName === owner.origin && alb.State?.Code === "active",
    "OWNED_ALB_NOT_ACTIVE",
  );
  let metadata;
  try {
    metadata = JSON.parse(
      (await readFile(metadataFile, "utf8")).replace(/^\uFEFF/, ""),
    );
  } catch (e) {
    if (e.code !== "ENOENT") throw e;
  }
  if (metadata)
    requireValue(
      metadata.localStackContainerId === runtime.localStackContainerId &&
        metadata.alias === owner.alias &&
        metadata.callerReference === owner.callerReference,
      "CLOUDFRONT_RUNTIME_OWNERSHIP_MISMATCH",
    );
  if (mode === "create") {
    const items =
      (await aws(["cloudfront", "list-distributions"])).DistributionList
        ?.Items ?? [];
    const matches = items.filter((d) =>
      d.Aliases?.Items?.includes(owner.alias),
    );
    requireValue(matches.length <= 1, "CLOUDFRONT_ALIAS_AMBIGUOUS");
    let distribution = matches[0];
    if (!distribution) {
      const created = await aws(
        ["cloudfront", "create-distribution-with-tags"],
        {
          DistributionConfigWithTags: {
            DistributionConfig: distributionConfig(owner),
            Tags: {
              Items: [
                { Key: "project", Value: "cloudtasks" },
                { Key: "runtime", Value: runtime.localStackContainerId },
              ],
            },
          },
        },
      );
      distribution = created.Distribution;
    }
    requireValue(
      distribution?.Id && distribution?.ARN,
      "DISTRIBUTION_ID_MISSING",
    );
    const result = await aws([
      "cloudfront",
      "get-distribution-config",
      "--id",
      distribution.Id,
    ]);
    assertOwnedDistribution(result.DistributionConfig, owner);
    const tags =
      (
        await aws([
          "cloudfront",
          "list-tags-for-resource",
          "--resource",
          distribution.ARN,
        ])
      ).Tags?.Items ?? [];
    requireValue(
      tags.some((t) => t.Key === "project" && t.Value === "cloudtasks") &&
        tags.some(
          (t) =>
            t.Key === "runtime" && t.Value === runtime.localStackContainerId,
        ),
      "DISTRIBUTION_TAG_OWNERSHIP_MISMATCH",
    );
    requireValue(
      !metadata || metadata.distributionId === distribution.Id,
      "DISTRIBUTION_ID_CHANGED",
    );
    metadata = {
      schemaVersion: 1,
      ...runtime,
      ...owner,
      distributionId: distribution.Id,
      arn: distribution.ARN,
      domainName: distribution.DomainName,
      createdAt: new Date().toISOString(),
    };
    await writeFile(metadataFile, JSON.stringify(metadata, null, 2) + "\n");
    console.log(
      JSON.stringify({
        createdOrAlreadyOwned: true,
        distributionId: distribution.Id,
        enabled: result.DistributionConfig.Enabled,
        alias: owner.alias,
      }),
    );
  } else {
    requireValue(metadata?.distributionId, "CREATE_CLOUDFRONT_FIRST");
    const load = async () => {
      const result = await aws([
        "cloudfront",
        "get-distribution-config",
        "--id",
        metadata.distributionId,
      ]);
      assertOwnedDistribution(result.DistributionConfig, owner);
      requireValue(
        typeof result.ETag === "string" && result.ETag.length > 0,
        "ETAG_MISSING",
      );
      return { config: result.DistributionConfig, etag: result.ETag };
    };
    const update = async (config, etag) => {
      assertOwnedDistribution(config, owner);
      const result = await aws(
        [
          "cloudfront",
          "update-distribution",
          "--id",
          metadata.distributionId,
          "--if-match",
          etag,
        ],
        { DistributionConfig: config },
      );
      requireValue(typeof result?.ETag === "string", "ETAG_MISSING");
      return result.ETag;
    };
    if (mode === "status") {
      const current = await load();
      console.log(
        JSON.stringify({
          distributionId: metadata.distributionId,
          enabled: current.config.Enabled,
          alias: owner.alias,
          origin: owner.origin,
          cacheHitsCertified: false,
        }),
      );
    } else {
      requireValue(
        metadata.domainName ===
          metadata.distributionId + ".cloudfront.localhost.localstack.cloud",
        "LOCAL_DISTRIBUTION_DOMAIN_REQUIRED",
      );
      const pin = await gatewayPin(),
        origin = "https://" + owner.origin + ":4566",
        cdn = "https://" + metadata.domainName + ":4566";
      const release = await requestLocal(origin + "/release.json", { pin });
      requireValue(release.status === 200, "ALB_RELEASE_NOT_AVAILABLE");
      const identity = JSON.parse(release.text);
      requireValue(
        /^pipeline-[a-f0-9-]{36}$/.test(identity.releaseId) &&
          identity.version === "1.8.2",
        "ALB_RELEASE_ID_INVALID",
      );
      Object.assign(proof, {
        ...runtime,
        distributionId: metadata.distributionId,
        alias: owner.alias,
        origin: owner.origin,
        releaseId: identity.releaseId,
        version: identity.version,
        distributionUrl: cdn,
        alternateAliasTrafficVerified: false,
        tlsGatewayPin: pin,
      });
      await withEnabledDistribution({
        load,
        update,
        probe: async () => {
          const current = await load();
          requireValue(current.config.Enabled, "ENABLED_STATE_NOT_VERIFIED");
          proof.checks.push("enabled-state-read-through-cloudfront-api");
          const health = await requestLocal(cdn + "/health", { pin });
          requireValue(health.status === 200, "CDN_HEALTH_STATUS_FAILED");
          const parsed = JSON.parse(health.text);
          requireValue(
            health.status === 200 &&
              parsed.status === "ok" &&
              parsed.database === "ok",
            "CDN_HEALTH_FAILED",
          );
          const served = await requestLocal(cdn + "/release.json", { pin });
          requireValue(
            served.status === 200 && served.text === release.text,
            "CDN_RELEASE_MISMATCH",
          );
          proof.checks.push("pinned-https-cloudfront-alb-ecs-real-postgresql");
          const index = await requestLocal(cdn + "/", { pin });
          requireValue(
            index.status === 200 && index.text.includes("/assets/"),
            "CDN_HTML_FAILED",
          );
          const assets = [
            ...new Set(
              [
                ...index.text.matchAll(/(?:src|href)="(\/assets\/[^"?#]+)"/g),
              ].map((x) => x[1]),
            ),
          ];
          requireValue(
            assets.length >= 2 && assets.length <= 10,
            "CDN_ASSET_LIST_INVALID",
          );
          proof.assets = [];
          for (const asset of assets) {
            const expected = await requestLocal(origin + asset, { pin }),
              actual = await requestLocal(cdn + asset, { pin });
            requireValue(
              expected.status === 200 &&
                actual.status === 200 &&
                actual.text === expected.text,
              "CDN_ASSET_BYTES_MISMATCH",
            );
            proof.assets.push({
              path: asset,
              sha256: hash(actual.text),
              status: actual.status,
            });
          }
          proof.checks.push("html-javascript-css-match-current-alb-bytes");
          let ownedId;
          try {
            const created = await requestLocal(cdn + "/api/tasks", {
              pin,
              method: "POST",
              body: {
                title: "CloudFront test " + randomUUID(),
                dueDate: "2026-10-10 após as 18h",
                important: false,
              },
            });
            requireValue(created.status === 201, "CDN_CREATE_FAILED");
            ownedId = JSON.parse(created.text).id;
            requireValue(
              /^[a-f0-9-]{36}$/.test(ownedId),
              "CDN_OWNED_ID_INVALID",
            );
            const updated = await requestLocal(cdn + "/api/tasks/" + ownedId, {
              pin,
              method: "PUT",
              body: { important: true, completed: true },
            });
            requireValue(updated.status === 200, "CDN_UPDATE_FAILED");
            const rows = await requestLocal(cdn + "/api/tasks", { pin });
            requireValue(rows.status === 200, "CDN_LIST_FAILED");
            const row = JSON.parse(rows.text).find((t) => t.id === ownedId);
            requireValue(
              row?.important === true &&
                row.completed === true &&
                row.dueDate === "2026-10-10 após as 18h",
              "CDN_DYNAMIC_READ_STALE",
            );
            const shared = await requestLocal(origin + "/api/tasks", { pin });
            requireValue(
              JSON.parse(shared.text).some(
                (t) => t.id === ownedId && t.important && t.completed,
              ),
              "CDN_ALB_DATABASE_NOT_SHARED",
            );
            const removed = await requestLocal(cdn + "/api/tasks/" + ownedId, {
              pin,
              method: "DELETE",
            });
            requireValue(removed.status === 204, "CDN_DELETE_FAILED");
            const finalRows = await requestLocal(cdn + "/api/tasks", { pin });
            requireValue(
              !JSON.parse(finalRows.text).some((t) => t.id === ownedId),
              "CDN_DELETED_ROW_STALE",
            );
            ownedId = undefined;
            proof.ownedTaskDeleted = true;
            proof.checks.push(
              "real-owned-task-crud-through-cdn-shared-with-alb",
            );
          } finally {
            if (ownedId) {
              const cleanup = await requestLocal(
                origin + "/api/tasks/" + ownedId,
                { pin, method: "DELETE" },
              );
              requireValue(
                [204, 404].includes(cleanup.status),
                "OWNED_CDN_TASK_REQUIRES_CLEANUP",
              );
            }
          }
          const plain = await requestLocal(
            cdn.replace("https:", "http:") + "/health",
          );
          proof.httpStatus = plain.status;
          proof.httpRedirectEnforced = [301, 302, 307, 308].includes(
            plain.status,
          );
          requireValue(
            plain.status === 200 || proof.httpRedirectEnforced,
            "CDN_HTTP_UNEXPECTED",
          );
        },
      });
      const final = await load();
      requireValue(!final.config.Enabled, "FINAL_DISABLED_NOT_VERIFIED");
      proof.finalEnabled = false;
      proof.configuration = final.config;
      proof.checks.push("disabled-state-restored-with-etag-and-verified");
      const disabled = await requestLocal(cdn + "/health", { pin });
      proof.disabledHttpsStatus = disabled.status;
      proof.disabledTrafficBlocked = disabled.status !== 200;
      proof.status = "PASSED";
      proof.recordedAt = new Date().toISOString();
      await writeFile(evidenceFile, JSON.stringify(proof, null, 2) + "\n");
      console.log(
        JSON.stringify({
          cloudFrontFunctionalProbePassed: true,
          checks: proof.checks.length,
          distributionId: metadata.distributionId,
          finalEnabled: false,
          httpRedirectEnforced: proof.httpRedirectEnforced,
          disabledTrafficBlocked: proof.disabledTrafficBlocked,
          cacheHitsCertified: false,
        }),
      );
    }
  }
} catch (error) {
  proof.status = "FAILED";
  proof.error = safeErrorCode(error);
  proof.recordedAt = new Date().toISOString();
  if (runtime)
    await writeFile(evidenceFile, JSON.stringify(proof, null, 2) + "\n");
  console.error("CLOUDFRONT_CHECK_FAILED=" + proof.error);
  process.exitCode = 1;
}
