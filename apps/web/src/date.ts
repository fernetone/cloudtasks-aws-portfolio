export function formatDate(date: string | null) {
  if (!date) return 'Sem prazo';

  const dateOnly = date.slice(0, 10);
  const parsed = new Date(`${dateOnly}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime())) return 'Data inválida';

  return new Intl.DateTimeFormat('pt-BR', {
    dateStyle: 'medium',
    timeZone: 'UTC',
  }).format(parsed);
}
