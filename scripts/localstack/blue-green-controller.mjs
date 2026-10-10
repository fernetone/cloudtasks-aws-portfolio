const diagnosticOperations = new Set([
  'sts/get-caller-identity', 'codepipeline/get-pipeline-execution', 'codepipeline/list-action-executions', 'codebuild/batch-get-builds',
  's3api/put-object', 's3api/get-object', 's3api/delete-object', 'ecr/describe-images', 'ecr/describe-repositories',
  'ecs/describe-services', 'ecs/list-tasks', 'ecs/describe-tasks', 'ecs/register-task-definition', 'ecs/describe-task-definition',
  'ecs/create-service', 'ecs/update-service', 'ecs/delete-service', 'ecs/deregister-task-definition',
  'elbv2/describe-target-health', 'elbv2/register-targets', 'elbv2/deregister-targets', 'elbv2/describe-load-balancers',
  'elbv2/describe-target-groups', 'elbv2/describe-listeners', 'elbv2/describe-rules', 'elbv2/create-target-group',
  'elbv2/modify-target-group-attributes', 'elbv2/create-rule', 'elbv2/modify-listener', 'elbv2/delete-rule', 'elbv2/delete-target-group',
  'logs/describe-log-streams', 'logs/delete-log-stream', 'docker/ps', 'docker/inspect', 'docker/image', 'docker/rm',
]);

export class DeploymentError extends Error {
  constructor(code, details) {
    const safe = /^[A-Z][A-Z0-9_]{0,99}$/.test(code) ? code : 'UNEXPECTED_ERROR';
    super(safe);
    this.code = safe;
    if (details) {
      const tools = ['aws', 'docker', 'process'];
      const reasons = ['exit', 'spawn', 'timeout', 'output-limit', 'transport', 'terminated', 'unknown'];
      const signals = ['SIGTERM', 'SIGKILL', 'SIGINT', 'SIGABRT'];
      this.details = Object.freeze({
        tool: tools.includes(details.tool) ? details.tool : 'process',
        operation: diagnosticOperations.has(details.operation) ? details.operation : 'unknown',
        reason: reasons.includes(details.reason) ? details.reason : 'unknown',
        elapsedMs: Number.isSafeInteger(details.elapsedMs) && details.elapsedMs >= 0 ? details.elapsedMs : 0,
        exitCode: Number.isInteger(details.exitCode) && details.exitCode >= 0 && details.exitCode <= 255 ? details.exitCode : ['ENOENT', 'EACCES', 'E2BIG'].includes(details.exitCode) ? details.exitCode : null,
        signal: signals.includes(details.signal) ? details.signal : null,
      });
    }
  }
}

export function errorCode(error) {
  return error instanceof DeploymentError ? error.code : 'UNEXPECTED_ERROR';
}

// The IO adapter owns AWS/Docker effects. A failed run never becomes success,
// even when rollback succeeds. Recovery keeps serving resources and the lock.
export async function deployBlueGreen(io, identity) {
  const receipt = {
    ...identity,
    mode: 'LocalStackBlueGreenAdapter',
    nativeBlueGreenControllerCertified: false,
    status: 'RUNNING',
    phases: [],
  };
  let locked = false;
  let blue;
  let switching = false;
  let committed = false;
  try {
    receipt.provenance = await io.lock();
    locked = true;
    blue = await io.baseline();
    receipt.blue = blue;
    receipt.phases.push('BLUE_VERIFIED');
    await io.createCandidate();
    const green = await io.validateCandidate();
    receipt.green = green;
    receipt.isolation = await io.validateIsolation(blue, green);
    receipt.sharedData = await io.validateSharedData(blue, green);
    receipt.phases.push('CANDIDATE_VERIFIED');
    await io.save(receipt);
    // Set before the first listener update: a partial switch needs rollback.
    switching = true;
    receipt.promotion = await io.promote(green);
    receipt.phases.push('TRAFFIC_PROMOTED');
    await io.save(receipt);
    receipt.bake = await io.observe(blue, green);
    receipt.phases.push('BAKE_PASSED');
    await io.save(receipt);
    receipt.final = await io.converge(green);
    committed = true;
    receipt.phases.push('CANONICAL_VERIFIED');
    receipt.cleanup = await io.cleanup();
    receipt.status = 'SUCCEEDED';
  } catch (error) {
    receipt.errorCode = errorCode(error);
    if (error instanceof DeploymentError && error.details) receipt.errorDetails = error.details;
    receipt.status = 'REJECTED';
    if (locked && committed) {
      receipt.status = 'RECOVERY_REQUIRED';
    } else if (locked && blue) {
      try {
        if (switching) {
          receipt.rollback = await io.rollback(blue);
          receipt.status = 'ROLLED_BACK';
        }
        receipt.bluePreserved = await io.verifyBlue(blue);
        receipt.cleanup = await io.cleanup();
      } catch (recoveryError) {
        receipt.recoveryErrorCode = errorCode(recoveryError);
        if (recoveryError instanceof DeploymentError && recoveryError.details) receipt.recoveryErrorDetails = recoveryError.details;
        receipt.status = 'RECOVERY_REQUIRED';
      }
    }
  }
  try {
    await io.save(receipt);
    if (locked && receipt.status !== 'RECOVERY_REQUIRED') await io.unlock();
  } catch (error) {
    receipt.recoveryErrorCode = errorCode(error);
    if (error instanceof DeploymentError && error.details) receipt.recoveryErrorDetails = error.details;
    else delete receipt.recoveryErrorDetails;
    receipt.status = 'RECOVERY_REQUIRED';
    // A local receipt may still be writable when S3 is unavailable.
    try { await io.save(receipt); } catch { /* Preserve resources and lock. */ }
  }
  return receipt;
}
