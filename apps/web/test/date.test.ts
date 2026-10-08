import { describe, expect, it } from 'vitest';
import { formatDate } from '../src/date';

describe('formatDate', () => {
  it('formata datas ISO sem deslocamento de fuso', () => {
    expect(formatDate('2026-09-25')).toContain('25');
    expect(formatDate('2026-09-25T03:00:00.000Z')).toContain('25');
  });

  it('trata tarefas sem prazo', () => {
    expect(formatDate(null)).toBe('Sem prazo');
  });

  it('exibe prazos em texto sem tentar convertê-los em data', () => {
    expect(formatDate('Amanhã às 18h, após a reunião')).toBe('Amanhã às 18h, após a reunião');
    expect(formatDate('invalida')).toBe('invalida');
    expect(formatDate('2026-10-08 após as 18h')).toBe('2026-10-08 após as 18h');
    expect(formatDate('2026-02-31')).toBe('2026-02-31');
  });
});
