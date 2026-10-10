import { randomUUID } from "node:crypto";
import { LocalOperationError } from "./localstack-tools.mjs";

const ORIGIN = "cloudtasks-alb.elb.localhost.localstack.cloud";
const ALIAS = "cloudtasks-cdn.localhost.localstack.cloud";
const METHODS = ["GET", "HEAD", "OPTIONS", "PUT", "PATCH", "POST", "DELETE"];
const requireValue = (value, code) => {
  if (!value) throw new LocalOperationError(code);
};
const equalSet = (a, b) =>
  JSON.stringify([...(a ?? [])].sort()) === JSON.stringify([...b].sort());

export function distributionConfig({ origin, alias, callerReference }) {
  requireValue(
    origin === ORIGIN &&
      alias === ALIAS &&
      /^cloudtasks-cdn-[a-f0-9]{12}$/.test(callerReference),
    "LOCAL_OWNED_ORIGIN_REQUIRED",
  );
  const behavior = {
    TargetOriginId: "cloudtasks-alb",
    ViewerProtocolPolicy: "redirect-to-https",
    TrustedSigners: { Enabled: false, Quantity: 0 },
    AllowedMethods: {
      Quantity: 7,
      Items: METHODS,
      CachedMethods: { Quantity: 2, Items: ["GET", "HEAD"] },
    },
    ForwardedValues: {
      QueryString: true,
      Cookies: { Forward: "none" },
      Headers: { Quantity: 1, Items: ["Content-Type"] },
    },
    MinTTL: 0,
    DefaultTTL: 0,
    MaxTTL: 0,
    Compress: true,
  };
  return {
    CallerReference: callerReference,
    Aliases: { Quantity: 1, Items: [alias] },
    DefaultRootObject: "index.html",
    Origins: {
      Quantity: 1,
      Items: [
        {
          Id: "cloudtasks-alb",
          DomainName: origin,
          OriginPath: "",
          CustomOriginConfig: {
            HTTPPort: 4566,
            HTTPSPort: 4566,
            OriginProtocolPolicy: "http-only",
            OriginSslProtocols: { Quantity: 1, Items: ["TLSv1.2"] },
          },
        },
      ],
    },
    DefaultCacheBehavior: behavior,
    CacheBehaviors: {
      Quantity: 1,
      Items: [
        {
          ...structuredClone(behavior),
          PathPattern: "/assets/*",
          AllowedMethods: {
            Quantity: 3,
            Items: ["GET", "HEAD", "OPTIONS"],
            CachedMethods: { Quantity: 2, Items: ["GET", "HEAD"] },
          },
          ForwardedValues: {
            QueryString: false,
            Cookies: { Forward: "none" },
            Headers: { Quantity: 0 },
          },
          MinTTL: 0,
          DefaultTTL: 86400,
          MaxTTL: 31536000,
        },
      ],
    },
    Comment: "BIA / CloudTasks - CloudFront local; reference state Disabled",
    Enabled: false,
    ViewerCertificate: { CloudFrontDefaultCertificate: true },
    Restrictions: { GeoRestriction: { RestrictionType: "none", Quantity: 0 } },
    PriceClass: "PriceClass_100",
    HttpVersion: "http2",
    IsIPV6Enabled: false,
  };
}

export function assertOwnedDistribution(config, owner) {
  const expected = distributionConfig(owner);
  requireValue(
    config.CallerReference === expected.CallerReference &&
      config.Aliases?.Quantity === 1 &&
      equalSet(config.Aliases.Items, [owner.alias]),
    "DISTRIBUTION_OWNERSHIP_MISMATCH",
  );
  const origin = config.Origins?.Items?.[0];
  requireValue(
    config.Origins?.Quantity === 1 &&
      config.Origins.Items.length === 1 &&
      origin.Id === "cloudtasks-alb" &&
      origin.DomainName === owner.origin &&
      (origin.OriginPath ?? "") === "" &&
      origin.CustomOriginConfig?.HTTPPort === 4566 &&
      origin.CustomOriginConfig.HTTPSPort === 4566 &&
      origin.CustomOriginConfig.OriginProtocolPolicy === "http-only",
    "DISTRIBUTION_ORIGIN_MISMATCH",
  );
  const b = config.DefaultCacheBehavior;
  requireValue(
    b?.TargetOriginId === "cloudtasks-alb" &&
      b.ViewerProtocolPolicy === "redirect-to-https" &&
      b.MinTTL === 0 &&
      b.DefaultTTL === 0 &&
      b.MaxTTL === 0 &&
      b.AllowedMethods?.Quantity === 7 &&
      equalSet(b.AllowedMethods.Items, METHODS) &&
      b.ForwardedValues?.QueryString === true &&
      b.ForwardedValues.Cookies?.Forward === "none" &&
      equalSet(b.ForwardedValues.Headers?.Items, ["Content-Type"]),
    "DYNAMIC_CACHE_BEHAVIOR_UNSAFE",
  );
  const a = config.CacheBehaviors?.Items;
  requireValue(
    config.CacheBehaviors?.Quantity === 1 &&
      a?.length === 1 &&
      a[0].PathPattern === "/assets/*" &&
      a[0].TargetOriginId === "cloudtasks-alb" &&
      a[0].ViewerProtocolPolicy === "redirect-to-https" &&
      a[0].MinTTL === 0 &&
      a[0].DefaultTTL === 86400 &&
      a[0].MaxTTL === 31536000 &&
      equalSet(a[0].AllowedMethods?.Items, ["GET", "HEAD", "OPTIONS"]) &&
      a[0].ForwardedValues?.QueryString === false &&
      a[0].ForwardedValues.Cookies?.Forward === "none" &&
      (a[0].ForwardedValues.Headers?.Quantity ?? 0) === 0,
    "ASSET_CACHE_BEHAVIOR_MISMATCH",
  );
  requireValue(
    config.ViewerCertificate?.CloudFrontDefaultCertificate === true &&
      typeof config.Enabled === "boolean",
    "VIEWER_CERTIFICATE_MISMATCH",
  );
  return config;
}

function fingerprint(config) {
  const copy = structuredClone(config);
  delete copy.Enabled;
  return JSON.stringify(copy);
}

export async function withEnabledDistribution({ load, update, probe }) {
  const initial = await load();
  requireValue(
    initial.config.Enabled === false,
    "DISABLED_DISTRIBUTION_REQUIRED",
  );
  // This marker identifies the invocation even when the response is lost.
  // An ETag by itself cannot identify who activated the distribution.
  const marked = {
    ...initial.config,
    Comment: "cloudtasks-probe-" + randomUUID(),
    Enabled: true,
  };
  let activationEtag;
  try {
    activationEtag = await update(marked, initial.etag);
    requireValue(
      typeof activationEtag === "string" && activationEtag !== initial.etag,
      "ENABLE_ETAG_NOT_VERIFIED",
    );
    return await probe();
  } finally {
    const current = await load();
    const alreadyOriginal =
      JSON.stringify(current.config) === JSON.stringify(initial.config);
    if (!alreadyOriginal) {
      requireValue(
        fingerprint(current.config) === fingerprint(marked),
        "CONCURRENT_CONFIGURATION_CHANGE_REQUIRES_RECOVERY",
      );
      requireValue(
        typeof activationEtag === "string",
        "ENABLE_RESPONSE_AMBIGUOUS_REQUIRES_RECOVERY",
      );
      requireValue(
        current.etag === activationEtag,
        "CONCURRENT_CONFIGURATION_CHANGE_REQUIRES_RECOVERY",
      );
      await update({ ...initial.config, Enabled: false }, current.etag);
    }
    const final = await load();
    requireValue(
      final.config.Enabled === false &&
        fingerprint(final.config) === fingerprint(initial.config),
      "DISABLED_RESTORATION_NOT_VERIFIED",
    );
  }
}
