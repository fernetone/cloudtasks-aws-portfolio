import { describe, expect, it } from 'vitest';
import { formatDate } from '../src/date';

describe('formatDate', () => {
  it('formata uma data ISO simples', () => {
    expect(formatDate('2026-09-19')).toBe('19/09/2026');
  });

  it('aceita timestamp completo sem quebrar a interface', () => {
    expect(formatDate('2026-09-19T00:00:00.000Z')).toBe('19/09/2026');
  });

  it('mantém valor desconhecido em vez de lançar erro', () => {
    expect(formatDate('data-invalida')).toBe('data-invalida');
  });
});
