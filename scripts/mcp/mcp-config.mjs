// Python imports must stay on the native container filesystem. The Windows
// bind mount under /var/lib/localstack makes startup exceed MCP deadlines.
export const toolRoot = "/opt/cloudtasks-mcp-tools";
export const readonlyRole = "cloudtasks_mcp_readonly";
export const readonlySecret = "cloudtasks/mcp-postgres";
export function mcpEnvironment(inherited = process.env) {
  const result = {};
  for (const name of [
    "PATH",
    "HOME",
    "LANG",
    "LC_ALL",
    "TMPDIR",
    "TEMP",
    "TMP",
    "LD_LIBRARY_PATH",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
  ])
    if (inherited[name]) result[name] = inherited[name];
  return {
    ...result,
    AWS_ACCESS_KEY_ID: "test",
    AWS_SECRET_ACCESS_KEY: "test",
    AWS_REGION: "us-east-1",
    AWS_DEFAULT_REGION: "us-east-1",
    AWS_ENDPOINT_URL: "http://127.0.0.1:4566",
    AWS_CONFIG_FILE: "/dev/null",
    AWS_SHARED_CREDENTIALS_FILE: "/dev/null",
    AWS_EC2_METADATA_DISABLED: "true",
    ALLOW_WRITE: "false",
    ALLOW_SENSITIVE_DATA: "false",
    FASTMCP_LOG_LEVEL: "ERROR",
    FASTMCP_LOG_FILE: toolRoot + "/ecs.private.log",
  };
}
export function checkedMcpRuntime(value) {
  if (
    !/^[a-f0-9]{64}$/.test(value.localStackContainerId) ||
    !/^cloudtasks-cluster(?:-r[0-9]{17})?$/.test(value.cluster) ||
    value.service !== "cloudtasks-service" ||
    !/^cloudtasks-postgres(?:-r[0-9]{17})?$/.test(value.dbIdentifier)
  )
    throw Error("MCP_RUNTIME_INVALID");
  return {
    localStackContainerId: value.localStackContainerId,
    cluster: value.cluster,
    service: value.service,
    dbIdentifier: value.dbIdentifier,
  };
}
export function checkedDatabase(value, runtime, instance) {
  if (
    instance?.DBInstanceIdentifier !== runtime.dbIdentifier ||
    instance?.DBInstanceStatus !== "available" ||
    ![
      value.host === "localhost.localstack.cloud",
      value.host?.endsWith(".localhost.localstack.cloud"),
    ].some(Boolean) ||
    value.host !== instance?.Endpoint?.Address ||
    value.port !== instance?.Endpoint?.Port ||
    !Number.isInteger(value.port) ||
    value.port < 1024 ||
    value.port > 65535 ||
    value.dbname !== "cloudtasks" ||
    value.dbInstanceIdentifier !== runtime.dbIdentifier ||
    typeof value.password !== "string" ||
    value.password.length < 8 ||
    !["cloudtasks_admin", readonlyRole].includes(value.username)
  )
    throw Error("MCP_DATABASE_SCOPE_INVALID");
  return {
    host: value.host,
    port: value.port,
    database: value.dbname,
    dbname: value.dbname,
    user: value.username,
    username: value.username,
    password: value.password,
    connectionTimeoutMillis: 10000,
  };
}
export function biaAgent(location = "host") {
  if (!["host", "container"].includes(location))
    throw Error("MCP_AGENT_LOCATION_INVALID");
  const server = (file) =>
    location === "host"
      ? {
          command: "docker",
          args: [
            "exec",
            "-i",
            "cloudtasks-localstack",
            "node",
            toolRoot + "/project/scripts/mcp/" + file,
          ],
          timeout: 120000,
        }
      : {
          command: "node",
          args: [toolRoot + "/project/scripts/mcp/" + file],
          timeout: 120000,
        };
  const tools = ["@ecs/ecs_resource_management", "@postgres/query"];
  return {
    name: "bia",
    description: "BIA: consultas reais ao ECS e PostgreSQL do projeto local",
    prompt:
      "Responda em português. Use os MCPs ECS e PostgreSQL para verificar o estado real da BIA. O ambiente autorizado é Docker/LocalStack, conta local 000000000000, região us-east-1. Consulte os clusters e o serviço cloudtasks-service e consulte o schema/contagens do banco cloudtasks. Não invente resultados ou paridade AWS. Use somente leitura. Não solicite segredos, não divulgue variáveis de ambiente e não altere recursos ou dados.",
    mcpServers: {
      ecs: server("ecs-stdio.mjs"),
      postgres: server("postgres-stdio.mjs"),
    },
    tools,
    allowedTools: tools,
    useLegacyMcpJson: false,
  };
}
