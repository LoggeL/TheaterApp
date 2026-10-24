// Unique figures of the stage runner's wardrobe (`runnerUniqueFigures`, from 0.11.4): every play has
// at most one, a non-human character of the play that no actor has as a role figure (Captain Kuschel
// in Creepshow, the AI in Nexus, …). It is played like the role figures (atlas, harness, portrait).
//
// - Catalog: an item with `rarity: "unique"` (the look of `uniqueFigures.rarity`, apart from the
//   rarities of the draw), `kind: "character"`, `role` (the character's name), `play`, `year`, no
//   `personId`, and `unlock: { play }` (optionally `year`): the play whose role figures unlock it.
//   One per play. Without its picture it stays `disabled` and is left out entirely, like any entry.
// - Unlock: whoever owns all active role figures of the play (actors' figures with `personId` and
//   that play, waiting ones not counted) gets it at once, for good (`uniques` in the progress
//   record): a role figure added later does not take it away. Never in crates, trades or purchases,
//   never shiny, no duplicates.
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

/** Whether the raw catalog entry [x] is a unique figure. */
export const isUniqueEntry = (x, rarity) => x?.rarity === rarity.id || list(x?.rarities).includes(rarity.id);

/** Checks a unique figure's entry; [raw] are all entries, disabled ones included. */
export function checkUniqueEntry(x, rarity, raw, bad) {
  const what = x?.id ?? JSON.stringify(x);
  if (x.kind !== 'character') bad(`${what}: a unique figure is a character`);
  if (x.rarities !== undefined && !(list(x.rarities).length === 1 && x.rarities[0] === rarity.id)) bad(`${what}: a unique figure has no other rarity`);
  if (x.personId !== undefined || x.default === true || x.reward === true || x.score !== undefined || x.variantOf !== undefined) bad(`${what}: a unique figure belongs to nobody and is no default, reward or variant`);
  if (!text(x.role) || !text(x.play) || !Number.isInteger(x.year)) bad(`${what}: a unique figure needs role, play and year`);
  const u = x.unlock;
  if (!u || typeof u !== 'object' || !text(u.play) || (u.year !== undefined && !Number.isInteger(u.year))) bad(`unlock of ${what}`);
  if (!raw.some(o => o?.kind === 'character' && o.personId !== undefined && o.play === u.play && (u.year === undefined || o.year === u.year))) bad(`unlock of ${what}: no role figure of ${u.play}`);
  const same = raw.filter(o => o?.unlock && isUniqueEntry(o, rarity) && o.unlock.play === u.play && o.unlock.year === u.year);
  if (same.length > 1) bad(`${what}: one unique figure per play (${same.map(o => o.id).join(', ')})`);
  return { play: u.play, ...(u.year !== undefined ? { year: u.year } : {}) };
}

const required = new WeakMap();
/** The active role figures of [u]'s play: owning all of them unlocks [u]. */
export function uniqueRequirement(c, u) {
  let byUnique = required.get(c);
  if (!byUnique) required.set(c, byUnique = new Map());
  if (!byUnique.has(u.id)) {
    byUnique.set(u.id, c.items.filter(x => x.kind === 'character' && x.personId !== undefined && !x.default && !x.reward && !x.unique
      && x.play === u.unlock.play && (u.unlock.year === undefined || x.year === u.unlock.year)).map(x => x.id));
  }
  return byUnique.get(u.id);
}

/** How many of [u]'s role figures [owned] has, and how many there are. */
export function uniqueCount(c, u, owned) {
  const ids = uniqueRequirement(c, u);
  return { have: ids.filter(id => owned.has(id)).length, total: ids.length };
}

/** Unique figures [p] has unlocked and the catalog has (with picture). */
export const ownedUniques = (c, p) => list(p.uniques).filter(id => c.byId.get(id)?.unique);

/**
 * [p] with every unique figure whose play [owned] completes now remembered for good (and when),
 * or [p] itself. A play without active role figures unlocks nothing.
 */
export function settleUniques(c, p, owned, at) {
  const have = new Set(list(p.uniques));
  const fresh = c.uniques.filter(u => !have.has(u.id)).filter(u => {
    const { have: n, total } = uniqueCount(c, u, owned);
    return total > 0 && n >= total;
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
 */
export function uniqueView(c, p, owned) {
  const mine = new Set(ownedUniques(c, p)), seen = new Set(list(p.uniquesSeen));
  const plays = c.uniques.map(u => {
    const { have, total } = uniqueCount(c, u, owned), unlocked = mine.has(u.id);
    if (!total && !unlocked) return null;
    const where = { play: u.unlock.play, ...(u.unlock.year !== undefined ? { year: u.unlock.year } : u.year !== undefined ? { year: u.year } : {}) };
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
