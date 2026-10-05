function timestamp(value) {
  const parsed = typeof value === 'string' ? Date.parse(value) : NaN;
  return Number.isFinite(parsed) ? parsed : null;
}

// Historical imports have no premiere date. Their season still precedes a
// newer season even when an old script is imported again today.
export function productionSortTime(production) {
  const premiere = timestamp(production.premiereAt);
  if (premiere !== null) return premiere;
  const label = `${production.title ?? ''} ${production.id ?? ''}`.toLowerCase();
  const years = [...label.matchAll(/(?:^|\D)((?:19|20)\d{2})(?=\D|$)/g)].map(match => Number(match[1]));
  if (years.length) {
    const month = label.includes('winter') ? 11 : label.includes('sommer') ? 6 : 0;
    return Date.UTC(Math.max(...years), month, 1);
  }
  return timestamp(production.createdAt) ?? 0;
}

export function compareProductionsNewestFirst(left, right) {
  const chronology = productionSortTime(right) - productionSortTime(left);
  if (chronology) return chronology;
  const a = (left.title ?? '').toLowerCase(), b = (right.title ?? '').toLowerCase();
  if (a !== b) return a < b ? 1 : -1;
  return left.id < right.id ? -1 : left.id > right.id ? 1 : 0;
}
