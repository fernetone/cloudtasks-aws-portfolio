import { afterEach, describe, expect, it, vi } from 'vitest';
import { taskApi } from '../src/api';

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllGlobals();
});

describe('taskApi', () => {
  it('propaga a mensagem de erro retornada pela API', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue(
        new Response(JSON.stringify({ message: 'Falha controlada' }), {
          status: 400,
          headers: { 'Content-Type': 'application/json' },
        }),
      ),
    );

    await expect(taskApi.list()).rejects.toThrow('Falha controlada');
  });

  it('só informa saúde quando API e banco respondem corretamente', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(
      JSON.stringify({ status: 'ok', service: 'cloudtasks-api', database: 'ok' }),
      { status: 200 },
    )));
    expect(await taskApi.health()).toBe(true);
    expect(fetch).toHaveBeenCalledWith('/health', expect.objectContaining({ cache: 'no-store' }));
  });

  it.each([
    [503, { status: 'error', service: 'cloudtasks-api', database: 'unavailable' }],
    [200, { status: 'ok', service: 'cloudtasks-api', database: 'unavailable' }],
  ])('não anuncia saúde com HTTP %s e banco indisponível', async (status, body) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(JSON.stringify(body), { status })));
    expect(await taskApi.health()).toBe(false);
  });

  it('propaga falha de transporte para o indicador ficar offline', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('Connection refused')));
    await expect(taskApi.health()).rejects.toThrow('Connection refused');
  });
});
