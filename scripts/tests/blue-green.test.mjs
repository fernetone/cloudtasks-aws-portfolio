import assert from 'node:assert/strict';
import test from 'node:test';
import http from 'node:http';
import { once } from 'node:events';
import { deployBlueGreen, DeploymentError } from '../localstack/blue-green-controller.mjs';
import { LocalStackDeployment } from '../localstack/blue-green-localstack.mjs';

function fixture(fail = {}) {
  const events = [];
  const saved = [];
  const blue = { image: 'blue', taskIds: ['b1', 'b2'] };
  const green = { image: 'green', taskIds: ['g1', 'g2'] };
  let serving = blue;
  let canonical = blue;
  let removed = false;
  let locked = false;
  const io = {};
  const steps = {
    lock: () => { locked = true; },
    baseline: () => blue,
    createCandidate: () => green,
    validateCandidate: () => green,
    validateIsolation: () => assert.equal(serving, blue),
    validateSharedData: () => assert.equal(serving, blue),
    promote: () => { serving = green; },
    observe: () => { assert.equal(canonical, blue); assert.equal(serving, green); },
    converge: () => { canonical = green; return { taskDefinition: 'new-revision', image: 'green' }; },
    rollback: () => { canonical = blue; serving = blue; },
    verifyBlue: () => { assert.equal(serving, blue); assert.equal(canonical, blue); },
    cleanup: () => { removed = true; },
    save: receipt => { saved.push(JSON.parse(JSON.stringify(receipt))); },
    unlock: () => { locked = false; },
  };
  for (const [name, body] of Object.entries(steps)) {
    io[name] = async (...args) => {
      events.push(name);
      if (fail[name] === 'partial') body(...args);
      if (fail[name]) throw new DeploymentError(fail[name] === 'partial' ? 'PARTIAL_' + name.toUpperCase() : String(fail[name]));
      return body(...args);
    };
  }
  return { io, events, saved, state: () => ({ serving, canonical, removed, locked }) };
}

test('promotes only after validation and converges only after bake', async () => {
  const f = fixture();
  const r = await deployBlueGreen(f.io, { executionId: 'execution', buildId: 'build' });
  assert.equal(r.status, 'SUCCEEDED');
  assert.deepEqual(f.events.filter(x => x !== 'save'), ['lock', 'baseline', 'createCandidate', 'validateCandidate', 'validateIsolation', 'validateSharedData', 'promote', 'observe', 'converge', 'cleanup', 'unlock']);
  assert.equal(f.state().serving.image, 'green');
  assert.equal(f.state().removed, true);
  assert.equal(f.state().locked, false);
});

for (const code of ['CANDIDATE_UNHEALTHY', 'CANDIDATE_IDENTITY_MISMATCH']) {
  test(code + ' preserves blue and fails the deployment', async () => {
    const f = fixture({ validateCandidate: code });
    const r = await deployBlueGreen(f.io, {});
    assert.equal(r.status, 'REJECTED');
    assert.equal(r.errorCode, code);
    assert.equal(f.events.includes('promote'), false);
    assert.equal(f.events.includes('converge'), false);
    assert.equal(f.state().serving.image, 'blue');
    assert.equal(f.state().removed, true);
    assert.equal(f.state().locked, false);
  });
}

test('partial listener switch restores blue before cleanup', async () => {
  const f = fixture({ promote: 'partial' });
  const r = await deployBlueGreen(f.io, {});
  assert.equal(r.status, 'ROLLED_BACK');
  assert.equal(f.state().serving.image, 'blue');
  assert.ok(f.events.indexOf('rollback') < f.events.indexOf('cleanup'));
});

test('bake failure rolls production back without converging canonical service', async () => {
  const f = fixture({ observe: 'CONTROLLED_BAKE_FAILURE' });
  const r = await deployBlueGreen(f.io, {});
  assert.equal(r.status, 'ROLLED_BACK');
  assert.equal(r.errorCode, 'CONTROLLED_BAKE_FAILURE');
  assert.equal(f.events.includes('converge'), false);
  assert.equal(f.state().serving.image, 'blue');
});

test('canonical failure restores blue before deleting candidate', async () => {
  const f = fixture({ converge: 'partial' });
  const r = await deployBlueGreen(f.io, {});
  assert.equal(r.status, 'ROLLED_BACK');
  assert.equal(f.state().canonical.image, 'blue');
  assert.ok(f.events.indexOf('rollback') < f.events.indexOf('cleanup'));
});

test('failed rollback preserves serving candidate and lock for recovery', async () => {
  const f = fixture({ observe: 'BAKE_FAILURE', rollback: 'ROLLBACK_FAILURE' });
  const r = await deployBlueGreen(f.io, {});
  assert.equal(r.status, 'RECOVERY_REQUIRED');
  assert.equal(f.events.includes('cleanup'), false);
  assert.equal(f.events.includes('unlock'), false);
  assert.equal(f.state().serving.image, 'green');
});

test('cleanup failure after commit does not claim success or undo healthy committed image', async () => {
  const f = fixture({ cleanup: 'CLEANUP_FAILURE' });
  const r = await deployBlueGreen(f.io, {});
  assert.equal(r.status, 'RECOVERY_REQUIRED');
  assert.equal(f.events.includes('rollback'), false);
  assert.equal(f.state().canonical.image, 'green');
  assert.equal(f.state().locked, true);
});

test('foreign lock causes no baseline read, candidate creation or unlock', async () => {
  const f = fixture({ lock: 'DEPLOYMENT_LOCK_HELD' });
  const r = await deployBlueGreen(f.io, {});
  assert.equal(r.status, 'REJECTED');
  assert.equal(f.events.includes('baseline'), false);
  assert.equal(f.events.includes('createCandidate'), false);
  assert.equal(f.events.includes('unlock'), false);
});

test('unsafe external error text never enters deployment receipt', async () => {
  const f = fixture();
  f.io.validateCandidate = async () => { throw new Error('private-canary-test-data'); };
  const r = await deployBlueGreen(f.io, {});
  assert.equal(r.errorCode, 'UNEXPECTED_ERROR');
  assert.equal(JSON.stringify(r).includes('private-canary-test-data'), false);
});

test('a failed process during bake reaches the saved receipt and still rolls production back', async () => {
  const f = fixture();
  const adapter = new LocalStackDeployment({ executionId: 'execution' }, '/unused-test-directory');
  f.io.observe = () => adapter.command(process.execPath, ['-e', "process.stderr.write('private-bake-canary'); process.exit(7)"]);
  const r = await deployBlueGreen(f.io, {});
  assert.equal(r.status, 'ROLLED_BACK');
  assert.equal(r.errorCode, 'AWS_COMMAND_FAILED');
  assert.equal(r.errorDetails?.reason, 'exit');
  assert.equal(r.errorDetails?.exitCode, 7);
  assert.equal(JSON.stringify(r).includes('private-bake-canary'), false);
  assert.deepEqual(f.saved.at(-1).errorDetails, r.errorDetails);
  assert.equal(f.saved.at(-1).status, 'ROLLED_BACK');
  assert.equal(JSON.stringify(f.saved).includes('private-bake-canary'), false);
  assert.equal(f.state().serving.image, 'blue');
  assert.equal(f.state().removed, true);
  assert.equal(f.state().locked, false);
});

test('diagnostics reject unknown operation labels and discard extra error payload', async () => {
  const f = fixture();
  f.io.observe = async () => { throw new DeploymentError('AWS_COMMAND_FAILED', { tool: 'aws', operation: 'private/passwordcanary', reason: 'exit', elapsedMs: 10, exitCode: 1, stderr: 'private-error-canary', args: ['private-argument-canary'] }); };
  const r = await deployBlueGreen(f.io, {});
  assert.equal(r.errorDetails?.operation, 'unknown');
  assert.equal(r.errorDetails?.exitCode, 1);
  assert.equal(JSON.stringify(r).includes('canary'), false);
});

test('a failed recovery process records its diagnostics while preserving serving resources and lock', async () => {
  const f = fixture({ observe: 'CONTROLLED_BAKE_FAILURE' });
  const adapter = new LocalStackDeployment({ executionId: 'execution' }, '/unused-test-directory');
  f.io.rollback = () => adapter.command(process.execPath, ['-e', "process.stderr.write('private-rollback-canary'); process.exit(3)"]);
  const r = await deployBlueGreen(f.io, {});
  assert.equal(r.status, 'RECOVERY_REQUIRED');
  assert.equal(r.recoveryErrorDetails?.exitCode, 3);
  assert.equal(r.recoveryErrorDetails?.reason, 'exit');
  assert.deepEqual(f.saved.at(-1).recoveryErrorDetails, r.recoveryErrorDetails);
  assert.equal(JSON.stringify(r).includes('private-rollback-canary'), false);
  assert.equal(f.state().removed, false);
  assert.equal(f.state().locked, true);
});

test('a final receipt write failure replaces recovery diagnostics without pairing stale command details', async () => {
  const f = fixture({ observe: 'CONTROLLED_BAKE_FAILURE' });
  f.io.rollback = async () => { throw new DeploymentError('AWS_COMMAND_FAILED', { tool: 'aws', operation: 'elbv2/modify-listener', reason: 'exit', elapsedMs: 12, exitCode: 1 }); };
  const save = f.io.save;
  let failed = false;
  f.io.save = async receipt => {
    if (receipt.status === 'RECOVERY_REQUIRED' && !failed) {
      failed = true;
      throw new Error('private-persistence-canary');
    }
    return save(receipt);
  };
  const r = await deployBlueGreen(f.io, {});
  assert.equal(failed, true);
  assert.equal(r.status, 'RECOVERY_REQUIRED');
  assert.equal(r.recoveryErrorCode, 'UNEXPECTED_ERROR');
  assert.equal(r.recoveryErrorDetails, undefined);
  assert.equal(f.saved.at(-1).recoveryErrorCode, 'UNEXPECTED_ERROR');
  assert.equal(f.saved.at(-1).recoveryErrorDetails, undefined);
  assert.equal(JSON.stringify(f.saved).includes('private-persistence-canary'), false);
  assert.equal(f.state().removed, false);
  assert.equal(f.state().locked, true);
});

test('a truncated post-promotion HTTP response rejects promptly and reaches rollback and cleanup', async t => {
  const server = http.createServer((req, res) => {
    res.writeHead(200, { 'Content-Length': '1000' });
    res.write('partial');
    setImmediate(() => res.destroy());
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const original = http.request;
  t.mock.method(http, 'request', (options, callback) => original({ ...options, hostname: '127.0.0.1', port: server.address().port }, callback));
  const io = new LocalStackDeployment({ executionId: 'execution' }, '/unused-test-directory');
  io.alb = { DNSName: 'lab.localhost' };
  const f = fixture();
  f.io.observe = () => io.request('/health');
  let timer;
  try {
    const result = await Promise.race([deployBlueGreen(f.io, {}), new Promise(resolve => { timer = setTimeout(() => resolve(null), 1000); })]);
    assert.notEqual(result, null, 'Interrupted responses must settle instead of hanging the deployment');
    assert.equal(result.status, 'ROLLED_BACK');
    assert.equal(result.errorCode, 'HTTP_TRANSPORT');
    assert.equal(f.state().serving.image, 'blue');
    assert.equal(f.state().removed, true);
    assert.equal(f.state().locked, false);
  } finally {
    clearTimeout(timer);
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
});
