function timestamp(value) {
  const parsed = typeof value === 'string' ? Date.parse(value) : NaN;
  return Number.isFinite(parsed) ? parsed : null;
}

/**
 * When a production (or anything titled like one, e.g. a gallery) ran: the premiere, else the
 * season in title or id ("Winterstück 2026" is December 2026), else null.
 * Mirrors `Production.seasonDate` in the Flutter app.
 */
export function productionSeasonTime(production) {
  const premiere = timestamp(production.premiereAt);
  if (premiere !== null) return premiere;
  const label = `${production.title ?? ''} ${production.id ?? ''}`.toLowerCase();
  const years = [...label.matchAll(/(?:^|\D)((?:19|20)\d{2})(?=\D|$)/g)].map(match => Number(match[1]));
  if (!years.length) return null;
  const month = label.includes('winter') ? 11 : label.includes('sommer') ? 6 : 0;
  return Date.UTC(Math.max(...years), month, 1);
}

// Historical imports have no premiere date. Their season still precedes a
// newer season even when an old script is imported again today.
export function productionSortTime(production) {
  return productionSeasonTime(production) ?? timestamp(production.createdAt) ?? 0;
}

export function compareProductionsNewestFirst(left, right) {
  const chronology = productionSortTime(right) - productionSortTime(left);
  if (chronology) return chronology;
  const a = (left.title ?? '').toLowerCase(), b = (right.title ?? '').toLowerCase();
  if (a !== b) return a < b ? 1 : -1;
  return left.id < right.id ? -1 : left.id > right.id ? 1 : 0;
}


/**
 * When a gallery's play ran: its linked production, else the season in its title (not the random
 * id), else its newest photo of `photoDates`, else when it was created.
 */
export function gallerySortTime(gallery, production = null, photoDates = []) {
  const photos = photoDates.map(timestamp).filter(time => time !== null);
  return (production ? productionSeasonTime(production) : null)
    ?? productionSeasonTime({ title: gallery.title })
    ?? (photos.length ? Math.max(...photos) : null)
    ?? timestamp(gallery.createdAt) ?? 0;
}

export function compareGalleriesNewestFirst(left, right) {
  return right.time - left.time || left.title.localeCompare(right.title, 'de') || left.id.localeCompare(right.id);
}
