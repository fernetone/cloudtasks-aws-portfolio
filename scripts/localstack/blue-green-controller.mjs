export class DeploymentError extends Error {
  constructor(code) {
    const safe = /^[A-Z][A-Z0-9_]{0,99}$/.test(code) ? code : 'UNEXPECTED_ERROR';
    super(safe);
    this.code = safe;
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
        receipt.status = 'RECOVERY_REQUIRED';
      }
    }
  }
  try {
    await io.save(receipt);
    if (locked && receipt.status !== 'RECOVERY_REQUIRED') await io.unlock();
  } catch (error) {
    receipt.recoveryErrorCode = errorCode(error);
    receipt.status = 'RECOVERY_REQUIRED';
    // A local receipt may still be writable when S3 is unavailable.
    try { await io.save(receipt); } catch { /* Preserve resources and lock. */ }
  }
  return receipt;
}
