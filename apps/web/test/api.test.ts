import { afterEach, describe, expect, it, vi } from 'vitest';
import { taskApi } from '../src/api';

afterEach(() => vi.restoreAllMocks());

describe('taskApi', () => {
  it('propaga a mensagem de erro retornada pela API', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ message: 'Falha controlada' }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      }),
    );

    await expect(taskApi.list()).rejects.toThrow('Falha controlada');
  });
});
