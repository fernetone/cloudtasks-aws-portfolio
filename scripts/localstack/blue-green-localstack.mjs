import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import http from 'node:http';
import https from 'node:https';
import { tmpdir } from 'node:os';
import path from 'node:path';
import tls from 'node:tls';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { deployBlueGreen, DeploymentError, errorCode } from './blue-green-controller.mjs';

const execute = promisify(execFile);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const release = /^pipeline-[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
const requireCheck = (ok, code) => { if (!ok) throw new DeploymentError(code); };
function json(text, code = 'INVALID_JSON') {
  try { return JSON.parse(text); } catch { throw new DeploymentError(code); }
}
export function awsOutput(text) { return text.trim() ? json(text) : {}; }
export function taskDockerIdentity(text, cluster, taskId) {
  const rows = text.trim().split(/\r?\n/).filter(Boolean);
  requireCheck(rows.length === 1, 'TASK_DOCKER_COUNT');
  const fields = rows[0].trim().split(/\s+/);
  requireCheck(fields.length === 2 && /^[a-f0-9]{64}$/.test(fields[0]) &&
    fields[1].startsWith('ls-ecs-' + cluster + '-' + taskId + '-'), 'TASK_DOCKER_IDENTITY');
  return fields[0];
}

export function validateLocalConfig(env) {
  let endpoint;
  try { endpoint = new URL(env.AWS_ENDPOINT_URL); } catch { throw new DeploymentError('LOCALSTACK_ENDPOINT_REQUIRED'); }
  requireCheck(endpoint.protocol === 'http:' && endpoint.hostname === 'cloudtasks-localstack' && endpoint.port === '4566' && endpoint.pathname === '/' && !endpoint.username && !endpoint.password && !endpoint.search && !endpoint.hash, 'LOCALSTACK_ENDPOINT_REQUIRED');
  requireCheck(/^cloudtasks-cluster(?:-r[0-9]{17})?$/.test(env.BG_CLUSTER || '') && env.BG_SERVICE === 'cloudtasks-service', 'CLOUDTASKS_RUNTIME_REQUIRED');
  requireCheck(uuid.test(env.BG_EXECUTION_ID || ''), 'PIPELINE_EXECUTION_ID_REQUIRED');
  requireCheck(/^[a-fA-F0-9]{64}$/.test(env.LOCALSTACK_TLS_CERT_SHA256 || ''), 'TLS_PIN_REQUIRED');
  const bakeSeconds = Number(env.BG_BAKE_SECONDS || 60);
  requireCheck(Number.isInteger(bakeSeconds) && bakeSeconds >= 60 && bakeSeconds <= 600, 'BAKE_RANGE');
  const scenario = env.BG_SCENARIO || 'Normal';
  requireCheck(['Normal', 'RejectCandidate', 'Rollback'].includes(scenario), 'SCENARIO_INVALID');
  const agentBuildId = /^[a-zA-Z0-9_.:-]{1,200}$/.test(env.CODEBUILD_BUILD_ID || '') ? env.CODEBUILD_BUILD_ID : null;
  return { endpoint: endpoint.origin, cluster: env.BG_CLUSTER, service: env.BG_SERVICE, executionId: env.BG_EXECUTION_ID, agentBuildId, tlsPin: env.LOCALSTACK_TLS_CERT_SHA256.toLowerCase(), bakeSeconds, scenario, bucket: 'cloudtasks-pipeline-artifacts' };
}

export function readImageDefinition(text, repository) {
  const data = json(text);
  requireCheck(Array.isArray(data) && data.length === 1 && data[0].name === 'cloudtasks-app', 'IMAGE_ARTIFACT_INVALID');
  const image = data[0].imageUri;
  requireCheck(typeof image === 'string' && image.startsWith(repository + ':') && release.test(image.slice(repository.length + 1)), 'IMAGE_ARTIFACT_INVALID');
  return { image, releaseId: image.slice(repository.length + 1) };
}

export function healthPayload(status, text) {
  requireCheck(status === 200, 'APP_HEALTH_HTTP');
  const body = json(text, 'APP_HEALTH_PAYLOAD');
  requireCheck(body?.status === 'ok' && body?.database === 'ok', 'APP_DATABASE_HEALTH');
  return body;
}

export function checkIdentity(expected, actual) {
  requireCheck(expected.releaseId === actual.releaseId && expected.bundleSha256 === actual.bundleSha256, 'CANDIDATE_IDENTITY_MISMATCH');
}

export function copyDefinition(td, image, family) {
  requireCheck(td.networkMode === 'bridge' && td.containerDefinitions?.length === 1 && td.containerDefinitions[0].name === 'cloudtasks-app', 'BRIDGE_APP_DEFINITION_REQUIRED');
  const result = {};
  for (const key of ['taskRoleArn', 'executionRoleArn', 'containerDefinitions', 'volumes', 'placementConstraints', 'requiresCompatibilities', 'cpu', 'memory', 'runtimePlatform']) {
    if (td[key] !== undefined) result[key] = structuredClone(td[key]);
  }
  Object.assign(result, { family, networkMode: 'bridge' });
  const app = result.containerDefinitions[0];
  app.image = image;
  for (const mapping of app.portMappings || []) mapping.hostPort = 0;
  app.dockerLabels = { ...app.dockerLabels };
  delete app.dockerLabels['cloudtasks.blue-green.execution'];
  if (!Object.keys(app.dockerLabels).length) delete app.dockerLabels;
  return result;
}

export class LocalStackDeployment {
  constructor(config, directory) {
    this.config = config;
    this.directory = directory;
    this.candidateName = 'cloudtasks-candidate-' + config.executionId.slice(0, 8);
    this.groupName = 'ct-bg-' + config.executionId.slice(0, 8) + '-green';
    this.owned = { rules: [], taskIds: [] };
    this.retiredCanonicalArns = new Set();
    this.canonicalChanged = false;
    this.locked = false;
    this.lockKey = 'cloudtasks/blue-green/deploy.lock';
    this.env = { ...process.env, AWS_ACCESS_KEY_ID: 'test', AWS_SECRET_ACCESS_KEY: 'test', AWS_DEFAULT_REGION: 'us-east-1', AWS_EC2_METADATA_DISABLED: 'true', AWS_PAGER: '', DOCKER_HOST: 'unix:///var/run/docker.sock' };
    for (const key of ['AWS_SESSION_TOKEN', 'AWS_PROFILE', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy', 'DOCKER_CONTEXT']) delete this.env[key];
  }

  async command(program, args) {
    try { return (await execute(program, args, { env: this.env, timeout: 40000, maxBuffer: 2 * 1024 * 1024 })).stdout; }
    catch (error) {
      const match = String(error.stderr || '').match(/An error occurred \(([A-Za-z0-9_.-]+)\)/);
      // Never include CLI arguments, provider errors or docker inspect environment.
      throw new DeploymentError(match ? 'AWS_' + match[1].replace(/[^a-zA-Z0-9]/g, '_').toUpperCase() : program === 'docker' ? 'DOCKER_COMMAND_FAILED' : 'AWS_COMMAND_FAILED');
    }
  }
  async aws(service, action, ...args) {
    return awsOutput(await this.command('aws', ['--endpoint-url', this.config.endpoint, '--region', 'us-east-1', service, action, ...args.map(String), '--output', 'json']));
  }
  async docker(...args) { return this.command('docker', args); }
  async file(name, data) { const p = path.join(this.directory, name); await writeFile(p, JSON.stringify(data)); return p; }
  async put(key, data, conditional = false) {
    const file = await this.file('upload.json', data);
    return this.aws('s3api', 'put-object', '--bucket', this.config.bucket, '--key', key, '--body', file, ...(conditional ? ['--if-none-match', '*'] : []));
  }
  async lock() {
    const caller = await this.aws('sts', 'get-caller-identity');
    requireCheck(caller.Account === '000000000000', 'LOCALSTACK_ACCOUNT_REQUIRED');
    const execution = (await this.aws('codepipeline', 'get-pipeline-execution', '--pipeline-name', 'cloudtasks-pipeline', '--pipeline-execution-id', this.config.executionId)).pipelineExecution;
    requireCheck(execution?.status === 'InProgress', 'NATIVE_PIPELINE_NOT_ACTIVE');
    const actions = (await this.aws('codepipeline', 'list-action-executions', '--pipeline-name', 'cloudtasks-pipeline', '--filter', 'pipelineExecutionId=' + this.config.executionId)).actionExecutionDetails;
    const builds = actions.filter(x => x.pipelineExecutionId === this.config.executionId && x.actionName === 'BuildAndPush' && x.status === 'Succeeded');
    requireCheck(builds.length === 1, 'NATIVE_IMAGE_BUILD_NOT_CONFIRMED');
    const imageBuildId = builds[0].output?.executionResult?.externalExecutionId;
    requireCheck(/^cloudtasks-build:[a-zA-Z0-9-]+$/.test(imageBuildId || ''), 'NATIVE_IMAGE_BUILD_NOT_CONFIRMED');
    const build = (await this.aws('codebuild', 'batch-get-builds', '--ids', imageBuildId)).builds?.[0];
    const outputs = builds[0].output?.outputArtifacts?.filter(x => x.name === 'BuildOutput');
    requireCheck(build?.id === imageBuildId && build.buildStatus === 'SUCCEEDED' && outputs?.length === 1, 'NATIVE_IMAGE_BUILD_NOT_CONFIRMED');
    const location = outputs[0].s3location;
    requireCheck(location?.bucket === this.config.bucket && build.artifacts?.location === 'arn:aws:s3:::' + location.bucket + '/' + location.key, 'NATIVE_INPUT_ARTIFACT_MISMATCH');
    await this.put(this.lockKey, { executionId: this.config.executionId }, true);
    this.locked = true;
    // The local agent's reserved ID can be a placeholder. Native provenance is
    // the action/API artifact linkage, also checked independently by PowerShell.
    return { imageBuildId, inputArtifactBucket: location.bucket, inputArtifactKey: location.key };
  }
  async unlock() {
    const file = path.join(this.directory, 'lock.json');
    await this.aws('s3api', 'get-object', '--bucket', this.config.bucket, '--key', this.lockKey, file);
    const owner = json(await readFile(file, 'utf8'));
    requireCheck(owner.executionId === this.config.executionId, 'LOCK_OWNER_MISMATCH');
    await this.aws('s3api', 'delete-object', '--bucket', this.config.bucket, '--key', this.lockKey);
    this.locked = false;
  }
  async save(receipt) {
    const data = { ...receipt, owned: this.owned, recordedAt: new Date().toISOString() };
    await writeFile('deployment-receipt.json', JSON.stringify(data, null, 2) + '\n');
    await this.put('cloudtasks/blue-green/executions/' + this.config.executionId + '/receipt.json', data);
    if (this.locked) await this.put('cloudtasks/blue-green/current.json', data);
    console.log('[Blue/Green] ' + receipt.phases.at(-1) + ' / ' + receipt.status);
  }

  async request(pathname, { tls: secure = false, candidate = false, retainedBlue = false, ip, method = 'GET', body } = {}) {
    const config = this.config;
    const headers = { Host: this.alb.DNSName + ':4566', 'Cache-Control': 'no-cache' };
    if (candidate) headers['X-CloudTasks-Candidate'] = config.executionId;
    if (retainedBlue) headers['X-CloudTasks-Candidate'] = 'blue-' + config.executionId;
    const payload = body === undefined ? undefined : JSON.stringify(body);
    if (payload) { headers['Content-Type'] = 'application/json'; headers['Content-Length'] = Buffer.byteLength(payload); }
    let agent;
    if (secure) {
      agent = new https.Agent();
      agent.createConnection = (options, done) => {
        let completed = false;
        const finish = (err, socket) => { if (!completed) { completed = true; done(err, socket); } };
        const socket = tls.connect({ ...options, servername: this.alb.DNSName, rejectUnauthorized: false });
        socket.once('error', error => finish(error));
        socket.once('secureConnect', () => {
          const certificate = socket.getPeerCertificate();
          if (!certificate.raw || createHash('sha256').update(certificate.raw).digest('hex') !== config.tlsPin) {
            socket.destroy(); finish(new DeploymentError('TLS_PIN_MISMATCH')); return;
          }
          finish(null, socket);
        });
      };
    }
    try {
      return await new Promise((resolve, reject) => {
        let settled = false;
        let deadline;
        const finish = (error, response) => {
          if (settled) return;
          settled = true;
          clearTimeout(deadline);
          if (error) reject(error); else resolve(response);
        };
        const req = (secure ? https : http).request({ hostname: ip || 'cloudtasks-localstack', port: ip ? 3000 : 4566, path: pathname, method, headers, agent }, res => {
          let text = '';
          res.on('data', chunk => {
            text += chunk;
            if (text.length > 2 * 1024 * 1024) { const error = new DeploymentError('HTTP_BODY_LIMIT'); finish(error); req.destroy(error); }
          });
          res.on('aborted', () => finish(new DeploymentError('HTTP_TRANSPORT')));
          res.on('error', () => finish(new DeploymentError('HTTP_TRANSPORT')));
          res.on('close', () => { if (!res.complete) finish(new DeploymentError('HTTP_TRANSPORT')); });
          res.on('end', () => {
            if (!res.complete) finish(new DeploymentError('HTTP_TRANSPORT'));
            else finish(null, { status: res.statusCode, text, type: res.headers['content-type'] || '' });
          });
        });
        deadline = setTimeout(() => { const error = new DeploymentError('HTTP_TIMEOUT'); finish(error); req.destroy(error); }, 8000);
        req.setTimeout(8000, () => req.destroy(new DeploymentError('HTTP_TIMEOUT')));
        req.on('error', error => finish(error instanceof DeploymentError ? error : new DeploymentError('HTTP_TRANSPORT')));
        req.end(payload);
      });
    } finally { agent?.destroy(); }
  }
  async application(options = {}) {
    const h = await this.request('/health', options);
    healthPayload(h.status, h.text);
    const tasks = await this.request('/api/tasks', options);
    requireCheck(tasks.status === 200 && Array.isArray(json(tasks.text)), 'APP_TASKS_GET');
    const index = await this.request('/', options);
    requireCheck(index.status === 200, 'APP_FRONTEND_HTTP');
    const scripts = [...index.text.matchAll(/<script\b[^>]*\bsrc=["']([^"']+\.js)["']/g)];
    requireCheck(scripts.length === 1 && /^\/assets\/[a-zA-Z0-9_.-]+\.js$/.test(scripts[0][1]), 'APP_ASSET_INVALID');
    const bundle = await this.request(scripts[0][1], options);
    requireCheck(bundle.status === 200 && bundle.text.length > 100, 'APP_BUNDLE_HTTP');
    const meta = await this.request('/release.json', options);
    let releaseId = null;
    if (meta.type.includes('application/json')) {
      const value = json(meta.text);
      // The default Docker build is the initial blue release. Candidate
      // acceptance still requires the exact pipeline artifact release below.
      requireCheck(meta.status === 200 && (value.releaseId === 'local' || release.test(value.releaseId || '')), 'APP_RELEASE_INVALID');
      releaseId = value.releaseId;
    } else {
      requireCheck(meta.status === 200 && meta.type.includes('text/html') && meta.text === index.text, 'LEGACY_RELEASE_INVALID');
    }
    return { releaseId, asset: scripts[0][1], bundleSha256: createHash('sha256').update(bundle.text).digest('hex'), health: 'ok', database: 'ok' };
  }
  async physical(arn, image, digest, owned = false) {
    const id = arn.split('/').at(-1);
    requireCheck(uuid.test(id), 'TASK_ID_INVALID');
    const containerId = taskDockerIdentity(await this.docker('ps', '--filter', 'name=' + id, '--filter', 'status=running', '--no-trunc', '--format', '{{.ID}} {{.Names}}'), this.config.cluster, id);
    const format = '{"running":{{json .State.Running}},"health":{{json .State.Health.Status}},"imageId":{{json .Image}},"networks":{{json .NetworkSettings.Networks}}}';
    const data = json(await this.docker('inspect', '--format', format, containerId));
    requireCheck(data.running && data.health === 'healthy', 'TASK_NOT_HEALTHY');
    const digests = json(await this.docker('image', 'inspect', '--format', '{{json .RepoDigests}}', data.imageId));
    requireCheck(digests?.includes(image.slice(0, image.lastIndexOf(':')) + '@' + digest), 'PHYSICAL_IMAGE_MISMATCH');
    const ip = data.networks?.['cloudtasks-localstack-network']?.IPAddress;
    requireCheck(ip && /^172\.[0-9.]+$/.test(ip), 'TASK_NETWORK_INVALID');
    if (owned) requireCheck(this.owned.taskIds.includes(id) && !this.blue.tasks.some(t => t.containerId === containerId), 'CANDIDATE_OWNER_MISMATCH');
    return { taskArn: arn, containerId, imageId: data.imageId, digest, ip, port: 3000, health: 'healthy' };
  }
  async imageDigest(image) {
    requireCheck(image.startsWith(this.repository + ':'), 'REPOSITORY_MISMATCH');
    const tag = image.slice(this.repository.length + 1);
    const result = await this.aws('ecr', 'describe-images', '--repository-name', 'cloudtasks', '--image-ids', 'imageTag=' + tag);
    requireCheck(result.imageDetails?.length === 1 && /^sha256:[a-f0-9]{64}$/.test(result.imageDetails[0].imageDigest), 'ECR_DIGEST_INVALID');
    return result.imageDetails[0].imageDigest;
  }
  async service(name) {
    const data = await this.aws('ecs', 'describe-services', '--cluster', this.config.cluster, '--services', name);
    requireCheck(data.services?.length === 1 && data.services[0].status === 'ACTIVE', 'SERVICE_NOT_ACTIVE');
    return data.services[0];
  }
  async ready(name, definition, image, digest, owned = false, timeout = 240) {
    const deadline = Date.now() + timeout * 1000;
    while (Date.now() < deadline) {
      const s = await this.service(name);
      const arns = (await this.aws('ecs', 'list-tasks', '--cluster', this.config.cluster, '--service-name', name, '--desired-status', 'RUNNING')).taskArns || [];
      if (owned) this.owned.taskIds = [...new Set([...this.owned.taskIds, ...arns.map(x => x.split('/').at(-1))])];
      if (s.desiredCount === 2 && s.runningCount === 2 && s.pendingCount === 0 && arns.length === 2 && s.taskDefinition === definition) {
        const tasks = await this.aws('ecs', 'describe-tasks', '--cluster', this.config.cluster, '--tasks', ...arns);
        requireCheck(tasks.failures?.length === 0 && tasks.tasks?.length === 2 && tasks.tasks.every(t =>
          t.lastStatus === 'RUNNING' && t.taskDefinitionArn === definition && t.group === 'service:' + name &&
          t.clusterArn === 'arn:aws:ecs:us-east-1:000000000000:cluster/' + this.config.cluster), 'TASK_API_MISMATCH');
        try {
          const physical = await Promise.all(arns.map(arn => this.physical(arn, image, digest, owned)));
          requireCheck(new Set(physical.map(x => x.ip)).size === 2, 'REPLICA_IPS_NOT_DISTINCT');
          return physical;
        } catch (error) { if (!['TASK_NOT_HEALTHY', 'TASK_DOCKER_COUNT'].includes(errorCode(error))) throw error; }
      }
      if (owned && this.config.scenario === 'RejectCandidate') {
        const stopped = (await this.aws('ecs', 'list-tasks', '--cluster', this.config.cluster, '--service-name', name, '--desired-status', 'STOPPED')).taskArns || [];
        if (stopped.length) { this.owned.taskIds.push(...stopped.map(x => x.split('/').at(-1))); throw new DeploymentError('CANDIDATE_UNHEALTHY'); }
      }
      await sleep(2000);
    }
    throw new DeploymentError(owned ? 'CANDIDATE_UNHEALTHY' : 'SERVICE_STABILITY_TIMEOUT');
  }
  async syncTargets(group, physical) {
    const current = (await this.aws('elbv2', 'describe-target-health', '--target-group-arn', group)).TargetHealthDescriptions || [];
    const wanted = physical.map(x => ({ Id: x.ip, Port: 3000, AvailabilityZone: 'all' }));
    await this.aws('elbv2', 'register-targets', '--target-group-arn', group, '--targets', JSON.stringify(wanted));
    const stale = current.map(x => x.Target).filter(x => !wanted.some(t => t.Id === x.Id && t.Port === x.Port));
    if (stale.length) await this.aws('elbv2', 'deregister-targets', '--target-group-arn', group, '--targets', JSON.stringify(stale));
    for (let attempt = 0; attempt < 30; attempt++) {
      const rows = (await this.aws('elbv2', 'describe-target-health', '--target-group-arn', group)).TargetHealthDescriptions || [];
      if (rows.length === 2 && rows.every(x => x.TargetHealth.State === 'healthy' && wanted.some(t => t.Id === x.Target.Id && t.Port === x.Target.Port))) return;
      await sleep(2000);
    }
    throw new DeploymentError('TARGETS_NOT_HEALTHY');
  }
  async baseline() {
    this.repository = (await this.aws('ecr', 'describe-repositories', '--repository-names', 'cloudtasks')).repositories[0].repositoryUri;
    this.artifact = readImageDefinition(await readFile(path.join(process.env.CODEBUILD_SRC_DIR || process.cwd(), 'imagedefinitions.json'), 'utf8'), this.repository);
    this.candidateDigest = await this.imageDigest(this.artifact.image);
    const s = await this.service(this.config.service);
    this.originalDefinition = (await this.aws('ecs', 'describe-task-definition', '--task-definition', s.taskDefinition)).taskDefinition;
    this.originalImage = this.originalDefinition.containerDefinitions.find(x => x.name === 'cloudtasks-app')?.image;
    requireCheck(this.originalImage !== this.artifact.image, 'IMAGE_NOT_CHANGED');
    const digest = await this.imageDigest(this.originalImage);
    const tasks = await this.ready(this.config.service, s.taskDefinition, this.originalImage, digest);
    this.alb = (await this.aws('elbv2', 'describe-load-balancers', '--names', 'cloudtasks-alb')).LoadBalancers[0];
    this.mainGroup = (await this.aws('elbv2', 'describe-target-groups', '--names', 'cloudtasks-tg')).TargetGroups[0];
    requireCheck(this.alb.VpcId === this.mainGroup.VpcId && this.mainGroup.TargetType === 'ip', 'LAB_TOPOLOGY_MISMATCH');
    this.listeners = (await this.aws('elbv2', 'describe-listeners', '--load-balancer-arn', this.alb.LoadBalancerArn)).Listeners;
    requireCheck(this.listeners.length === 2 && this.listeners.some(x => x.Protocol === 'HTTP') && this.listeners.some(x => x.Protocol === 'HTTPS'), 'HTTP_HTTPS_REQUIRED');
    for (const listener of this.listeners) {
      requireCheck(listener.DefaultActions.length === 1 && listener.DefaultActions[0].Type === 'forward' && listener.DefaultActions[0].TargetGroupArn === this.mainGroup.TargetGroupArn, 'PRODUCTION_ROUTE_NOT_CANONICAL');
      const rules = (await this.aws('elbv2', 'describe-rules', '--listener-arn', listener.ListenerArn)).Rules;
      requireCheck(!rules.some(x => ['49310', '49311'].includes(String(x.Priority))), 'TEST_RULE_PRIORITY_IN_USE');
    }
    const identity = await this.application();
    checkIdentity(identity, await this.application({ tls: true }));
    for (const task of tasks) checkIdentity(identity, await this.application({ ip: task.ip }));
    this.blue = { definition: s.taskDefinition, image: this.originalImage, digest, ...identity, tasks };
    return this.blue;
  }
  async createCandidate() {
    const definition = copyDefinition(this.originalDefinition, this.artifact.image, 'cloudtasks-candidate');
    const app = definition.containerDefinitions[0];
    app.logConfiguration.options['awslogs-stream-prefix'] = 'bg-' + this.config.executionId;
    if (this.config.scenario === 'RejectCandidate') app.command = ['node', '-e', 'process.exit(42)'];
    this.owned.definition = (await this.aws('ecs', 'register-task-definition', '--cli-input-json', JSON.stringify(definition))).taskDefinition.taskDefinitionArn;
    this.owned.group = (await this.aws('elbv2', 'create-target-group', '--name', this.groupName, '--protocol', 'HTTP', '--port', '3000', '--vpc-id', this.mainGroup.VpcId, '--target-type', 'ip', '--health-check-path', '/health', '--health-check-interval-seconds', '5', '--health-check-timeout-seconds', '3', '--healthy-threshold-count', '2', '--unhealthy-threshold-count', '2')).TargetGroups[0].TargetGroupArn;
    await this.aws('elbv2', 'modify-target-group-attributes', '--target-group-arn', this.owned.group, '--attributes', 'Key=deregistration_delay.timeout_seconds,Value=0');
    for (const listener of this.listeners) {
      // Both groups must stay associated with the ALB. Otherwise switching the
      // default to green makes the canonical group Target.NotInUse, so it cannot
      // become healthy before the final traffic switch or a rollback.
      for (const route of [
        { priority: '49310', value: this.config.executionId, group: this.owned.group },
        { priority: '49311', value: 'blue-' + this.config.executionId, group: this.mainGroup.TargetGroupArn },
      ]) {
        const conditions = [{ Field: 'http-header', HttpHeaderConfig: { HttpHeaderName: 'X-CloudTasks-Candidate', Values: [route.value] } }];
        const rule = await this.aws('elbv2', 'create-rule', '--listener-arn', listener.ListenerArn, '--priority', route.priority, '--conditions', JSON.stringify(conditions), '--actions', JSON.stringify([{ Type: 'forward', TargetGroupArn: route.group }]));
        this.owned.rules.push(rule.Rules[0].RuleArn);
      }
    }
    this.owned.service = (await this.aws('ecs', 'create-service', '--cli-input-json', JSON.stringify({ cluster: this.config.cluster, serviceName: this.candidateName, taskDefinition: this.owned.definition, desiredCount: 2, launchType: 'EC2', deploymentController: { type: 'ECS' }, tags: [{ key: 'cloudtasks:deployment', value: this.config.executionId }] }))).service.serviceArn;
  }
  async validateCandidate() {
    const tasks = await this.ready(this.candidateName, this.owned.definition, this.artifact.image, this.candidateDigest, true);
    const identity = await this.application({ ip: tasks[0].ip });
    requireCheck(identity.releaseId === this.artifact.releaseId, 'CANDIDATE_IDENTITY_MISMATCH');
    for (const task of tasks) checkIdentity(identity, await this.application({ ip: task.ip }));
    await this.syncTargets(this.owned.group, tasks);
    this.green = { definition: this.owned.definition, image: this.artifact.image, digest: this.candidateDigest, ...identity, tasks };
    return this.green;
  }
  async verifyBlue(blue) {
    const s = await this.service(this.config.service);
    const tasks = await this.ready(this.config.service, s.taskDefinition, blue.image, blue.digest);
    if (!this.canonicalChanged) requireCheck(tasks.map(x => x.containerId).sort().join() === blue.tasks.map(x => x.containerId).sort().join(), 'BLUE_REPLACED_TOO_EARLY');
    checkIdentity(blue, await this.application());
    checkIdentity(blue, await this.application({ tls: true }));
    return { physicalHealthy: 2, http: 'blue', https: 'blue', tasks };
  }
  async validateIsolation(blue, green) {
    await this.verifyBlue(blue);
    checkIdentity(green, await this.application({ candidate: true }));
    checkIdentity(green, await this.application({ candidate: true, tls: true }));
    return { productionHttp: 'blue', productionHttps: 'blue', testHttp: 'green', testHttps: 'green' };
  }
  async validateSharedData() {
    const title = 'CloudTasks BG ' + this.config.executionId;
    const created = await this.request('/api/tasks', { method: 'POST', body: { title } });
    requireCheck(created.status === 201, 'CRUD_CREATE_FAILED');
    const task = json(created.text);
    requireCheck(uuid.test(task.id) && task.title === title && task.completed === false, 'CRUD_ID_INVALID');
    try {
      const listed = await this.request('/api/tasks', { candidate: true, tls: true });
      requireCheck(json(listed.text).some(x => x.id === task.id && x.title === title), 'SHARED_DATABASE_READ_FAILED');
      const update = await this.request('/api/tasks/' + task.id, { candidate: true, method: 'PUT', body: { title, completed: true } });
      requireCheck(update.status === 200 && json(update.text).completed === true, 'CRUD_UPDATE_FAILED');
      const blue = await this.request('/api/tasks', { tls: true });
      requireCheck(json(blue.text).some(x => x.id === task.id && x.completed === true), 'SHARED_DATABASE_UPDATE_FAILED');
    } finally {
      const deleted = await this.request('/api/tasks/' + task.id, { method: 'DELETE' });
      requireCheck(deleted.status === 204, 'CRUD_CLEANUP_FAILED');
    }
    return { createBlueReadGreen: true, updateGreenReadBlue: true, ownedTaskDeleted: true };
  }
  async promote(green) {
    for (const listener of this.listeners) await this.aws('elbv2', 'modify-listener', '--listener-arn', listener.ListenerArn, '--default-actions', JSON.stringify([{ Type: 'forward', TargetGroupArn: this.owned.group }]));
    checkIdentity(green, await this.application());
    checkIdentity(green, await this.application({ tls: true }));
    return { http: 'green', https: 'green', releaseId: green.releaseId };
  }
  async observe(blue, green) {
    const start = Date.now();
    const samples = [];
    while (true) {
      const old = await this.ready(this.config.service, blue.definition, blue.image, blue.digest);
      requireCheck(old.map(x => x.containerId).sort().join() === blue.tasks.map(x => x.containerId).sort().join(), 'BLUE_REPLACED_DURING_BAKE');
      await this.ready(this.candidateName, green.definition, green.image, green.digest, true);
      checkIdentity(blue, await this.application({ retainedBlue: true }));
      checkIdentity(blue, await this.application({ retainedBlue: true, tls: true }));
      checkIdentity(green, await this.application());
      checkIdentity(green, await this.application({ tls: true }));
      const seconds = (Date.now() - start) / 1000;
      samples.push({ seconds: Math.round(seconds * 10) / 10, blueHealthy: 2, greenHealthy: 2, blueHttp: 'blue', blueHttps: 'blue', productionRelease: green.releaseId, httpsPinned: true });
      if (this.config.scenario === 'Rollback') throw new DeploymentError('CONTROLLED_BAKE_FAILURE');
      if (seconds >= this.config.bakeSeconds) break;
      await sleep(5000);
    }
    return { requiredSeconds: this.config.bakeSeconds, elapsedSeconds: (Date.now() - start) / 1000, samples };
  }
  async restoreListeners() {
    for (const listener of this.listeners) {
      try { await this.aws('elbv2', 'modify-listener', '--listener-arn', listener.ListenerArn, '--default-actions', JSON.stringify(listener.DefaultActions)); }
      catch { /* A lost response may still have restored this listener. Try both. */ }
    }
    try { await this.verifyProductionRoutes(this.mainGroup.TargetGroupArn, 'LISTENER_RESTORE_INCOMPLETE'); }
    catch { throw new DeploymentError('LISTENER_RESTORE_INCOMPLETE'); }
  }
  async verifyProductionRoutes(group, code) {
    requireCheck(this.listeners.length === 2 && typeof group === 'string' && group.length > 0, code);
    const result = await this.aws('elbv2', 'describe-listeners', '--listener-arns', ...this.listeners.map(l => l.ListenerArn));
    requireCheck(result.Listeners?.length === 2 && this.listeners.every(original => {
      const matches = result.Listeners.filter(l => l.ListenerArn === original.ListenerArn);
      if (matches.length !== 1) return false;
      const actions = matches[0].DefaultActions;
      if (actions?.length !== 1 || actions[0].Type !== 'forward' || actions[0].TargetGroupArn !== group) return false;
      const targets = actions[0].ForwardConfig?.TargetGroups;
      return targets === undefined || (targets.length === 1 && targets[0].TargetGroupArn === group && Number(targets[0].Weight ?? 1) > 0);
    }), code);
  }
  async quiesceCanonical() {
    // Green already serves production after bake. Do not overlap another
    // rolling replacement inside the emulator's canonical service scheduler.
    await this.ready(this.candidateName, this.green.definition, this.green.image, this.green.digest, true);
    // Image identity alone cannot distinguish candidate from canonical after
    // convergence. Establish and read back both physical default routes first.
    for (const listener of this.listeners) await this.aws('elbv2', 'modify-listener', '--listener-arn', listener.ListenerArn, '--default-actions', JSON.stringify([{ Type: 'forward', TargetGroupArn: this.owned.group }]));
    await this.verifyProductionRoutes(this.owned.group, 'CANDIDATE_ROUTE_UNCONFIRMED');
    checkIdentity(this.green, await this.application());
    checkIdentity(this.green, await this.application({ tls: true }));
    const capture = async () => {
      let running = [];
      for (const status of ['RUNNING', 'STOPPED']) {
        const arns = (await this.aws('ecs', 'list-tasks', '--cluster', this.config.cluster, '--service-name', this.config.service, '--desired-status', status)).taskArns || [];
        if (status === 'RUNNING') running = arns;
        for (let i = 0; i < arns.length; i += 100) {
          const batch = arns.slice(i, i + 100);
          const described = await this.aws('ecs', 'describe-tasks', '--cluster', this.config.cluster, '--tasks', ...batch);
          requireCheck(described.failures?.length === 0 && described.tasks?.length === batch.length && described.tasks.every(t =>
            batch.includes(t.taskArn) && t.group === 'service:' + this.config.service &&
            t.clusterArn === 'arn:aws:ecs:us-east-1:000000000000:cluster/' + this.config.cluster &&
            t.taskDefinitionArn.startsWith('arn:aws:ecs:us-east-1:000000000000:task-definition/cloudtasks:')), 'CANONICAL_RETIREMENT_OWNER_MISMATCH');
          for (const arn of batch) this.retiredCanonicalArns.add(arn);
        }
      }
      return running;
    };
    await capture();
    // Mark immediately before the first mutation: its response may be lost.
    this.canonicalChanged = true;
    await this.aws('ecs', 'update-service', '--cluster', this.config.cluster, '--service', this.config.service, '--desired-count', '0');
    const deadline = Date.now() + 60000;
    let emptySamples = 0;
    while (emptySamples < 2) {
      const running = await capture();
      const service = await this.service(this.config.service);
      const rows = (await this.docker('ps', '--no-trunc', '--format', '{{.ID}} {{.Names}}')).trim().split(/\r?\n/).filter(Boolean);
      const physical = rows.some(row => [...this.retiredCanonicalArns].some(arn =>
        row.split(/\s+/)[1]?.startsWith('ls-ecs-' + this.config.cluster + '-' + arn.split('/').at(-1) + '-')));
      emptySamples = service.desiredCount === 0 && service.runningCount === 0 && service.pendingCount === 0 && running.length === 0 && !physical ? emptySamples + 1 : 0;
      if (emptySamples === 2) break;
      requireCheck(Date.now() < deadline, 'CANONICAL_RETIREMENT_TIMEOUT');
      await sleep(2000);
    }
    checkIdentity(this.green, await this.application());
    checkIdentity(this.green, await this.application({ tls: true }));
    return { taskArns: [...this.retiredCanonicalArns], emptySamples, physicalRunning: 0, productionHttp: 'green', productionHttps: 'green' };
  }
  async converge(green) {
    const definition = copyDefinition(this.originalDefinition, green.image, 'cloudtasks');
    const arn = (await this.aws('ecs', 'register-task-definition', '--cli-input-json', JSON.stringify(definition))).taskDefinition.taskDefinitionArn;
    const retirement = await this.quiesceCanonical();
    await this.aws('ecs', 'update-service', '--cluster', this.config.cluster, '--service', this.config.service, '--task-definition', arn, '--desired-count', '2');
    const tasks = await this.ready(this.config.service, arn, green.image, green.digest);
    for (const task of tasks) checkIdentity(green, await this.application({ ip: task.ip }));
    await this.syncTargets(this.mainGroup.TargetGroupArn, tasks);
    await this.restoreListeners();
    checkIdentity(green, await this.application());
    checkIdentity(green, await this.application({ tls: true }));
    return { taskDefinition: arn, image: green.image, digest: green.digest, releaseId: green.releaseId, tasks, targetGroup: this.mainGroup.TargetGroupArn, http: 'green', https: 'green', canonicalRetirement: retirement };
  }
  async rollback(blue) {
    if (this.canonicalChanged) {
      const definition = copyDefinition(this.originalDefinition, blue.image, 'cloudtasks');
      const arn = (await this.aws('ecs', 'register-task-definition', '--cli-input-json', JSON.stringify(definition))).taskDefinition.taskDefinitionArn;
      await this.quiesceCanonical();
      await this.aws('ecs', 'update-service', '--cluster', this.config.cluster, '--service', this.config.service, '--task-definition', arn, '--desired-count', '2');
      const tasks = await this.ready(this.config.service, arn, blue.image, blue.digest);
      await this.syncTargets(this.mainGroup.TargetGroupArn, tasks);
    }
    await this.restoreListeners();
    await this.verifyBlue(blue);
    return { productionImage: blue.image, productionRelease: blue.releaseId, http: 'blue', https: 'blue' };
  }
  async ownedContainers() {
    const result = [];
    for (const taskId of new Set(this.owned.taskIds)) {
      requireCheck(uuid.test(taskId), 'CANDIDATE_TASK_ID_INVALID');
      const rows = await this.docker('ps', '-a', '--filter', 'name=' + taskId, '--no-trunc', '--format', '{{.ID}} {{.Names}}');
      if (!rows.trim()) continue;
      const id = taskDockerIdentity(rows, this.config.cluster, taskId);
      requireCheck(!this.blue.tasks.some(t => t.containerId === id), 'CANDIDATE_OWNER_MISMATCH');
      result.push(id);
    }
    return result;
  }
  isOwnedRule(rule) {
    const retained = String(rule.Priority) === '49311';
    if (!retained && String(rule.Priority) !== '49310') return false;
    const expectedGroup = retained ? this.mainGroup?.TargetGroupArn : this.owned.group;
    const header = rule.Conditions?.[0]?.HttpHeaderConfig;
    return Boolean(expectedGroup && rule.Conditions?.length === 1 && rule.Conditions[0].Field === 'http-header' &&
      header?.HttpHeaderName?.toLowerCase() === 'x-cloudtasks-candidate' && header.Values?.length === 1 &&
      header.Values[0] === (retained ? 'blue-' : '') + this.config.executionId &&
      rule.Actions?.length === 1 && rule.Actions[0].Type === 'forward' && rule.Actions[0].TargetGroupArn === expectedGroup);
  }
  async discoverOwnedRules() {
    const found = [];
    for (const listener of this.listeners) {
      const rules = (await this.aws('elbv2', 'describe-rules', '--listener-arn', listener.ListenerArn)).Rules;
      requireCheck(Array.isArray(rules), 'CANDIDATE_RULE_CLEANUP_FAILED');
      for (const rule of rules) if (this.owned.rules.includes(rule.RuleArn) || this.isOwnedRule(rule)) found.push(rule.RuleArn);
    }
    return [...new Set(found)];
  }
  async cleanup() {
    // Reconcile creations with uncertain responses before deleting anything.
    // Exact listener/priority/execution-header/target identifies our lost ARN.
    const rulesToDelete = await this.discoverOwnedRules();
    this.owned.rules = [...new Set([...this.owned.rules, ...rulesToDelete])];
    for (const rule of rulesToDelete) await this.aws('elbv2', 'delete-rule', '--rule-arn', rule);
    if (this.owned.service) {
      for (const status of ['RUNNING', 'STOPPED']) {
        const arns = (await this.aws('ecs', 'list-tasks', '--cluster', this.config.cluster, '--service-name', this.candidateName, '--desired-status', status)).taskArns || [];
        this.owned.taskIds.push(...arns.map(x => x.split('/').at(-1)));
      }
      await this.aws('ecs', 'update-service', '--cluster', this.config.cluster, '--service', this.candidateName, '--desired-count', '0');
      // Capture again after scaling down: the Docker executor can finish an
      // in-flight task between the first inventory and UpdateService. Deleting
      // the service too early removes the API identity needed for safe cleanup.
      const deadline = Date.now() + 60000;
      let emptySamples = 0;
      while (emptySamples < 2) {
        const service = (await this.aws('ecs', 'describe-services', '--cluster', this.config.cluster, '--services', this.candidateName)).services?.[0];
        const running = (await this.aws('ecs', 'list-tasks', '--cluster', this.config.cluster, '--service-name', this.candidateName, '--desired-status', 'RUNNING')).taskArns || [];
        const stopped = (await this.aws('ecs', 'list-tasks', '--cluster', this.config.cluster, '--service-name', this.candidateName, '--desired-status', 'STOPPED')).taskArns || [];
        this.owned.taskIds.push(...running.map(x => x.split('/').at(-1)), ...stopped.map(x => x.split('/').at(-1)));
        emptySamples = service?.desiredCount === 0 && service.runningCount === 0 && service.pendingCount === 0 && running.length === 0 ? emptySamples + 1 : 0;
        if (emptySamples === 2) break;
        requireCheck(Date.now() < deadline, 'CANDIDATE_RETIREMENT_TIMEOUT');
        await sleep(2000);
      }
      await this.aws('ecs', 'delete-service', '--cluster', this.config.cluster, '--service', this.candidateName, '--force');
      await sleep(4000);
    }
    const ownedIds = await this.ownedContainers();
    for (const id of ownedIds) await this.docker('rm', '-f', '-v', id);
    if (this.owned.group) await this.aws('elbv2', 'delete-target-group', '--target-group-arn', this.owned.group);
    if (this.owned.definition) await this.aws('ecs', 'deregister-task-definition', '--task-definition', this.owned.definition);
    const logs = await this.aws('logs', 'describe-log-streams', '--log-group-name', '/cloudtasks/ecs', '--log-stream-name-prefix', 'bg-' + this.config.executionId + '/');
    for (const stream of logs.logStreams || []) await this.aws('logs', 'delete-log-stream', '--log-group-name', '/cloudtasks/ecs', '--log-stream-name', stream.logStreamName);
    const serviceResult = await this.aws('ecs', 'describe-services', '--cluster', this.config.cluster, '--services', this.candidateName);
    requireCheck(Array.isArray(serviceResult.services) && Array.isArray(serviceResult.failures), 'CANDIDATE_SERVICE_CLEANUP_FAILED');
    const remainingServices = serviceResult.services;
    requireCheck(!remainingServices.some(s => s.status === 'ACTIVE' || s.runningCount || s.pendingCount), 'CANDIDATE_SERVICE_CLEANUP_FAILED');
    const groups = (await this.aws('elbv2', 'describe-target-groups')).TargetGroups;
    requireCheck(Array.isArray(groups), 'CANDIDATE_GROUP_CLEANUP_FAILED');
    requireCheck(!groups.some(g => g.TargetGroupName === this.groupName), 'CANDIDATE_GROUP_CLEANUP_FAILED');
    for (const listener of this.listeners) {
      const rules = (await this.aws('elbv2', 'describe-rules', '--listener-arn', listener.ListenerArn)).Rules;
      requireCheck(Array.isArray(rules), 'CANDIDATE_RULE_CLEANUP_FAILED');
      requireCheck(!rules.some(r => this.owned.rules.includes(r.RuleArn) || this.isOwnedRule(r)), 'CANDIDATE_RULE_CLEANUP_FAILED');
    }
    if (this.owned.definition) {
      const td = (await this.aws('ecs', 'describe-task-definition', '--task-definition', this.owned.definition)).taskDefinition;
      requireCheck(td?.status === 'INACTIVE', 'CANDIDATE_DEFINITION_CLEANUP_FAILED');
    }
    const remainingLogs = await this.aws('logs', 'describe-log-streams', '--log-group-name', '/cloudtasks/ecs', '--log-stream-name-prefix', 'bg-' + this.config.executionId + '/');
    requireCheck(remainingLogs.logStreams?.length === 0, 'CANDIDATE_LOG_CLEANUP_FAILED');
    requireCheck((await this.ownedContainers()).length === 0, 'CANDIDATE_DOCKER_CLEANUP_FAILED');
    if (this.canonicalChanged) {
      const rows = (await this.docker('ps', '-a', '--no-trunc', '--format', '{{.ID}} {{.Names}}')).trim().split(/\r?\n/).filter(Boolean);
      const arns = new Set([...this.retiredCanonicalArns, ...this.blue.tasks.map(t => t.taskArn)]);
      for (const arn of arns) {
        const taskId = arn.split('/').at(-1);
        const matches = rows.filter(row => row.split(/\s+/)[1]?.startsWith('ls-ecs-' + this.config.cluster + '-' + taskId + '-'));
        if (!matches.length) continue;
        const id = taskDockerIdentity(matches.join('\n'), this.config.cluster, taskId);
        const running = (await this.docker('inspect', '--format', '{{.State.Running}}', id)).trim();
        requireCheck(running === 'false', 'RETIRED_BLUE_STILL_RUNNING');
        await this.docker('rm', '-v', id);
      }
    }
    return { temporaryServiceRemoved: true, temporaryRulesRemoved: true, temporaryGroupRemoved: true, temporaryDefinitionDeregistered: true, temporaryContainersRemoved: true, temporaryLogsRemoved: true };
  }
}

async function main() {
  const config = validateLocalConfig(process.env);
  const directory = await mkdtemp(path.join(tmpdir(), 'cloudtasks-bg-'));
  try {
    const io = new LocalStackDeployment(config, directory);
    const receipt = await deployBlueGreen(io, { executionId: config.executionId, agentBuildId: config.agentBuildId, scenario: config.scenario, bakeSeconds: config.bakeSeconds });
    console.log('[Blue/Green] RESULT=' + receipt.status + ' CODE=' + (receipt.errorCode || 'OK'));
    process.exitCode = receipt.status === 'SUCCEEDED' ? 0 : 1;
  } finally { await rm(directory, { recursive: true, force: true }); }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error('[Blue/Green] ' + errorCode(error)); process.exitCode = 1; });
}
