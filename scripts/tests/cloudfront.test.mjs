import assert from "node:assert/strict";
import test from "node:test";
import {
  safeErrorCode,
  LocalOperationError,
} from "../localstack/localstack-tools.mjs";
import {
  distributionConfig,
  assertOwnedDistribution,
  withEnabledDistribution,
} from "../localstack/cloudfront-config.mjs";

const owner = {
  origin: "cloudtasks-alb.elb.localhost.localstack.cloud",
  alias: "cloudtasks-cdn.localhost.localstack.cloud",
  callerReference: "cloudtasks-cdn-87dbf59bfa79",
};

test("distribution starts Disabled and only immutable assets declare caching", () => {
  const c = distributionConfig(owner);
  assert.equal(c.Enabled, false);
  assert.equal(c.DefaultCacheBehavior.MinTTL, 0);
  assert.equal(c.DefaultCacheBehavior.DefaultTTL, 0);
  assert.equal(c.DefaultCacheBehavior.MaxTTL, 0);
  assert.deepEqual(c.DefaultCacheBehavior.AllowedMethods.Items, [
    "GET",
    "HEAD",
    "OPTIONS",
    "PUT",
    "PATCH",
    "POST",
    "DELETE",
  ]);
  assert.equal(c.CacheBehaviors.Quantity, 1);
  assert.equal(c.CacheBehaviors.Items[0].PathPattern, "/assets/*");
  assert.ok(c.CacheBehaviors.Items[0].DefaultTTL > 0);
  assert.equal(c.DefaultCacheBehavior.ForwardedValues.QueryString, true);
  assert.ok(
    !c.DefaultCacheBehavior.ForwardedValues.Headers.Items.includes("Host"),
  );
  assertOwnedDistribution(c, owner);
});

test("foreign origins, aliases and caller references cannot be used", () => {
  for (const mutation of [
    { origin: "example.com" },
    { origin: "cloudtasks-alb.elb.localhost.localstack.cloud.evil.invalid" },
    { alias: "cdn.formacaoaws.com.br" },
    { callerReference: "foreign" },
  ])
    assert.throws(() => distributionConfig({ ...owner, ...mutation }));
  for (const mutate of [
    (c) => (c.CallerReference = "foreign"),
    (c) => (c.Aliases.Items = ["foreign.localhost.localstack.cloud"]),
    (c) => (c.Origins.Items[0].DomainName = "example.com"),
    (c) => (c.Origins.Items[0].CustomOriginConfig.HTTPPort = 80),
  ]) {
    const c = distributionConfig(owner);
    mutate(c);
    assert.throws(() => assertOwnedDistribution(c, owner));
  }
});

test("dynamic caching and viewer Host forwarding fail closed", () => {
  for (const mutate of [
    (c) => (c.DefaultCacheBehavior.MinTTL = 1),
    (c) => (c.DefaultCacheBehavior.MaxTTL = 1),
    (c) => c.DefaultCacheBehavior.ForwardedValues.Headers.Items.push("Host"),
    (c) => (c.DefaultCacheBehavior.ForwardedValues.QueryString = false),
    (c) => (c.DefaultCacheBehavior.AllowedMethods.Items = ["GET", "HEAD"]),
    (c) =>
      c.CacheBehaviors.Items.unshift({
        ...c.CacheBehaviors.Items[0],
        PathPattern: "/api/*",
      }),
  ]) {
    const c = distributionConfig(owner);
    mutate(c);
    assert.throws(() => assertOwnedDistribution(c, owner));
  }
});

function adapter({
  failProbe = false,
  lostUpdate = false,
  concurrent = false,
} = {}) {
  let config = distributionConfig(owner),
    etag = 1,
    updates = [];
  return {
    updates,
    load: async () => ({ config: structuredClone(config), etag: String(etag) }),
    update: async (c, tag) => {
      assert.equal(tag, String(etag));
      config = structuredClone(c);
      etag++;
      updates.push(c.Enabled);
      if (lostUpdate && c.Enabled) throw Error("response lost");
      return String(etag);
    },
    probe: async () => {
      assert.equal(config.Enabled, true);
      if (concurrent) {
        config.Comment = "Changed by another operator";
        etag++;
      }
      if (failProbe) throw Error("probe failed");
      return "proved";
    },
  };
}

test("successful traffic probe restores Disabled with the latest ETag", async () => {
  const a = adapter();
  assert.equal(await withEnabledDistribution(a), "proved");
  assert.deepEqual(a.updates, [true, false]);
  assert.equal((await a.load()).config.Enabled, false);
});

test("failed traffic probe still restores Disabled", async () => {
  const a = adapter({ failProbe: true });
  await assert.rejects(withEnabledDistribution(a), /probe failed/);
  assert.deepEqual(a.updates, [true, false]);
  assert.equal((await a.load()).config.Enabled, false);
});

test("an ambiguous enable response retains state and requires recovery", async () => {
  const a = adapter({ lostUpdate: true });
  await assert.rejects(
    withEnabledDistribution(a),
    /ENABLE_RESPONSE_AMBIGUOUS_REQUIRES_RECOVERY/,
  );
  assert.deepEqual(a.updates, [true]);
  assert.equal((await a.load()).config.Enabled, true);
});

test("a concurrent configuration change is preserved and requires recovery", async () => {
  const a = adapter({ concurrent: true });
  await assert.rejects(
    withEnabledDistribution(a),
    /CONCURRENT_CONFIGURATION_CHANGE/,
  );
  assert.deepEqual(a.updates, [true]);
  assert.equal((await a.load()).config.Comment, "Changed by another operator");
});

test("an already enabled distribution is not disabled by a test", async () => {
  const c = distributionConfig(owner);
  c.Enabled = true;
  let writes = 0;
  await assert.rejects(
    withEnabledDistribution({
      load: async () => ({ config: c, etag: "1" }),
      update: async () => writes++,
      probe: async () => {},
    }),
    /DISABLED_DISTRIBUTION_REQUIRED/,
  );
  assert.equal(writes, 0);
});

test("an enable rejected by ETag never disables a concurrent unmarked enable", async () => {
  let config = distributionConfig(owner),
    etag = 1;
  const updates = [];
  await assert.rejects(
    withEnabledDistribution({
      load: async () => ({
        config: structuredClone(config),
        etag: String(etag),
      }),
      update: async (c, tag) => {
        updates.push(c.Enabled);
        if (c.Enabled) {
          config = { ...distributionConfig(owner), Enabled: true };
          etag++;
          throw Error("PRECONDITION_FAILED");
        }
        assert.equal(tag, String(etag));
        config = c;
      },
      probe: async () => assert.fail("own probe must not run"),
    }),
  );
  assert.equal(config.Enabled, true);
  assert.deepEqual(updates, [true]);
});

test("confirmed enable cannot overwrite a later enable that retains the marker", async () => {
  let config = distributionConfig(owner),
    etag = 1;
  const updates = [];
  await assert.rejects(
    withEnabledDistribution({
      load: async () => ({
        config: structuredClone(config),
        etag: String(etag),
      }),
      update: async (c, tag) => {
        assert.equal(tag, String(etag));
        config = c;
        etag++;
        updates.push(c.Enabled);
        return String(etag);
      },
      probe: async () => {
        config.Enabled = false;
        etag++;
        config.Enabled = true;
        etag++;
      },
    }),
    /CONCURRENT_CONFIGURATION_CHANGE/,
  );
  assert.deepEqual(updates, [true]);
  assert.equal(config.Enabled, true);
});

test("unexpected JSON and filesystem errors cannot serialize private messages", () => {
  const canary = "private-canary-20261010";
  assert.equal(safeErrorCode(new SyntaxError(canary)), "INVALID_JSON");
  assert.equal(
    safeErrorCode(Object.assign(new Error(canary), { code: "ENOENT" })),
    "LOCAL_FILESYSTEM_FAILED/ENOENT",
  );
  assert.equal(safeErrorCode(new Error(canary)), "UNEXPECTED_LOCAL_ERROR");
  assert.equal(
    safeErrorCode(new LocalOperationError("CDN_HEALTH_FAILED")),
    "CDN_HEALTH_FAILED",
  );
});
