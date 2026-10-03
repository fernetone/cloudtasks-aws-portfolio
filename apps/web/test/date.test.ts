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

  it('não derruba a interface com uma data inválida', () => {
    expect(formatDate('invalida')).toBe('Data inválida');
  });
});
