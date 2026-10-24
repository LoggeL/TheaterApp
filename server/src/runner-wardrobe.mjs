import { createHash, randomInt } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { AppError } from './theater.mjs';
import { addEnsembleMeters, countSection, ensembleCrates, ensembleRunView, ensembleState, ensembleView, grantEnsembleCrates, ownedRewards, parseEnsemble, reachedMilestones } from './runner-ensemble.mjs';

// "Garderobe" of the stage runner: every metre run counts towards costume crates; a crate holds one
// item (a character, a backdrop, an obstacle set or an effect) that the person does not own yet.
//
// - Milestones: the n-th crate needs `firstMeters + stepMeters·(n−1)` metres more than the one before
//   (2000 m, 4100 m, 6300 m, …): the same for everyone, no bonus for skill.
// - The item is drawn on the server only when a crate is opened, in two steps as in Counter-Strike:
//   first a rarity by its weight, then one of its items uniformly. Only items not owned yet take
//   part (no duplicates); a rarity with nothing left passes its chance on to the others. Items added
//   later are in the pool at once. With nothing left to draw crates pile up until new items arrive.
// - An item may belong to several rarities (a hybrid such as technician and ensemble): it can be
//   drawn through each of them and is still one item. Characters may carry a `score` instead of a
//   fixed rarity; rarities with `minScore` turn it into the rarest one reached, so moving a limit is
//   a one-line change. An `exclusive` rarity (gold) keeps its hybrids to itself: they are drawn only
//   through it, the other colour is just looks, so gold stays as rare as its chance. A rarity with `requires` (e.g. all light blue characters owned) joins the draw
//   only once that is met; until then its items show as locked with the rarity's `hint`.
// - Rarities, departments and which item has which rarity are pure catalog data
//   (server/src/wardrobe/catalog.json); pictures live next to it in server/src/wardrobe/images and are
//   served to signed-in members, so new costumes come with a server deployment, not an app release.
//   Entries with `disabled: true` (a costume whose picture is not done yet) are left out entirely.
// - Per person (`runnerProgress`): metres, opened crates, owned and selected items and how runs
//   ended. Runs from before this existed are credited once with `creditPerRound` metres each.
// - Duplicates (`runnerDupes`, only for apps that ask with `{ dupes: true }`): the rarity is drawn by
//   its weight among all open rarities, complete ones included. A rarity with something still
//   missing gives one of the missing items, as before (the basic collection stays fair); a complete
//   one gives a duplicate of one of its items: a role variant of that person if one with a picture
//   is left, else `gage` of that rarity. Every draw shines with `dupes.shinyChance`: a new item
//   comes shiny, a shiny duplicate of an item owned plainly makes it shiny instead of paying.
//   Gage buys a "Tauschvertrag" (a random missing item of the next rarity up) or one chosen missing
//   item; gold only comes from crates and trades. Older apps keep the rule without duplicates.
// - The shared "Ensemble-Strecke" of all players lives in runner-ensemble.mjs.

export const runnerUnlocks = Object.freeze({
  firstMeters: 2000, stepMeters: 100,
  // One-time credit per run played before metres were counted.
  creditPerRound: 150,
  // Older clients send no metres: count min(score, metres the measured time allows) × this factor.
  // The score contains pickups (up to 6 points per metre) and the server time contains network and
  // curtain delays, so both bounds lie above the real distance; 0.8 of the smaller one stays below it
  // for normal runs without being stingy.
  legacyMetersFactor: 0.8,
  // The reel of an opening: this many cards, the won one at `reelWinner`.
  reelLength: 56, reelWinner: 48,
  // Filler cards are drawn like a crate from all items, with rarity weight^fillerFlatten, so rare
  // colours pass by more often than they are won; now and then the rarest one stops right next to
  // the marker.
  fillerFlatten: 0.6, nearMissChance: 0.45,
});
export const wardrobeKinds = Object.freeze(['character', 'backdrop', 'obstacles', 'fx']);
// How runs end, as the client's `ObstacleKind` names; anything else counts as `unknown`.
export const runnerObstacleKinds = Object.freeze(['crate', 'flat', 'lamp', 'border', 'sandbag', 'drum', 'pile', 'truss', 'drop']);
export const crateRequestPrefix = 'runner-crate:';
export const tradeRequestPrefix = 'runner-trade:';
export const buyRequestPrefix = 'runner-buy:';
// Defaults of the catalog's `dupes`: chance of a shine per draw, and how many duplicates of a
// rarity (its `gage` each) a trade and a purchase cost.
export const dupeDefaults = Object.freeze({ shinyChance: 0.03, tradeDupes: 5, buyDupes: 10 });
// The runner's poses in a character atlas (`RunnerSprite` in the app).
export const runnerPoses = Object.freeze(['fly', 'dangle', 'runA', 'passA', 'runB', 'passB', 'cheer', 'crash']);

const fail = (status, message, code) => { throw new AppError(status, message, code); };
const list = value => Array.isArray(value) ? value : [];

/** Total metres needed for the [n]-th crate (0 for none). */
export const crateMilestone = n => {
  const { firstMeters: b, stepMeters: d } = runnerUnlocks;
  return n <= 0 ? 0 : n * b + d * n * (n - 1) / 2;
};
/** How many crates [meters] have earned in total. */
export const cratesEarned = meters => {
  const { firstMeters: b, stepMeters: d } = runnerUnlocks, m = Math.max(0, meters);
  // Solve n·b + d·n(n−1)/2 ≤ m, then correct rounding at the edges.
  let n = d ? Math.floor(((d / 2 - b) + Math.sqrt((b - d / 2) ** 2 + 2 * d * m)) / d) : Math.floor(m / b);
  while (n > 0 && crateMilestone(n) > m) n--;
  while (crateMilestone(n + 1) <= m) n++;
  return n;
};

const fileName = /^[a-z0-9][a-z0-9._-]{0,80}\.(?:webp|png)$/;
const hex = /^#[0-9A-Fa-f]{6}$/;
const imageTypes = { '.webp': 'image/webp', '.png': 'image/png' };

/**
 * Checks and indexes a catalog. Pictures are looked up in [imageDir]; a missing one is left out, so
 * an entry may come before its picture (the app then draws the default art, tinted if `tint` is set).
 */
export function loadCatalog(data, imageDir = null) {
  const bad = message => { throw new Error(`Wardrobe catalog: ${message}`); };
  const rarities = list(data?.rarities).map((r, rank) => {
    if (typeof r?.id !== 'string' || !r.id || typeof r.name !== 'string' || !hex.test(r.color ?? '') || !(r.weight > 0)) bad(`invalid rarity ${JSON.stringify(r)}`);
    if (r.minScore !== undefined && typeof r.minScore !== 'number') bad(`minScore of ${r.id}`);
    if (r.gage !== undefined && !(Number.isInteger(r.gage) && r.gage >= 0)) bad(`gage of ${r.id}`);
    return {
      id: r.id, name: r.name, color: r.color, weight: r.weight, rank,
      // What a duplicate of this rarity pays; whether one chosen item of it can be bought.
      gage: r.gage ?? 0, buyable: r.buyable !== false,
      ...(typeof r.minScore === 'number' ? { minScore: r.minScore } : {}),
      ...(r.requires ? { requires: { rarity: String(r.requires.rarity), ...(r.requires.kind ? { kind: String(r.requires.kind) } : {}) } } : {}),
      ...(typeof r.hint === 'string' && r.hint ? { hint: r.hint } : {}),
      ...(typeof r.style === 'string' && r.style ? { style: r.style } : {}),
      ...(r.exclusive === true ? { exclusive: true } : {}),
    };
  });
  if (!rarities.length) bad('no rarities');
  const rarity = new Map(rarities.map(r => [r.id, r]));
  if (rarity.size !== rarities.length) bad('duplicate rarity');
  for (const r of rarities) if (r.requires && (!rarity.has(r.requires.rarity) || r.requires.rarity === r.id || (r.requires.kind && !wardrobeKinds.includes(r.requires.kind)))) bad(`requires of ${r.id}`);
  // The rarest rarity whose limit a score reaches.
  const scored = rarities.filter(r => r.minScore !== undefined).sort((x, y) => y.minScore - x.minScore || y.rank - x.rank);
  const byScore = score => scored.find(r => score >= r.minScore)?.id;
  const departments = list(data?.departments).map(d => {
    if (typeof d?.id !== 'string' || !d.id || typeof d.name !== 'string') bad(`invalid department ${JSON.stringify(d)}`);
    return { id: d.id, name: d.name, icon: typeof d.icon === 'string' ? d.icon : null };
  });
  const department = new Set(departments.map(d => d.id));
  const dupes = { ...dupeDefaults };
  for (const [key, value] of Object.entries(data?.dupes ?? {})) {
    if (key === 'note') continue;
    if (!(key in dupeDefaults) || typeof value !== 'number' || value < 0 || (key === 'shinyChance' ? value > 1 : !Number.isInteger(value) || value < 1)) bad(`dupes.${key}`);
    dupes[key] = value;
  }
  const rawIds = new Set(list(data?.items).map(x => x?.id));
  const ensemble = parseEnsemble(data?.ensemble, rawIds, bad);
  const rewardIds = new Set((ensemble?.milestones ?? []).map(m => m.item).filter(Boolean));
  const files = new Map(), byId = new Map(), variantIds = new Set();
  const picture = name => {
    if (name === undefined || name === null) return undefined;
    if (typeof name !== 'string' || !fileName.test(name)) bad(`invalid file name ${JSON.stringify(name)}`);
    if (!files.has(name)) {
      const path = imageDir ? new URL(name, imageDir) : null;
      if (!path || !existsSync(path)) return undefined;
      const bytes = readFileSync(path);
      files.set(name, { bytes, mime: imageTypes[name.slice(name.lastIndexOf('.'))], hash: createHash('sha256').update(bytes).digest('hex').slice(0, 16) });
    }
    return `/games/runner/skins/${name}?v=${files.get(name).hash}`;
  };
  // `disabled` entries wait for their pictures: they are not part of the catalog at all, so nobody
  // draws, sees or wears them; one owned before falls back to the default when worn.
  const items = list(data?.items).filter(x => x?.disabled !== true).map(x => {
    if (typeof x?.id !== 'string' || !x.id || byId.has(x.id)) bad(`invalid or duplicate item id ${JSON.stringify(x?.id)}`);
    if (!wardrobeKinds.includes(x.kind)) bad(`unknown kind of ${x.id}`);
    if (typeof x.name !== 'string' || !x.name) bad(`name of ${x.id} missing`);
    if (x.score !== undefined && typeof x.score !== 'number') bad(`score of ${x.id}`);
    // An ensemble reward: owned by everyone once its milestone is reached, never drawn or bought.
    const reward = x.reward === true;
    if (reward !== rewardIds.has(x.id) || (reward && x.default === true)) bad(`reward ${x.id} needs exactly one ensemble milestone`);
    const fixed = x.rarities !== undefined ? list(x.rarities) : x.rarity !== undefined ? [x.rarity] : [];
    const own = reward && !fixed.length ? [ensemble.rarity.id] : [...new Set([...fixed, ...(x.score !== undefined && byScore(x.score) ? [byScore(x.score)] : [])])];
    if (!own.length || own.some(id => !rarity.has(id) && !(reward && id === ensemble.rarity.id))) bad(`unknown rarity of ${x.id}`);
    // Rarest first: the first one is the item's main colour.
    own.sort((a, b) => (rarity.get(b)?.rank ?? -1) - (rarity.get(a)?.rank ?? -1));
    // One department or several ("Bühnentechnik · Videotechnik"); only a label, never a rarity.
    const departmentIds = x.department === undefined ? [] : Array.isArray(x.department) ? x.department : [x.department];
    if (departmentIds.some(d => !department.has(d))) bad(`unknown department of ${x.id}`);
    if (x.personId !== undefined && !Number.isInteger(x.personId)) bad(`personId of ${x.id}`);
    const item = {
      id: x.id, kind: x.kind, name: x.name, rarity: own[0], rarities: own,
      ...(x.score !== undefined ? { score: x.score } : {}),
      ...(x.default === true ? { default: true } : {}),
      ...(x.placeholder === true ? { placeholder: true } : {}),
      ...(reward ? { reward: true } : {}),
      ...(departmentIds.length ? { departments: [...departmentIds] } : {}),
      ...(typeof x.rarityReason === 'string' && x.rarityReason ? { rarityReason: x.rarityReason } : {}),
      // A free label instead of the department names, e.g. "Bühnentechnik · Ensemble".
      ...(typeof x.label === 'string' && x.label ? { label: x.label } : {}),
      ...(typeof x.description === 'string' && x.description ? { description: x.description } : {}),
      ...(x.personId !== undefined ? { personId: x.personId } : {}),
      ...(x.tint && typeof x.tint === 'object' ? { tint: { hue: Number(x.tint.hue) || 0, saturation: Number(x.tint.saturation ?? 1), brightness: Number(x.tint.brightness ?? 1) } } : {}),
      ...(x.effect && typeof x.effect === 'object' ? { effect: { trail: String(x.effect.trail ?? 'sparkle'), colors: list(x.effect.colors).filter(c => hex.test(c)) } } : {}),
    };
    // The rarities it can be drawn through: only the exclusive ones if it has any.
    const exclusive = own.filter(id => rarity.get(id)?.exclusive);
    Object.defineProperty(item, 'drawnBy', { value: reward ? [] : exclusive.length ? exclusive : own, enumerable: false });
    // `image`: the atlas (or backdrop); `portrait`: a square picture for the cards.
    const image = picture(x.image), portrait = picture(x.portrait);
    if (image) item.image = image;
    if (portrait) item.portrait = portrait;
    // Where the flying wire meets a character's harness per pose, if it differs from the default.
    if (x.harness !== undefined) {
      if (!x.harness || typeof x.harness !== 'object' || Object.entries(x.harness).some(([pose, at]) => !runnerPoses.includes(pose) || !Array.isArray(at) || at.length !== 2 || !at.every(Number.isFinite))) bad(`harness of ${x.id}`);
      item.harness = x.harness;
    }
    // Role variants of a character ("Julia (Romeo und Julia, 2026)"): a duplicate may bring one.
    // Without its picture a variant is not available yet: not shown, not won, not worn.
    if (x.variants !== undefined) {
      if (x.kind !== 'character' || !Array.isArray(x.variants)) bad(`variants of ${x.id}`);
      const variants = x.variants.map(v => {
        if (typeof v?.id !== 'string' || !v.id || variantIds.has(v.id) || rawIds.has(v.id) || typeof v.name !== 'string' || !v.name) bad(`invalid variant of ${x.id}: ${JSON.stringify(v?.id)}`);
        if (v.harness !== undefined && (!v.harness || typeof v.harness !== 'object' || Object.entries(v.harness).some(([pose, at]) => !runnerPoses.includes(pose) || !Array.isArray(at) || at.length !== 2 || !at.every(Number.isFinite)))) bad(`harness of ${v.id}`);
        variantIds.add(v.id);
        const image = picture(v.image), portrait = picture(v.portrait);
        return image ? { id: v.id, name: v.name, image, ...(portrait ? { portrait } : {}), ...(v.harness ? { harness: v.harness } : {}) } : null;
      }).filter(Boolean);
      if (variants.length) item.variants = variants;
    }
    byId.set(item.id, item);
    return item;
  });
  for (const kind of wardrobeKinds) if (items.filter(x => x.kind === kind && x.default).length !== 1) bad(`exactly one default ${kind} needed`);
  // What crates, trades and purchases can bring: all but the default outfit and ensemble rewards.
  const collectible = items.filter(x => !x.default && !x.reward);
  const variantOf = new Map(items.flatMap(x => (x.variants ?? []).map(v => [v.id, x.id])));
  return { rarities, departments, items, collectible, byId, files, rarity, dupes, ensemble, variantOf, defaults: Object.fromEntries(wardrobeKinds.map(k => [k, items.find(x => x.kind === k && x.default).id])) };
}

let bundled = null;
/** The catalog shipped with the server (server/src/wardrobe). */
export const bundledCatalog = () => bundled ??= loadCatalog(JSON.parse(readFileSync(new URL('./wardrobe/catalog.json', import.meta.url), 'utf8')), new URL('./wardrobe/images/', import.meta.url));

/** Uniform in [0, 1) from the system's secure random numbers. */
export const secureRandom = () => randomInt(2 ** 47) / 2 ** 47;

/** One of [entries], each with the chance of its `weight` (to the power [power]). */
export function weightedPick(entries, random, power = 1) {
  const weights = entries.map(x => x.weight ** power), total = weights.reduce((a, b) => a + b, 0);
  let r = random() * total;
  for (const [i, w] of weights.entries()) { if ((r -= w) < 0) return entries[i]; }
  return entries.at(-1);
}

/**
 * Draws one of [items]: a rarity among the [open] ones that has items here, by its weight, then one
 * of its items uniformly; a hybrid counts in each of its rarities.
 */
export function drawItem(c, items, random, power = 1, open = null) {
  const present = c.rarities.filter(r => (!open || open.has(r.id)) && items.some(x => x.drawnBy.includes(r.id)));
  const tier = weightedPick(present, random, power), inTier = items.filter(x => x.drawnBy.includes(tier.id));
  return inTier[Math.min(inTier.length - 1, Math.floor(random() * inTier.length))];
}

/** Uniformly one of [items]. */
const pickOne = (items, random) => items[Math.min(items.length - 1, Math.floor(random() * items.length))];

/**
 * The draw with duplicates: a rarity by its weight among all [open] rarities that have collectible
 * items, complete ones included (so a complete rarity keeps its chance and gold stays rare); then
 * one of its missing items, or, if nothing of it is missing, one of all its items as a duplicate.
 */
export function drawWithDupes(c, owned, random, open) {
  const present = c.rarities.filter(r => open.has(r.id) && c.collectible.some(x => x.drawnBy.includes(r.id)));
  if (!present.length) return null;
  const tier = weightedPick(present, random);
  const inTier = c.collectible.filter(x => x.drawnBy.includes(tier.id)), missing = inTier.filter(x => !owned.has(x.id));
  return missing.length ? { tier, item: pickOne(missing, random), duplicate: false } : { tier, item: pickOne(inTier, random), duplicate: true };
}

const catalog = t => t.runnerCatalog;
const credit = runnerUnlocks.creditPerRound;

/** The person's progress record; created on first use with the credit for earlier runs. */
export function runnerProgress(t, personId) {
  const existing = t.store.get('runnerProgress', personId);
  if (existing) return existing;
  const rounds = t.store.get('runnerScores', personId)?.rounds ?? 0;
  const credited = rounds * credit;
  return t.store.put('runnerProgress', personId, { personId, meters: credited, creditedMeters: credited, creditedRounds: rounds, opened: 0, owned: [], selected: {}, deaths: {}, createdAt: t.clock().toISOString() });
}

/** The progress record with the Ensemble-Kisten of reached milestones credited. */
const progressOf = (t, personId) => grantEnsembleCrates(t, runnerProgress(t, personId), credit);

/** Item ids [p] owns: the defaults, what crates brought, the person's own character and the ensemble's rewards. */
const ownedIds = (t, p) => {
  const c = catalog(t);
  return new Set([...Object.values(c.defaults), ...list(p.owned).filter(id => c.byId.has(id)), ...c.items.filter(x => x.personId === p.personId).map(x => x.id), ...ownedRewards(t, credit)]);
};
/** Rarities that take part in [p]'s draws: all but those whose `requires` is not met yet. */
export const openRarities = (c, owned) => new Set(c.rarities.filter(r => !r.requires || c.items.every(x => x.default || x.reward || owned.has(x.id) || !x.rarities.includes(r.requires.rarity) || (r.requires.kind && x.kind !== r.requires.kind))).map(r => r.id));
const pool = (t, p, owned = ownedIds(t, p)) => {
  const c = catalog(t), open = openRarities(c, owned);
  return { items: c.collectible.filter(x => !owned.has(x.id) && x.drawnBy.some(r => open.has(r))), open };
};

export function progressView(t, p) {
  const earned = cratesEarned(p.meters), poolSize = pool(t, p).items.length;
  // `complete`: nothing new left. Apps with duplicates open crates anyway (`dupes`).
  return { meters: p.meters, earned, opened: p.opened, crates: Math.max(0, earned - p.opened), previousAt: crateMilestone(earned), nextAt: crateMilestone(earned + 1), poolSize, complete: poolSize === 0, ensembleCrates: ensembleCrates(p), dupes: true };
}

const selection = (t, p, owned = ownedIds(t, p)) => {
  const c = catalog(t);
  return Object.fromEntries(wardrobeKinds.map(k => {
    const id = p.selected?.[k];
    return [k, id && owned.has(id) && c.byId.get(id).kind === k ? id : c.defaults[k]];
  }));
};

/** Role variants [p] owns that are available (their item is owned and they have their picture). */
const ownedVariants = (c, p, owned) => list(p.variants).filter(v => c.variantOf.has(v) && owned.has(c.variantOf.get(v)));

/** The first open rarity above rank [from] with something missing: where a trade from there leads. */
export function tradeTarget(c, owned, open, from) {
  return c.rarities.find(r => r.rank > from && open.has(r.id) && c.collectible.some(x => x.drawnBy.includes(r.id) && !owned.has(x.id))) ?? null;
}
/**
 * A trade into [target] costs `tradeDupes` duplicates of the rarity right below it, also when it
 * was reached past complete rarities: a cheap rarity never buys a dear one (gold stays at 5 × red).
 */
export const tradeCost = (c, target) => c.dupes.tradeDupes * c.rarities[target.rank - 1].gage;
/** One chosen missing item costs `buyDupes` duplicates of its main rarity; null if it cannot be bought. */
export const buyCost = (c, item) => {
  const r = c.rarity.get(item.rarity);
  return r?.buyable && r.gage > 0 ? c.dupes.buyDupes * r.gage : null;
};

/** The trades on offer: one per open rarity with something missing, from the rarity below it. */
function tradeOptions(c, owned, open) {
  return c.rarities.filter(r => r.rank > 0 && c.rarities[r.rank - 1].gage > 0 && tradeTarget(c, owned, open, r.rank - 1)?.id === r.id)
    .map(r => ({ from: c.rarities[r.rank - 1].id, to: r.id, cost: tradeCost(c, r) }));
}

/** Runs, metres and how they ended; runs before the breakdown existed are counted honestly apart. */
export function statsView(t, p) {
  const score = t.store.get('runnerScores', p.personId), rounds = score?.rounds ?? 0;
  const deaths = runnerObstacleKinds.map(kind => ({ kind, count: p.deaths?.[kind] ?? 0 })).filter(x => x.count > 0).sort((x, y) => y.count - x.count || runnerObstacleKinds.indexOf(x.kind) - runnerObstacleKinds.indexOf(y.kind));
  const counted = Object.values(p.deaths ?? {}).reduce((a, b) => a + b, 0);
  return { rounds, best: score?.best ?? 0, meters: p.meters, creditedMeters: p.creditedMeters ?? 0, deaths, unknown: p.deaths?.unknown ?? 0, untracked: Math.max(0, rounds - counted) };
}

// Ensemble rewards come apart from `items`, so older apps neither count nor show them.
const catalogView = t => {
  const c = catalog(t);
  return {
    kinds: [...wardrobeKinds], rarities: c.rarities.map(({ rank, ...r }) => r), departments: c.departments,
    items: c.items.filter(x => !x.reward), rewards: c.items.filter(x => x.reward), dupes: c.dupes,
    ...(c.ensemble ? { ensembleRarity: c.ensemble.rarity } : {}),
  };
};

function view(t, p) {
  const c = catalog(t), owned = ownedIds(t, p), open = openRarities(c, owned);
  const variants = ownedVariants(c, p, owned);
  const selectedVariants = Object.fromEntries(Object.entries(p.selectedVariant ?? {}).filter(([id, v]) => variants.includes(v) && c.variantOf.get(v) === id));
  const ensemble = ensembleView(t, p, credit);
  return {
    progress: progressView(t, p), catalog: catalogView(t), lockedRarities: c.rarities.filter(r => !open.has(r.id)).map(r => r.id),
    owned: c.items.filter(x => owned.has(x.id)).map(x => x.id), selected: selection(t, p, owned), stats: statsView(t, p),
    // Added with `runnerDupes` and `runnerEnsemble`; older apps ignore them.
    shiny: list(p.shiny).filter(id => owned.has(id)), variants, selectedVariants,
    gage: { balance: p.gage ?? 0, earned: p.gageEarned ?? 0 }, trades: tradeOptions(c, owned, open),
    ...(ensemble ? { ensemble } : {}),
  };
}

/** GET /games/runner/wardrobe: progress, catalog, inventory, selection and statistics. */
export function wardrobe(t, uid) {
  return t.store.transaction(() => view(t, progressOf(t, t.account(uid).personId)));
}

/** Plausible metres of a finished run; without `meters` (older clients) a conservative estimate. */
export function runMeters(b, elapsedMs, maxMeters, { slackSeconds, tolerance }) {
  if (b.meters === undefined || b.meters === null) return Math.floor(Math.min(b.score, maxMeters(elapsedMs / 1000)) * runnerUnlocks.legacyMetersFactor);
  if (!Number.isInteger(b.meters) || b.meters < 0 || b.meters > b.score || b.meters > maxMeters(elapsedMs / 1000 + slackSeconds) * tolerance) fail(400, 'So viele Meter sind in dieser Zeit nicht möglich.', 'implausible');
  return b.meters;
}

/** Adds a finished run to the person's progress and to the ensemble (inside runnerScore's transaction). */
export function recordRun(t, personId, meters, hitBy) {
  // First: on its first use the shared distance counts what was run before, without this run.
  ensembleState(t, credit);
  const p = countSection(t, runnerProgress(t, personId), meters, credit), before = cratesEarned(p.meters);
  const kind = runnerObstacleKinds.includes(hitBy) ? hitBy : 'unknown';
  const reachedNow = addEnsembleMeters(t, meters, credit);
  const next = grantEnsembleCrates(t, t.store.put('runnerProgress', personId, { ...p, meters: p.meters + meters, deaths: { ...p.deaths, [kind]: (p.deaths?.[kind] ?? 0) + 1 } }), credit);
  const progress = progressView(t, next), ensemble = ensembleRunView(t, meters, reachedNow, credit);
  return { ...progress, gained: meters, newCrates: progress.earned - before, ...(ensemble ? { ensemble } : {}) };
}

/** Runs [fn] once per Idempotency-Key: a repeated key returns the stored result. */
function once(t, uid, prefix, requestId, action, fn) {
  if (typeof requestId !== 'string' || !requestId || requestId.length > 150) fail(400, 'Ein gültiger Änderungsschlüssel fehlt.');
  const key = prefix + requestId;
  return t.store.transaction(() => {
    const a = t.account(uid);
    const previous = t.store.db.prepare('SELECT result FROM requests WHERE uid=? AND request_id=?').get(uid, key);
    if (previous) return JSON.parse(previous.result);
    const { result, subject } = fn(a);
    t.store.db.prepare('INSERT INTO requests VALUES(?,?,?,?,?)').run(uid, key, action, JSON.stringify(result), t.clock().toISOString());
    t.store.audit(uid, action, subject);
    return result;
  });
}

/**
 * What a drawn duplicate brings [p]: a shiny one makes a plain item shiny; else a role variant still
 * missing; else the gage of the rarity it was drawn through.
 */
function duplicate(c, p, draw, shiny, random) {
  const { item, tier } = draw, shinyOwned = list(p.shiny).includes(item.id);
  if (shiny && !shinyOwned) return { next: { ...p, shiny: [...list(p.shiny), item.id] }, outcome: { type: 'shine' } };
  const missing = (item.variants ?? []).filter(v => !list(p.variants).includes(v.id));
  if (missing.length) {
    const variant = pickOne(missing, random);
    return { next: { ...p, variants: [...list(p.variants), variant.id] }, outcome: { type: 'variant', variant: { id: variant.id, name: variant.name } } };
  }
  return { next: { ...p, gage: (p.gage ?? 0) + tier.gage, gageEarned: (p.gageEarned ?? 0) + tier.gage }, outcome: { type: 'gage', gage: tier.gage } };
}

/**
 * POST /games/runner/crates: opens one crate. A repeated Idempotency-Key returns the same opening.
 * `{ dupes: true }` (apps with `runnerDupes`) draws with duplicates and shine; `crate: 'ensemble'`
 * opens an Ensemble-Kiste instead of a crate of the own metres, always shiny.
 */
export function openCrate(t, uid, requestId, b = {}) {
  const dupes = b?.dupes === true, ensemble = b?.crate === 'ensemble';
  if (ensemble && !dupes) fail(400, 'Ensemble-Kisten gibt es nur in der neuen App.');
  return once(t, uid, crateRequestPrefix, requestId, 'runner.crate', a => {
    const c = catalog(t), p = progressOf(t, a.personId);
    if (ensemble ? ensembleCrates(p) <= 0 : cratesEarned(p.meters) - p.opened <= 0) fail(409, ensemble ? 'Gerade ist keine Ensemble-Kiste da.' : 'Gerade ist keine Kostümkiste da. Lauf weiter!', 'no_crate');
    if (!dupes) {
      // Older apps: only what is still missing; with nothing left the crates stay closed.
      const { items: candidates, open } = pool(t, p);
      if (!candidates.length) fail(409, 'Der Fundus ist komplett. Neue Kostüme kommen bald – die Kisten bleiben so lange zu.', 'wardrobe_complete');
      const item = drawItem(c, candidates, t.random, 1, open);
      const next = t.store.put('runnerProgress', a.personId, { ...p, opened: p.opened + 1, owned: [...list(p.owned), item.id] });
      return { result: { item, ...reel(t, item, open), wardrobe: view(t, next) }, subject: item.id };
    }
    const owned = ownedIds(t, p), open = openRarities(c, owned);
    const draw = drawWithDupes(c, owned, t.random, open);
    if (!draw) fail(409, 'Im Fundus ist noch nichts.', 'wardrobe_complete');
    const shiny = ensemble || t.random() < c.dupes.shinyChance;
    const { next, outcome } = draw.duplicate ? duplicate(c, p, draw, shiny, t.random)
      : { next: { ...p, owned: [...list(p.owned), draw.item.id], ...(shiny ? { shiny: [...list(p.shiny), draw.item.id] } : {}) }, outcome: { type: 'new' } };
    const counted = ensemble ? { ensembleOpened: (p.ensembleOpened ?? 0) + 1 } : { opened: p.opened + 1 };
    const saved = t.store.put('runnerProgress', a.personId, { ...next, ...counted });
    const result = { item: draw.item, ...reel(t, draw.item, open), outcome: { ...outcome, duplicate: draw.duplicate, shiny, rarity: draw.tier.id, crate: ensemble ? 'ensemble' : 'costume' }, wardrobe: view(t, saved) };
    return { result, subject: `${draw.item.id}${draw.duplicate ? ` ${outcome.type}` : ''}${shiny ? ' shiny' : ''}` };
  });
}

/** POST /games/runner/trade `{ rarity }`: gage for a random missing item of the next rarity up. */
export function tradeGage(t, uid, requestId, b) {
  return once(t, uid, tradeRequestPrefix, requestId, 'runner.trade', a => {
    const c = catalog(t), from = c.rarity.get(b?.rarity);
    if (!from) fail(400, 'Unbekannte Stufe.');
    const p = progressOf(t, a.personId), owned = ownedIds(t, p), open = openRarities(c, owned);
    const target = tradeTarget(c, owned, open, from.rank);
    if (!target) fail(409, 'Darüber fehlt dir nichts mehr.', 'nothing_to_trade');
    const cost = tradeCost(c, target);
    if (!(cost > 0)) fail(409, 'Diese Stufe bringt keine Gage.', 'nothing_to_trade');
    if ((p.gage ?? 0) < cost) fail(409, 'Dafür reicht die Gage noch nicht.', 'not_enough_gage');
    const item = pickOne(c.collectible.filter(x => x.drawnBy.includes(target.id) && !owned.has(x.id)), t.random);
    const next = t.store.put('runnerProgress', a.personId, { ...p, gage: p.gage - cost, owned: [...list(p.owned), item.id] });
    return { result: { item, outcome: { type: 'trade', rarity: target.id, cost }, wardrobe: view(t, next) }, subject: `${item.id} -${cost}` };
  });
}

/** POST /games/runner/buy `{ itemId }`: one chosen missing item for gage; not gold. */
export function buyItem(t, uid, requestId, b) {
  return once(t, uid, buyRequestPrefix, requestId, 'runner.buy', a => {
    const c = catalog(t), item = c.byId.get(b?.itemId);
    if (!item || item.default || item.reward) fail(404, 'Dieses Teil gibt es nicht.');
    const p = progressOf(t, a.personId), owned = ownedIds(t, p), open = openRarities(c, owned);
    if (owned.has(item.id)) fail(409, 'Das hast du schon.', 'already_owned');
    const cost = buyCost(c, item);
    if (cost === null) fail(409, `${c.rarity.get(item.rarity)?.name ?? 'Diese Stufe'} gibt es nur aus Kisten und Tauschverträgen.`, 'not_buyable');
    if (!item.drawnBy.some(r => open.has(r))) fail(409, c.rarity.get(item.rarity)?.hint ?? 'Noch gesperrt.', 'locked');
    if ((p.gage ?? 0) < cost) fail(409, 'Dafür reicht die Gage noch nicht.', 'not_enough_gage');
    const next = t.store.put('runnerProgress', a.personId, { ...p, gage: p.gage - cost, owned: [...list(p.owned), item.id] });
    return { result: { item, outcome: { type: 'buy', rarity: item.rarity, cost }, wardrobe: view(t, next) }, subject: `${item.id} -${cost}` };
  });
}

/** PUT /games/runner/ensemble/seen `{ km }`: the celebration of milestones up to [km] was shown. */
export function ensembleSeen(t, uid, b) {
  if (!(typeof b?.km === 'number' && b.km >= 0)) fail(400, 'Ungültiger Meilenstein.');
  return t.store.transaction(() => {
    const a = t.account(uid), c = catalog(t), p = progressOf(t, a.personId);
    const highest = c.ensemble ? reachedMilestones(c.ensemble, ensembleState(t, credit).meters).at(-1)?.km ?? 0 : 0;
    const seen = Math.max(p.ensembleSeen ?? 0, Math.min(b.km, highest));
    return view(t, seen === (p.ensembleSeen ?? 0) ? p : t.store.put('runnerProgress', a.personId, { ...p, ensembleSeen: seen }));
  });
}

/** Cards for the opening animation; only the one at `winnerIndex` was drawn, the rest is show. */
function reel(t, item, open) {
  const { reelLength, reelWinner, fillerFlatten, nearMissChance } = runnerUnlocks, c = catalog(t);
  // Only what could be won: locked rarities are not teased.
  const all = c.collectible.filter(x => x.drawnBy.some(r => open.has(r)));
  const cards = Array.from({ length: reelLength }, () => drawItem(c, all, t.random, fillerFlatten, open).id);
  cards[reelWinner] = item.id;
  const rarest = all.filter(x => x.id !== item.id).sort((x, y) => c.rarity.get(y.rarity).rank - c.rarity.get(x.rarity).rank)[0];
  if (rarest && c.rarity.get(rarest.rarity).rank > c.rarity.get(item.rarity).rank && t.random() < nearMissChance) {
    cards[reelWinner + (t.random() < 0.5 ? -1 : 1)] = rarest.id;
  }
  return { reel: cards, winnerIndex: reelWinner };
}

/**
 * PUT /games/runner/outfit: wears an owned item; `{ kind, itemId }`, optionally `variant` (an owned
 * role variant of the item, or null for its own look).
 */
export function selectOutfit(t, uid, b) {
  return t.store.transaction(() => {
    const a = t.account(uid), c = catalog(t);
    if (!wardrobeKinds.includes(b?.kind)) fail(400, 'Unbekannte Art.');
    const item = c.byId.get(b.itemId);
    if (!item || item.kind !== b.kind) fail(404, 'Dieses Teil gibt es nicht.');
    const p = progressOf(t, a.personId), owned = ownedIds(t, p);
    if (!owned.has(item.id)) fail(409, 'Dieses Teil ist noch nicht in deiner Garderobe.', 'not_owned');
    const selectedVariant = { ...p.selectedVariant };
    if (b.variant === null) delete selectedVariant[item.id];
    else if (b.variant !== undefined) {
      if (c.variantOf.get(b.variant) !== item.id) fail(404, 'Diese Rolle gibt es nicht.');
      if (!ownedVariants(c, p, owned).includes(b.variant)) fail(409, 'Diese Rolle hast du noch nicht.', 'not_owned');
      selectedVariant[item.id] = b.variant;
    }
    return view(t, t.store.put('runnerProgress', a.personId, { ...p, selected: { ...p.selected, [b.kind]: item.id }, selectedVariant }));
  });
}

/** GET /games/runner/skins/<file>: a picture of the catalog, for signed-in members. */
export function skinFile(t, uid, name) {
  t.account(uid);
  const file = catalog(t).files.get(name);
  if (!file) fail(404, 'Nicht gefunden.');
  return file;
}
