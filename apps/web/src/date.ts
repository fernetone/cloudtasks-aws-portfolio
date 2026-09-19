export function formatDate(value: string): string {
  const datePart = value.slice(0, 10);
  const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(datePart);
  if (!match) return value;
  return `${match[3]}/${match[2]}/${match[1]}`;
}
