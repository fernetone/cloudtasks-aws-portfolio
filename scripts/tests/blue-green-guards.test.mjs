import assert from 'node:assert/strict';
import test from 'node:test';
import http from 'node:http';
import { EventEmitter } from 'node:events';
import { validateLocalConfig, readImageDefinition, healthPayload, checkIdentity, copyDefinition, awsOutput, taskDockerIdentity, LocalStackDeployment } from '../localstack/blue-green-localstack.mjs';
import { DeploymentError } from '../localstack/blue-green-controller.mjs';

const execution = '12345678-1234-4123-8123-123456789abc';
const uri = '000000000000.dkr.ecr.us-east-1.localhost.localstack.cloud:4566/cloudtasks';
const env = {
  AWS_ENDPOINT_URL: 'http://cloudtasks-localstack:4566',
  BG_CLUSTER: 'cloudtasks-cluster-r20261004030336711',
  BG_SERVICE: 'cloudtasks-service',
  BG_EXECUTION_ID: execution,
  CODEBUILD_BUILD_ID: 'cloudtasks-bluegreen-deploy:build',
  LOCALSTACK_TLS_CERT_SHA256: 'a'.repeat(64),
  BG_SCENARIO: 'Normal',
};

test('successful AWS operations with no payload do not become JSON failures', () => {
  assert.deepEqual(awsOutput(''), {});
  assert.deepEqual(awsOutput('\n  '), {});
  assert.deepEqual(awsOutput('{"ok":true}'), { ok: true });
  assert.throws(() => awsOutput('unexpected non-JSON text'));
});

test('a real failed child process preserves exit diagnostics without command text', async () => {
  const io = new LocalStackDeployment(validateLocalConfig(env), '/unused-test-directory');
  const canary = 'private-command-canary-20261010';
  await assert.rejects(io.command(process.execPath, ['-e', "process.stderr.write('" + canary + "'); process.exit(7)"]), error => {
    assert.equal(error.code, 'AWS_COMMAND_FAILED');
    assert.equal(error.details?.tool, 'process');
    assert.equal(error.details?.operation, 'unknown');
    assert.equal(error.details?.reason, 'exit');
    assert.equal(error.details?.exitCode, 7);
    assert.ok(error.details?.elapsedMs >= 0);
    assert.equal(JSON.stringify(error).includes(canary), false);
    return true;
  });
});

test('a missing AWS executable identifies the requested operation without payload or credentials', async () => {
  const io = new LocalStackDeployment(validateLocalConfig(env), '/unused-test-directory');
  io.env.PATH = '/cloudtasks-no-executable-20261010';
  await assert.rejects(io.aws('ecs', 'register-task-definition', '--cli-input-json', '{"password":"private-payload-canary"}'), error => {
    assert.equal(error.code, 'AWS_COMMAND_FAILED');
    assert.equal(error.details?.tool, 'aws');
    assert.equal(error.details?.operation, 'ecs/register-task-definition');
    assert.equal(error.details?.reason, 'spawn');
    assert.equal(error.details?.exitCode, 'ENOENT');
    assert.equal(JSON.stringify(error).includes('private-payload-canary'), false);
    return true;
  });
});

test('a real child terminated by a POSIX signal is distinguished from a normal exit', { skip: process.platform === 'win32' }, async () => {
  const io = new LocalStackDeployment(validateLocalConfig(env), '/unused-test-directory');
  for (const signal of ['SIGTERM', 'SIGKILL']) {
    await assert.rejects(io.command(process.execPath, ['-e', "process.kill(process.pid, '" + signal + "')"]), error => {
      assert.equal(error.details?.reason, 'terminated');
      assert.equal(error.details?.signal, signal);
      assert.equal(error.details?.exitCode, null);
      return true;
    });
  }
});

test('an oversized POSIX argument is a spawn failure without copying the argument', { skip: process.platform === 'win32' }, async () => {
  const io = new LocalStackDeployment(validateLocalConfig(env), '/unused-test-directory');
  const payload = 'private-oversized-canary'.repeat(20000);
  await assert.rejects(io.command(process.execPath, ['-e', '', payload]), error => {
    assert.equal(error.details?.reason, 'spawn');
    assert.equal(error.details?.exitCode, 'E2BIG');
    assert.equal(JSON.stringify(error).includes('private-oversized-canary'), false);
    return true;
  });
});

test('Docker task identity requires the exact cluster and task name prefix', () => {
  const id = 'a'.repeat(64);
  const name = 'ls-ecs-' + env.BG_CLUSTER + '-' + execution + '-0-cafebabe';
  assert.equal(taskDockerIdentity(id + ' ' + name, env.BG_CLUSTER, execution), id);
  assert.throws(() => taskDockerIdentity(id + ' foreign-' + execution, env.BG_CLUSTER, execution));
  assert.throws(() => taskDockerIdentity(id + ' ' + name + '\n' + id + ' ' + name, env.BG_CLUSTER, execution));
  assert.throws(() => taskDockerIdentity(id + ' ' + name, 'different-cluster', execution));
});

test('configuration accepts only this LocalStack endpoint and canonical service', () => {
  assert.equal(validateLocalConfig(env).endpoint, env.AWS_ENDPOINT_URL);
  for (const url of ['https://ecs.us-east-1.amazonaws.com', 'http://cloudtasks-localstack:80', 'http://other:4566', 'http://user:pass@cloudtasks-localstack:4566', 'http://cloudtasks-localstack:4566/path']) {
    assert.throws(() => validateLocalConfig({ ...env, AWS_ENDPOINT_URL: url }));
  }
  assert.throws(() => validateLocalConfig({ ...env, BG_SERVICE: 'unrelated-service' }));
  assert.throws(() => validateLocalConfig({ ...env, BG_CLUSTER: 'another-cluster' }));
});

test('configuration rejects missing TLS pin, unlinked execution and short bake', () => {
  assert.throws(() => validateLocalConfig({ ...env, LOCALSTACK_TLS_CERT_SHA256: '' }));
  assert.throws(() => validateLocalConfig({ ...env, BG_EXECUTION_ID: '#{codepipeline.PipelineExecutionId}' }));
  assert.throws(() => validateLocalConfig({ ...env, BG_BAKE_SECONDS: '0' }));
  assert.throws(() => validateLocalConfig({ ...env, BG_BAKE_SECONDS: '59' }));
  assert.equal(validateLocalConfig(env).bakeSeconds, 60);
});

test('the local agent reserved build ID is informational, not native provenance', () => {
  for (const id of ['', 'local:00000000-0000-0000-0000-000000000000']) {
    const value = validateLocalConfig({ ...env, CODEBUILD_BUILD_ID: id });
    assert.equal(value.executionId, execution);
    assert.equal(value.buildId, undefined);
  }
});

test('image artifact requires exactly one approved immutable container image', () => {
  const image = uri + ':pipeline-' + execution;
  assert.equal(readImageDefinition(JSON.stringify([{ name: 'cloudtasks-app', imageUri: image }]), uri).image, image);
  for (const defs of [{}, [], [{ name: 'other', imageUri: image }], [{ name: 'cloudtasks-app', imageUri: uri + ':latest' }], [{ name: 'cloudtasks-app', imageUri: 'other:tag' }], [{ name: 'cloudtasks-app', imageUri: image }, { name: 'cloudtasks-app', imageUri: image }]]) {
    assert.throws(() => readImageDefinition(JSON.stringify(defs), uri));
  }
});

test('HTTP 200 without semantic application and database health is rejected', () => {
  assert.deepEqual(healthPayload(200, '{"status":"ok","database":"ok"}'), { status: 'ok', database: 'ok' });
  assert.throws(() => healthPayload(200, '{}'));
  assert.throws(() => healthPayload(200, '{"status":"ok","database":"unavailable"}'));
  assert.throws(() => healthPayload(503, '{"status":"ok","database":"ok"}'));
});

test('candidate HTTP identity cannot use the legacy bootstrap or another release', () => {
  const expected = { releaseId: 'pipeline-' + execution, bundleSha256: 'b'.repeat(64) };
  checkIdentity(expected, expected);
  assert.throws(() => checkIdentity(expected, { ...expected, releaseId: null }));
  assert.throws(() => checkIdentity(expected, { ...expected, releaseId: 'pipeline-other' }));
  assert.throws(() => checkIdentity(expected, { ...expected, bundleSha256: 'c'.repeat(64) }));
  const legacy = { ...expected, releaseId: null };
  checkIdentity(legacy, legacy);
  assert.throws(() => checkIdentity(legacy, expected));
  assert.throws(() => checkIdentity(expected, { ...expected, releaseId: 'local' }));
});

function applicationFixture(releaseId) {
  const io = new LocalStackDeployment(validateLocalConfig(env), '/unused-test-directory');
  io.request = async pathname => {
    if (pathname === '/health') return { status: 200, text: '{"status":"ok","database":"ok"}', type: 'application/json' };
    if (pathname === '/api/tasks') return { status: 200, text: '[]', type: 'application/json' };
    if (pathname === '/') return { status: 200, text: '<script type="module" src="/assets/index-fixture.js"></script>', type: 'text/html' };
    if (pathname === '/assets/index-fixture.js') return { status: 200, text: '/* application bundle */'.repeat(10), type: 'text/javascript' };
    if (pathname === '/release.json') return { status: 200, text: JSON.stringify({ releaseId, version: '1.8.0' }), type: 'application/json' };
    throw new Error('Unexpected fixture path');
  };
  return io;
}

test('the default Docker build local release is a valid bootstrap application identity', async () => {
  const identity = await applicationFixture('local').application();
  assert.equal(identity.releaseId, 'local');
  assert.equal(identity.database, 'ok');
  assert.match(identity.bundleSha256, /^[a-f0-9]{64}$/);
});

test('local bootstrap identity cannot qualify a pipeline candidate or image artifact', async () => {
  const io = applicationFixture('local');
  io.artifact = { image: uri + ':pipeline-' + execution, releaseId: 'pipeline-' + execution };
  io.ready = async () => [{ ip: '172.18.0.3' }, { ip: '172.18.0.4' }];
  io.syncTargets = async () => { assert.fail('The local image must be rejected before target registration'); };
  await assert.rejects(io.validateCandidate(), { code: 'CANDIDATE_IDENTITY_MISMATCH' });
  assert.throws(() => readImageDefinition(JSON.stringify([{ name: 'cloudtasks-app', imageUri: uri + ':local' }]), uri));
});

test('bootstrap compatibility does not accept arbitrary release metadata', async () => {
  for (const releaseId of [null, '', 'latest', 'pipeline-other', 'local-other']) {
    await assert.rejects(applicationFixture(releaseId).application(), { code: 'APP_RELEASE_INVALID' });
  }
});

test('task definition copy resets observed bridge host ports without changing secret references', () => {
  const td = { family: 'cloudtasks', networkMode: 'bridge', revision: 3, taskDefinitionArn: 'old', containerDefinitions: [{ name: 'cloudtasks-app', image: 'old', secrets: [{ name: 'DATABASE_SECRET_JSON', valueFrom: 'arn:reference' }], portMappings: [{ containerPort: 3000, hostPort: 19025 }] }] };
  const copy = copyDefinition(td, 'new', 'cloudtasks-candidate');
  assert.equal(copy.containerDefinitions[0].portMappings[0].hostPort, 0);
  assert.deepEqual(copy.containerDefinitions[0].secrets, td.containerDefinitions[0].secrets);
  assert.equal(copy.containerDefinitions[0].dockerLabels, undefined);
  assert.equal(copy.revision, undefined);
  assert.equal(td.containerDefinitions[0].portMappings[0].hostPort, 19025);
  assert.equal(td.containerDefinitions[0].image, 'old');
  assert.throws(() => copyDefinition({ ...td, networkMode: 'awsvpc' }, 'new', 'cloudtasks-candidate', execution));
});


test('cleanup captures a task that finishes starting while the candidate is scaled down', async () => {
  const io = new LocalStackDeployment(validateLocalConfig(env), '/unused-test-directory');
  const ids = ['11111111-1111-4111-8111-111111111111', '22222222-2222-4222-8222-222222222222', '33333333-3333-4333-8333-333333333333'];
  const containers = new Map(ids.slice(0, 2).map((id, i) => [id, String(i + 1).repeat(64)]));
  const arn = id => 'arn:aws:ecs:us-east-1:000000000000:task/' + env.BG_CLUSTER + '/' + id;
  let scaled = false;
  let deleted = false;
  io.blue = { tasks: [{ containerId: 'a'.repeat(64) }, { containerId: 'b'.repeat(64) }] };
  io.owned.service = 'owned-candidate-service';
  io.listeners = [];
  io.aws = async (service, action, ...args) => {
    if (action === 'list-tasks') {
      const status = args[args.indexOf('--desired-status') + 1];
      return { taskArns: deleted ? [] : scaled ? (status === 'STOPPED' ? ids.map(arn) : []) : (status === 'RUNNING' ? ids.slice(0, 2).map(arn) : []) };
    }
    if (action === 'update-service') { scaled = true; containers.set(ids[2], '3'.repeat(64)); return {}; }
    if (action === 'delete-service') { deleted = true; return {}; }
    if (action === 'describe-services') return { services: [{ status: deleted ? 'INACTIVE' : 'ACTIVE', desiredCount: 0, runningCount: 0, pendingCount: 0 }], failures: [] };
    if (action === 'describe-target-groups') return { TargetGroups: [] };
    if (action === 'describe-log-streams') return { logStreams: [] };
    throw new Error('Unexpected fixture API: ' + service + '/' + action);
  };
  io.docker = async (...args) => {
    if (args[0] === 'ps') {
      const id = args.find(x => x.startsWith('name=')).slice(5);
      return containers.has(id) ? containers.get(id) + ' ls-ecs-' + env.BG_CLUSTER + '-' + id + '-0-fixture' : '';
    }
    if (args[0] === 'rm') { for (const [key, value] of containers) if (value === args.at(-1)) containers.delete(key); return ''; }
    throw new Error('Unexpected fixture Docker operation');
  };
  await io.cleanup();
  assert.equal(containers.size, 0, 'A late candidate container must not be omitted from cleanup');
});


test('promotion keeps the retained blue target group associated with both ALB listeners', async () => {
  const io = new LocalStackDeployment(validateLocalConfig(env), '/unused-test-directory');
  io.mainGroup = { TargetGroupArn: 'main-group', VpcId: 'vpc' };
  io.originalDefinition = { networkMode: 'bridge', containerDefinitions: [{ name: 'cloudtasks-app', logConfiguration: { options: {} } }] };
  io.artifact = { image: uri + ':pipeline-' + execution };
  io.listeners = [{ ListenerArn: 'http' }, { ListenerArn: 'https' }];
  const defaults = new Map(io.listeners.map(x => [x.ListenerArn, 'main-group']));
  const rules = [];
  io.aws = async (service, action, ...args) => {
    const get = name => args[args.indexOf(name) + 1];
    if (action === 'register-task-definition') return { taskDefinition: { taskDefinitionArn: 'candidate-definition' } };
    if (action === 'create-target-group') return { TargetGroups: [{ TargetGroupArn: 'green-group' }] };
    if (action === 'modify-target-group-attributes') return {};
    if (action === 'create-rule') { rules.push({ listener: get('--listener-arn'), actions: JSON.parse(get('--actions')) }); return { Rules: [{ RuleArn: 'rule-' + rules.length }] }; }
    if (action === 'create-service') return { service: { serviceArn: 'candidate-service' } };
    if (action === 'modify-listener') { defaults.set(get('--listener-arn'), JSON.parse(get('--default-actions'))[0].TargetGroupArn); return {}; }
    throw new Error('Unexpected fixture API: ' + service + '/' + action);
  };
  const green = { releaseId: 'pipeline-' + execution, bundleSha256: 'c'.repeat(64) };
  io.application = async () => green;
  await io.createCandidate();
  await io.promote(green);
  for (const listener of io.listeners) {
    assert.equal(defaults.get(listener.ListenerArn), 'green-group');
    assert.ok(rules.some(rule => rule.listener === listener.ListenerArn && rule.actions.some(action => action.TargetGroupArn === 'main-group')), 'Retained blue must remain attached for health checks and rollback');
  }
});

test('canonical replacement reaches an empty runtime before starting the accepted revision while green serves', async () => {
  const io = new LocalStackDeployment(validateLocalConfig(env), '/unused-test-directory');
  const taskArn = 'arn:aws:ecs:us-east-1:000000000000:task/' + env.BG_CLUSTER + '/' + execution;
  const oldDefinition = 'arn:aws:ecs:us-east-1:000000000000:task-definition/cloudtasks:1';
  const newDefinition = oldDefinition.replace(':1', ':2');
  const green = { definition: 'candidate-definition', image: uri + ':pipeline-' + execution, digest: 'sha256:' + 'b'.repeat(64), releaseId: 'pipeline-' + execution, bundleSha256: 'c'.repeat(64) };
  let desired = 2;
  let emptyObserved = 0;
  let greenResponses = 0;
  io.green = green;
  io.blue = { tasks: [] };
  io.originalDefinition = { networkMode: 'bridge', containerDefinitions: [{ name: 'cloudtasks-app' }] };
  io.mainGroup = { TargetGroupArn: 'main-group' };
  io.owned.group = 'green-group';
  io.listeners = ['http', 'https'].map(ListenerArn => ({ ListenerArn, DefaultActions: [{ Type: 'forward', TargetGroupArn: 'main-group' }] }));
  const defaults = new Map(io.listeners.map(l => [l.ListenerArn, 'green-group']));
  io.application = async () => { greenResponses++; return green; };
  io.ready = async () => [{ ip: '172.18.0.3' }, { ip: '172.18.0.4' }];
  io.syncTargets = async () => {};
  io.aws = async (service, action, ...args) => {
    const get = name => args[args.indexOf(name) + 1];
    if (action === 'register-task-definition') return { taskDefinition: { taskDefinitionArn: newDefinition } };
    if (action === 'modify-listener') { defaults.set(get('--listener-arn'), JSON.parse(get('--default-actions'))[0].TargetGroupArn); return {}; }
    if (action === 'describe-listeners') return { Listeners: io.listeners.map(l => ({ ...l, DefaultActions: [{ Type: 'forward', TargetGroupArn: defaults.get(l.ListenerArn) }] })) };
    if (action === 'list-tasks') return { taskArns: get('--desired-status') === 'STOPPED' || desired ? [taskArn] : [] };
    if (action === 'describe-tasks') return { failures: [], tasks: [{ taskArn, group: 'service:cloudtasks-service', clusterArn: 'arn:aws:ecs:us-east-1:000000000000:cluster/' + env.BG_CLUSTER, taskDefinitionArn: oldDefinition }] };
    if (action === 'describe-services') { if (!desired) emptyObserved++; return { services: [{ status: 'ACTIVE', desiredCount: desired, runningCount: desired, pendingCount: 0 }] }; }
    if (action === 'update-service') {
      if (get('--desired-count') === '2') assert.ok(emptyObserved >= 2, 'The emulator must be quiescent before the next canonical revision starts');
      desired = Number(get('--desired-count')); return {};
    }
    throw new Error('Unexpected fixture API: ' + service + '/' + action);
  };
  io.docker = async (...args) => { assert.equal(args[0], 'ps'); return ''; };
  const result = await io.converge(green);
  assert.equal(result.taskDefinition, newDefinition);
  assert.ok(greenResponses >= 4, 'Green must be verified while the canonical service is empty');
});

function retirementFixture({ canonicalGreen = false, candidateFailure = false, ignoreHttpsSwitch = false } = {}) {
  const io = new LocalStackDeployment(validateLocalConfig(env), '/unused-test-directory');
  const green = { definition: 'candidate-definition', image: uri + ':pipeline-' + execution, digest: 'sha256:' + 'b'.repeat(64), releaseId: 'pipeline-' + execution, bundleSha256: 'c'.repeat(64) };
  const blue = { definition: 'arn:aws:ecs:us-east-1:000000000000:task-definition/cloudtasks:1', image: uri + ':old', digest: 'sha256:' + 'a'.repeat(64), releaseId: null, bundleSha256: 'a'.repeat(64), tasks: [{ ip: '172.18.0.3', containerId: '1'.repeat(64) }, { ip: '172.18.0.4', containerId: '2'.repeat(64) }] };
  const taskArn = 'arn:aws:ecs:us-east-1:000000000000:task/' + env.BG_CLUSTER + '/' + execution;
  const defaults = new Map([['http', canonicalGreen ? 'main-group' : 'green-group'], ['https', canonicalGreen ? 'main-group' : 'green-group']]);
  const events = [];
  let desired = 2;
  let current = canonicalGreen ? green : blue;
  let definition = blue.definition;
  const revisions = new Map();
  io.green = green; io.blue = blue;
  io.owned.group = 'green-group';
  io.mainGroup = { TargetGroupArn: 'main-group' };
  io.originalDefinition = { networkMode: 'bridge', containerDefinitions: [{ name: 'cloudtasks-app', image: blue.image }] };
  io.listeners = ['http', 'https'].map(ListenerArn => ({ ListenerArn, DefaultActions: [{ Type: 'forward', TargetGroupArn: 'main-group' }] }));
  io.ready = async name => {
    if (name === io.candidateName && candidateFailure) throw new DeploymentError('CANDIDATE_UNHEALTHY');
    return blue.tasks;
  };
  io.application = async (options = {}) => {
    const group = defaults.get(options.tls ? 'https' : 'http');
    if (!options.ip && !options.candidate && group === 'green-group') return green;
    if (!desired) throw new DeploymentError('PRODUCTION_ROUTE_EMPTY');
    return current;
  };
  io.syncTargets = async () => {};
  io.docker = async () => '';
  io.aws = async (service, action, ...args) => {
    const get = name => args.includes(name) ? args[args.indexOf(name) + 1] : undefined;
    if (action === 'register-task-definition') {
      const arn = blue.definition.replace(':1', ':' + (revisions.size + 2));
      const image = JSON.parse(get('--cli-input-json')).containerDefinitions[0].image;
      revisions.set(arn, image === blue.image ? blue : green);
      return { taskDefinition: { taskDefinitionArn: arn } };
    }
    if (action === 'modify-listener') {
      const name = get('--listener-arn');
      const target = JSON.parse(get('--default-actions'))[0].TargetGroupArn;
      events.push('route:' + name + ':' + target);
      if (!(ignoreHttpsSwitch && name === 'https' && target === 'green-group')) defaults.set(name, target);
      return {};
    }
    if (action === 'describe-listeners') return { Listeners: io.listeners.map(l => ({ ...l, DefaultActions: [{ Type: 'forward', TargetGroupArn: defaults.get(l.ListenerArn) }] })) };
    if (action === 'list-tasks') return { taskArns: get('--desired-status') === 'STOPPED' || desired ? [taskArn] : [] };
    if (action === 'describe-tasks') return { failures: [], tasks: [{ taskArn, group: 'service:cloudtasks-service', clusterArn: 'arn:aws:ecs:us-east-1:000000000000:cluster/' + env.BG_CLUSTER, taskDefinitionArn: definition }] };
    if (action === 'describe-services') return { services: [{ status: 'ACTIVE', desiredCount: desired, runningCount: desired, pendingCount: 0 }] };
    if (action === 'update-service') {
      events.push('desired:' + get('--desired-count'));
      if (get('--desired-count') === '0') assert.ok([...defaults.values()].every(x => x === 'green-group'), 'Both physical defaults must use the candidate before canonical retirement');
      desired = Number(get('--desired-count'));
      if (get('--task-definition') !== undefined) { definition = get('--task-definition'); current = revisions.get(definition); }
      return {};
    }
    throw new Error('Unexpected fixture API: ' + service + '/' + action);
  };
  return { io, blue, green, defaults, events, state: () => ({ desired, current }) };
}

test('rollback routes both defaults back to the candidate before retiring an identical green canonical image', async () => {
  const f = retirementFixture({ canonicalGreen: true });
  f.io.canonicalChanged = true;
  await f.io.rollback(f.blue);
  assert.equal(f.state().desired, 2);
  assert.equal(f.state().current, f.blue);
  assert.ok([...f.defaults.values()].every(x => x === 'main-group'));
  assert.ok(f.events.indexOf('route:https:green-group') < f.events.indexOf('desired:0'));
});

test('failed candidate preflight restores untouched blue without attempting canonical retirement', async () => {
  const f = retirementFixture({ candidateFailure: true });
  await assert.rejects(f.io.converge(f.green), { code: 'CANDIDATE_UNHEALTHY' });
  assert.equal(f.io.canonicalChanged, false);
  await f.io.rollback(f.blue);
  assert.ok([...f.defaults.values()].every(x => x === 'main-group'));
  assert.equal(f.events.includes('desired:0'), false);
  assert.equal(f.state().current, f.blue);
});

test('an acknowledged but unapplied HTTPS switch never authorizes canonical retirement', async () => {
  const f = retirementFixture({ canonicalGreen: true, ignoreHttpsSwitch: true });
  await assert.rejects(f.io.quiesceCanonical(), { code: 'CANDIDATE_ROUTE_UNCONFIRMED' });
  assert.equal(f.events.includes('desired:0'), false);
  assert.equal(f.state().desired, 2);
});

test('listener restoration attempts both protocols and rejects incomplete recovery', async () => {
  const f = retirementFixture();
  const original = f.io.aws;
  f.io.aws = async (service, action, ...args) => {
    if (action === 'modify-listener' && args[1] === 'http') {
      f.events.push('failed:http'); throw new DeploymentError('AWS_COMMAND_FAILED');
    }
    return original(service, action, ...args);
  };
  await assert.rejects(f.io.restoreListeners());
  assert.ok(f.events.includes('route:https:main-group'), 'One restore error must not skip the other protocol');
  assert.equal(f.defaults.get('https'), 'main-group');
});

test('listener restoration verifies provider state even after successful command acknowledgements', async () => {
  const f = retirementFixture();
  const original = f.io.aws;
  f.io.aws = async (service, action, ...args) => action === 'modify-listener' ? {} : original(service, action, ...args);
  await assert.rejects(f.io.restoreListeners(), { code: 'LISTENER_RESTORE_INCOMPLETE' });
});

test('request has a wall-clock deadline even when the socket never emits a timeout', async t => {
  const io = new LocalStackDeployment(validateLocalConfig(env), '/unused-test-directory');
  io.alb = { DNSName: 'lab.localhost' };
  const req = new EventEmitter();
  req.setTimeout = () => req; req.end = () => {}; req.destroy = error => { if (error) req.emit('error', error); };
  t.mock.method(http, 'request', () => req);
  t.mock.timers.enable({ apis: ['setTimeout'] });
  let result;
  const pending = io.request('/health').then(() => { result = 'RESOLVED'; }, error => { result = error.code; });
  t.mock.timers.tick(8001);
  for (let i = 0; i < 6; i++) await Promise.resolve();
  assert.equal(result, 'HTTP_TIMEOUT');
  await pending;
});

test('cleanup discovers execution-owned rules whose successful creation response was lost', async () => {
  const io = new LocalStackDeployment(validateLocalConfig(env), '/unused-test-directory');
  io.mainGroup = { TargetGroupArn: 'main-group', VpcId: 'vpc' };
  io.originalDefinition = { networkMode: 'bridge', containerDefinitions: [{ name: 'cloudtasks-app', logConfiguration: { options: {} } }] };
  io.artifact = { image: uri + ':pipeline-' + execution };
  io.blue = { tasks: [] };
  io.listeners = [{ ListenerArn: 'http' }, { ListenerArn: 'https' }];
  const foreign = { RuleArn: 'foreign-rule', Priority: '49200', Conditions: [], Actions: [] };
  const rules = new Map([['foreign-rule', { listener: 'http', rule: foreign }]]);
  let removedGroup = false;
  let inactive = false;
  io.docker = async () => '';
  io.aws = async (service, action, ...args) => {
    const get = name => args[args.indexOf(name) + 1];
    if (action === 'register-task-definition') return { taskDefinition: { taskDefinitionArn: 'owned-definition' } };
    if (action === 'create-target-group') return { TargetGroups: [{ TargetGroupArn: 'green-group' }] };
    if (action === 'modify-target-group-attributes') return {};
    if (action === 'create-rule') {
      const RuleArn = 'owned-rule-' + get('--priority');
      const rule = { RuleArn, Priority: get('--priority'), Conditions: JSON.parse(get('--conditions')), Actions: JSON.parse(get('--actions')) };
      rules.set(RuleArn, { listener: get('--listener-arn'), rule });
      if (rule.Priority === '49311') throw new DeploymentError('AWS_COMMAND_FAILED');
      return { Rules: [rule] };
    }
    if (action === 'describe-rules') return { Rules: [...rules.values()].filter(x => x.listener === get('--listener-arn')).map(x => x.rule) };
    if (action === 'delete-rule') { rules.delete(get('--rule-arn')); return {}; }
    if (action === 'delete-target-group') { removedGroup = true; return {}; }
    if (action === 'describe-target-groups') return { TargetGroups: removedGroup ? [] : [{ TargetGroupName: io.groupName }] };
    if (action === 'deregister-task-definition') { inactive = true; return {}; }
    if (action === 'describe-task-definition') return { taskDefinition: { status: inactive ? 'INACTIVE' : 'ACTIVE' } };
    if (action === 'describe-services') return { services: [], failures: [] };
    if (action === 'describe-log-streams') return { logStreams: [] };
    throw new Error('Unexpected fixture API: ' + service + '/' + action);
  };
  await assert.rejects(io.createCandidate(), { code: 'AWS_COMMAND_FAILED' });
  const result = await io.cleanup();
  assert.equal(result.temporaryRulesRemoved, true);
  assert.deepEqual([...rules.keys()], ['foreign-rule'], 'Unacknowledged owned rules must be deleted and foreign rules preserved');
});

test('an unavailable rule inventory preserves known resources instead of starting unverified cleanup', async () => {
  const io = new LocalStackDeployment(validateLocalConfig(env), '/unused-test-directory');
  io.listeners = [{ ListenerArn: 'http' }];
  io.owned.rules = ['known-owned-rule'];
  let deleted = false;
  io.aws = async (service, action) => {
    if (action === 'describe-rules') throw new DeploymentError('AWS_COMMAND_FAILED');
    if (action === 'delete-rule') { deleted = true; return {}; }
    if (action === 'describe-services') return { services: [], failures: [] };
    if (action === 'describe-target-groups') return { TargetGroups: [] };
    throw new Error('Unexpected fixture API: ' + service + '/' + action);
  };
  await assert.rejects(io.cleanup());
  assert.equal(deleted, false);
});
