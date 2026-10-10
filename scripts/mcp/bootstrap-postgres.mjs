import { randomBytes } from "node:crypto";
import { toolRoot, readonlyRole, readonlySecret } from "./mcp-config.mjs";
import {
  runtime,
  localAws,
  database,
  packageRequire,
  save,
  safeCode,
} from "./mcp-runtime.mjs";
let admin, reader;
try {
  const context = await runtime(),
    source = await database("cloudtasks/database", context),
    { Client } = packageRequire("pg");
  const marker = "CloudTasks MCP readonly " + context.localStackContainerId;
  if (source.value.username !== "cloudtasks_admin")
    throw Error("MCP_ADMIN_SCOPE_INVALID");
  const tags = [
    { Key: "project", Value: "cloudtasks" },
    { Key: "runtime", Value: context.localStackContainerId },
  ];
  let metadata;
  try {
    metadata = await localAws([
      "secretsmanager",
      "describe-secret",
      "--secret-id",
      readonlySecret,
    ]);
  } catch (e) {
    if (e.message !== "MCP_AWS_FAILED/ResourceNotFoundException") throw e;
  }
  let credential;
  if (metadata) {
    if (
      !tags.every((t) =>
        metadata.Tags?.some((x) => x.Key === t.Key && x.Value === t.Value),
      )
    )
      throw Error("MCP_SECRET_FOREIGN");
    credential = (await database(readonlySecret, context)).value;
    if (
      credential.username !== readonlyRole ||
      credential.host !== source.value.host ||
      credential.port !== source.value.port ||
      credential.runtime !== context.localStackContainerId ||
      !/^[a-f0-9]{64}$/.test(credential.password)
    )
      throw Error("MCP_SECRET_OWNERSHIP_INVALID");
  } else {
    credential = {
      ...source.value,
      username: readonlyRole,
      password: randomBytes(32).toString("hex"),
      runtime: context.localStackContainerId,
    };
    await localAws(["secretsmanager", "create-secret"], {
      Name: readonlySecret,
      SecretString: JSON.stringify(credential),
      Tags: tags,
    });
  }
  admin = new Client(source.connection);
  await admin.connect();
  const snapshot = async () =>
    (
      await admin.query(
        "SELECT count(*)::int AS count,md5(coalesce(jsonb_agg(to_jsonb(t) ORDER BY t.id),'[]'::jsonb)::text) AS fingerprint FROM public.tasks t",
      )
    ).rows[0];
  const before = await snapshot();
  await admin.query("BEGIN");
  try {
    await admin.query(
      "SELECT pg_advisory_xact_lock(hashtext('cloudtasks'),hashtext('mcp-role'))",
    );
    const existing = (
      await admin.query(
        "SELECT oid,shobj_description(oid,'pg_authid') AS comment FROM pg_roles WHERE rolname=$1",
        [readonlyRole],
      )
    ).rows[0];
    if (existing && existing.comment !== marker)
      throw Error("MCP_DATABASE_ROLE_FOREIGN");
    if (
      existing &&
      (
        await admin.query(
          "SELECT count(*)::int AS count FROM pg_auth_members WHERE member=$1",
          [existing.oid],
        )
      ).rows[0].count !== 0
    )
      throw Error("MCP_DATABASE_ROLE_MEMBERSHIP_FOREIGN");
    if (!existing) {
      await admin.query(
        "CREATE ROLE " +
          readonlyRole +
          " LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS",
      );
      await admin.query(
        "COMMENT ON ROLE " + readonlyRole + " IS '" + marker + "'",
      );
    }
    await admin.query(
      "ALTER ROLE " +
        readonlyRole +
        " LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS PASSWORD '" +
        credential.password +
        "'",
    );
    await admin.query(
      "REVOKE ALL PRIVILEGES ON DATABASE cloudtasks FROM " + readonlyRole,
    );
    await admin.query(
      "GRANT CONNECT ON DATABASE cloudtasks TO " + readonlyRole,
    );
    await admin.query(
      "REVOKE ALL PRIVILEGES ON SCHEMA public FROM " + readonlyRole,
    );
    await admin.query("GRANT USAGE ON SCHEMA public TO " + readonlyRole);
    await admin.query(
      "REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM " +
        readonlyRole,
    );
    await admin.query(
      "GRANT SELECT ON ALL TABLES IN SCHEMA public TO " + readonlyRole,
    );
    await admin.query(
      "ALTER DEFAULT PRIVILEGES FOR ROLE cloudtasks_admin IN SCHEMA public GRANT SELECT ON TABLES TO " +
        readonlyRole,
    );
    await admin.query(
      "ALTER ROLE " + readonlyRole + " SET default_transaction_read_only = on",
    );
    await admin.query("COMMIT");
  } catch (e) {
    await admin.query("ROLLBACK");
    throw e;
  }
  reader = new Client((await database(readonlySecret, context)).connection);
  await reader.connect();
  const privileges = (
    await reader.query(
      "SELECT current_user AS role,has_table_privilege(current_user,'public.tasks','SELECT') AS can_select,has_table_privilege(current_user,'public.tasks','INSERT') AS can_insert,has_table_privilege(current_user,'public.tasks','UPDATE') AS can_update,has_table_privilege(current_user,'public.tasks','DELETE') AS can_delete",
    )
  ).rows[0];
  if (
    privileges.role !== readonlyRole ||
    !privileges.can_select ||
    privileges.can_insert ||
    privileges.can_update ||
    privileges.can_delete
  )
    throw Error("MCP_READONLY_PRIVILEGES_INVALID");
  await reader.query("SET default_transaction_read_only = off");
  let writeDenied = false,
    writeDenialSqlState;
  try {
    await reader.query("UPDATE public.tasks SET title=title WHERE false");
  } catch (e) {
    writeDenialSqlState = e.code;
    writeDenied = e.code === "42501";
  }
  if (!writeDenied) throw Error("MCP_DATABASE_WRITE_NOT_DENIED");
  const after = await snapshot();
  if (JSON.stringify(before) !== JSON.stringify(after))
    throw Error("MCP_TASK_DATA_CHANGED");
  await save(toolRoot + "/postgres-bootstrap-evidence.json", {
    schemaVersion: 1,
    status: "PASSED",
    ...context,
    role: readonlyRole,
    secretName: readonlySecret,
    credentialsStoredInRuntimeSecretOnly: true,
    secretRequestPrivateTemporaryFileRemoved: true,
    privileges,
    databasePermissionDenialVerified: writeDenied,
    writeDenialSqlState,
    before,
    after,
    recordedAt: new Date().toISOString(),
  });
  console.log("MCP_POSTGRES_ROLE_AND_DATA_PRESERVATION_ACCEPTED");
} catch (e) {
  console.error(safeCode(e));
  process.exitCode = 1;
} finally {
  await reader?.end();
  await admin?.end();
}
