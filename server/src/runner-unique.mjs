// Unique figures of the stage runner's wardrobe (`runnerUniqueFigures`, from 0.11.4): every play has
// at most one, a non-human character of the play that no actor has as a role figure (Beatrice in
// Creepshow, the AI in Nexus, …), and a few belong to several plays (Captain Kuschel, in Creepshow and
// Nexus). Adolph Kolping instead needs all collectible technicians
// (`unlock: { allTechnicians: true }`). It is played like
// the role figures (atlas, harness, portrait).
//
// - Catalog: an item with `rarity: "unique"` (the look of `uniqueFigures.rarity`, apart from the
//   rarities of the draw), `kind: "character"`, `role` (the character's name), `play`, `year`, no
//   `personId`, and `unlock: { play }` (optionally `year`): the play whose role figures unlock it.
//   One per play. A figure across plays (Captain Kuschel, from 0.11.5) has `unlock: { plays: [...] }`
//   instead: two or more plays (a name, or `{ play, year }`), one figure per such set of plays.
//   Without its picture it stays `disabled` and is left out entirely, like any entry.
// - Unlock: whoever owns all active role figures of the play (actors' figures with `personId` and
//   that play, waiting ones not counted), across plays of every one of them, gets it at once, for
//   good (`uniques` in the progress record): a role figure added later does not take it away. Never
//   in crates, trades or purchases, never shiny, no duplicates.
// - Secret until unlocked: the catalog lists only the person's own unique figures; before, the view
//   shows the play's progress with `name: '???'`, without id, name or picture, and its pictures are
//   not served (404 as an unknown file). Apps from before (without `unique`) see nothing of them:
//   not in the catalog, not owned, not worn (they show the default figure instead).

const list = value => Array.isArray(value) ? value : [];
const text = v => typeof v === 'string' && v.trim() !== '';
const hex = /^#[0-9A-Fa-f]{6}$/;

/** The look of the unique figures when the catalog names none. */
export const uniqueDefaults = Object.freeze({ id: 'unique', name: 'Unique', color: '#B388FF', style: 'holo' });
/** What a unique figure is called before it is unlocked. */
export const hiddenUniqueName = '???';

/** The unique figures' look from the catalog's `uniqueFigures.rarity`; [ids] are the draw's rarities. */
export function parseUniqueRarity(data, ids, bad) {
  const r = data?.rarity ?? {};
  if (data !== undefined && (typeof data !== 'object' || data === null)) bad('uniqueFigures');
  const rarity = {
    id: text(r.id) ? r.id : uniqueDefaults.id,
    name: text(r.name) ? r.name : uniqueDefaults.name,
    color: hex.test(r.color ?? '') ? r.color : uniqueDefaults.color,
    style: text(r.style) ? r.style : uniqueDefaults.style,
  };
  if (ids.has(rarity.id)) bad(`uniqueFigures.rarity ${rarity.id} is a rarity of the draw`);
  return rarity;
}

/**
 * The plays whose role figures unlock a unique figure, as `[{ play, year? }]`: one for
 * `unlock: { play, year }`, each of `unlock: { plays: ['Creepshow', { play: 'Nexus', year: 2024 }] }`.
 */
export function unlockPlays(unlock) {
  const one = (play, year) => ({ play, ...(year !== undefined ? { year } : {}) });
  if (Array.isArray(unlock?.plays)) return unlock.plays.map(p => typeof p === 'string' ? one(p) : one(p?.play, p?.year));
  return [one(unlock?.play, unlock?.year)];
}
const playsKey = plays => plays.map(p => `${p.play}\u0000${p.year ?? ''}`).sort().join('\u0001');
/** "Creepshow", "Creepshow und Nexus", "A, B und C". */
export const playsText = names => names.length < 2 ? names.join('') : `${names.slice(0, -1).join(', ')} und ${names.at(-1)}`;
const isRoleOf = (x, p) => x?.kind === 'character' && x.personId !== undefined && x.play === p.play && (p.year === undefined || x.year === p.year);

/** Whether the raw catalog entry [x] is a unique figure. */
export const isUniqueEntry = (x, rarity) => x?.rarity === rarity.id || list(x?.rarities).includes(rarity.id);

/** Checks a unique figure's entry; [raw] are all entries, disabled ones included. */
export function checkUniqueEntry(x, rarity, raw, bad) {
  const what = x?.id ?? JSON.stringify(x);
  if (x.kind !== 'character') bad(`${what}: a unique figure is a character`);
  if (x.rarities !== undefined && !(list(x.rarities).length === 1 && x.rarities[0] === rarity.id)) bad(`${what}: a unique figure has no other rarity`);
  if (x.personId !== undefined || x.default === true || x.reward === true || x.score !== undefined || x.variantOf !== undefined) bad(`${what}: a unique figure belongs to nobody and is no default, reward or variant`);
  if (!text(x.role)) bad(`${what}: a unique figure needs a role`);
  const u = x.unlock;
  if (!u || typeof u !== 'object') bad(`unlock of ${what}`);
  if (u.allTechnicians !== undefined) {
    if (u.allTechnicians !== true || u.play !== undefined || u.plays !== undefined || u.year !== undefined
      || x.play !== undefined || x.year !== undefined) bad(`unlock of ${what}: allTechnicians has no play or year`);
    const same = raw.filter(o => isUniqueEntry(o, rarity) && o?.unlock?.allTechnicians === true);
    if (same.length > 1) bad(`${what}: one unique figure for all technicians`);
    return { allTechnicians: true };
  }
  if (!text(x.play) || !Number.isInteger(x.year)) bad(`${what}: a unique figure needs role, play and year`);
  // `{ play }` or (across plays) `{ plays }`, never both; `plays` names two or more different plays.
  const several = u.plays !== undefined;
  if (several ? u.play !== undefined || u.year !== undefined || !Array.isArray(u.plays) || u.plays.length < 2 : !text(u.play)) bad(`unlock of ${what}`);
  const plays = unlockPlays(u);
  if (plays.some(p => !text(p.play) || (p.year !== undefined && !Number.isInteger(p.year)))) bad(`unlock of ${what}`);
  if (new Set(plays.map(p => playsKey([p]))).size !== plays.length) bad(`unlock of ${what}: a play twice`);
  for (const p of plays) if (!raw.some(o => isRoleOf(o, p))) bad(`unlock of ${what}: no role figure of ${p.play}`);
  const key = playsKey(plays);
  const same = raw.filter(o => o?.unlock && !o.unlock.allTechnicians && typeof o.unlock === 'object' && isUniqueEntry(o, rarity) && playsKey(unlockPlays(o.unlock)) === key);
  if (same.length > 1) bad(`${what}: one unique figure per play (${same.map(o => o.id).join(', ')})`);
  if (several) return { plays: plays.map(p => p.year !== undefined ? { ...p } : p.play) };
  return { play: u.play, ...(u.year !== undefined ? { year: u.year } : {}) };
}

const required = new WeakMap();
/**
 * Per play of [u] (`{ play, year?, ids }`) its active role figures: owning all of them, of every
 * play, unlocks [u]. The year is the one named in `unlock`, else (one play) the figure's own, else
 * (across plays) the one all the play's role figures share. A technician unique requires
 * every active collectible character in a crew rarity, independent of the actors' roles.
 */
export function uniqueRequirement(c, u) {
  let byUnique = required.get(c);
  if (!byUnique) required.set(c, byUnique = new Map());
  if (!byUnique.has(u.id)) {
    if (u.unlock.allTechnicians) {
      const ids = c.items.filter(x => x.kind === 'character' && !x.default && !x.reward && !x.unique
        && list(x.rarities).some(id => c.rarities.some(r => r.id === id && r.crew))).map(x => x.id);
      byUnique.set(u.id, [{ play: 'Technik', ids }]);
      return byUnique.get(u.id);
    }
    const plays = unlockPlays(u.unlock), several = Array.isArray(u.unlock?.plays);
    byUnique.set(u.id, plays.map(p => {
      const roles = c.items.filter(x => isRoleOf(x, p) && !x.default && !x.reward && !x.unique);
      const years = new Set(roles.map(x => x.year));
      const year = p.year ?? (!several ? u.year : years.size === 1 ? [...years][0] : undefined);
      return { play: p.play, ...(year !== undefined ? { year } : {}), ids: roles.map(x => x.id) };
    }));
  }
  return byUnique.get(u.id);
}

/**
 * How many of [u]'s role figures [owned] has and how many there are, all together and per play
 * (`plays`); `ready`: every play has active role figures (else nothing is unlocked or shown).
 */
export function uniqueCount(c, u, owned) {
  const plays = uniqueRequirement(c, u).map(({ ids, ...p }) => ({ ...p, have: ids.filter(id => owned.has(id)).length, total: ids.length }));
  const sum = k => plays.reduce((n, p) => n + p[k], 0);
  return { have: sum('have'), total: sum('total'), plays, ready: plays.length > 0 && plays.every(p => p.total > 0) };
}

/** Unique figures [p] has unlocked and the catalog has (with picture). */
export const ownedUniques = (c, p) => list(p.uniques).filter(id => c.byId.get(id)?.unique);

/**
 * [p] with every unique figure whose plays [owned] completes now remembered for good (and when),
 * or [p] itself. A play without active role figures unlocks nothing (also not across plays).
 */
export function settleUniques(c, p, owned, at) {
  const have = new Set(list(p.uniques));
  const fresh = c.uniques.filter(u => !have.has(u.id)).filter(u => {
    const { have: n, total, ready } = uniqueCount(c, u, owned);
    return ready && n >= total;
  }).map(u => u.id);
  if (!fresh.length) return p;
  const when = at.toISOString();
  return { ...p, uniques: [...have, ...fresh], uniquesAt: { ...p.uniquesAt, ...Object.fromEntries(fresh.map(id => [id, when])) } };
}

/** [owned] without unique figures: what apps from before may see. */
export const withoutUniques = (c, owned) => new Set([...owned].filter(id => !c.byId.get(id)?.unique));

/**
 * What the app shows of the unique figures: per play its progress (`have`/`total` of the active role
 * figures), and only once unlocked its id and name; `unseen` the unlocked ones not celebrated yet.
 * Plays whose unique figure is waiting (disabled) or that have no active role figure are left out.
 * A figure across plays is one entry: `play` names them all ("Creepshow und Nexus", so apps of
 * 0.11.4 show "23/40 Rollen aus Creepshow und Nexus"), no `year`, `have`/`total` summed up, and
 * `plays` the progress per play (`{ play, year, have, total }`).
 */
export function uniqueView(c, p, owned) {
  const mine = new Set(ownedUniques(c, p)), seen = new Set(list(p.uniquesSeen));
  const plays = c.uniques.map(u => {
    const { have, total, ready, plays: parts } = uniqueCount(c, u, owned), unlocked = mine.has(u.id);
    if (!ready && !unlocked) return null;
    const where = u.unlock.allTechnicians
      ? { play: 'Technik', allTechnicians: true, plays: parts }
      : Array.isArray(u.unlock.plays)
      ? { play: playsText(parts.map(x => x.play)), plays: parts }
      : { play: u.unlock.play, ...(parts[0].year !== undefined ? { year: parts[0].year } : {}) };
    return unlocked
      ? { ...where, have, total, unlocked: true, itemId: u.id, name: u.role ?? u.name, ...(p.uniquesAt?.[u.id] ? { unlockedAt: p.uniquesAt[u.id] } : {}) }
      : { ...where, have, total, unlocked: false, hidden: true, name: hiddenUniqueName };
  }).filter(Boolean);
  return { plays, unseen: [...mine].filter(id => !seen.has(id)) };
}

/** [p] with the celebration of [ids] (unlocked ones only) shown. */
export function markUniquesSeen(c, p, ids) {
  const mine = new Set(ownedUniques(c, p)), seen = new Set(list(p.uniquesSeen));
  const fresh = list(ids).filter(id => mine.has(id) && !seen.has(id));
  return fresh.length ? { ...p, uniquesSeen: [...seen, ...fresh] } : p;
}
