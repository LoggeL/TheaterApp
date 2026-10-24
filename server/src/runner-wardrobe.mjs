import { createHash, randomInt } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { AppError } from './theater.mjs';
import { berlinDay } from './event-series.mjs';
import { missionsView, recordMissionRun } from './runner-missions.mjs';
import { crateView, markEventCrateOpened, nextEventCrate, waitingEventCrates } from './runner-event-crates.mjs';
import { migrateToRoleFigures, olderAppDeal, olderAppOpening, olderAppOutfit, olderAppView, roleFiguresModel } from './runner-role-figures.mjs';
import { addEnsembleMeters, countSection, ensembleCrates, ensembleRunView, ensembleState, ensembleView, grantEnsembleCrates, ownedRewards, parseEnsemble, reachedMilestones, revealedRewards } from './runner-ensemble.mjs';
import { checkUniqueEntry, isUniqueEntry, markUniquesSeen, ownedUniques, parseUniqueRarity, settleUniques, uniqueView, withoutUniques } from './runner-unique.mjs';

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
//   through it, the other colour is just looks, so gold stays as rare as its chance. A rarity with `requires` (e.g. 10 light blue characters owned, or all of them without `count`) joins the draw
//   only once that is met; until then its items show as locked with the rarity's `hint`. Once met it
//   stays open for that person (`unlockedRarities`), even if the catalog changes later.
// - Role figures (`runnerRoleFigures`, catalog `roleFigures: true`): every stage role of an actor
//   (person × play × role) is a figure of its own with its own rarity; a technician is one figure
//   across all plays (a `crew` rarity, `role` is the function, no play or year). Apps from before
//   knew one figure per person with role variants: they get a view of the same ownership in that
//   shape (runner-role-figures.mjs), apps that ask with `roles` get the figures as they are.
// - Rarities, departments and which item has which rarity are pure catalog data
//   (server/src/wardrobe/catalog.json); pictures live next to it in server/src/wardrobe/images (the
//   backdrops' music in server/src/wardrobe/music) and are served to signed-in members, so new costumes come with a server deployment, not an app release.
//   Entries with `disabled: true` (a costume whose picture is not done yet) are left out entirely.
// - Per person (`runnerProgress`): metres, opened crates, owned and selected items and how runs
//   ended. Runs from before this existed are credited once with `creditPerRound` metres each.
// - Duplicates (`runnerDupes`, only for apps that ask with `{ dupes: true }`): the rarity is drawn by
//   its weight among all open rarities, complete ones included. A rarity with something still
//   missing gives one of the missing items, as before (the basic collection stays fair); a complete
//   one gives a duplicate of one of its items: its shine if it has none yet and the draw shines,
//   else `gage` of that rarity (role variants were a step here before role figures). Every draw shines with the chance of its crate kind
//   (`dupes.shinyChance`, e.g. `{ costume: 0.03, ensemble: 0.03 }`): a new item
//   comes shiny, a shiny duplicate of an item owned plainly makes it shiny instead of paying.
//   Gage buys a "Tauschvertrag" (a random missing item of the next rarity up) or one chosen missing
//   item; gold only comes from crates and trades. Older apps keep the rule without duplicates.
// - Tagesbonus (`runnerDailyBonus`): the first counted run of a Europe/Berlin calendar day with more
//   than 0 m is credited a second time as bonus metres. They count only towards the crates: the
//   "Kistenstrecke" is the real metres plus all bonus metres (`progress.meters`); statistics, best
//   score and the Ensemble-Strecke keep the real metres. No cooldown, no diminishing returns.
// - The shared "Ensemble-Strecke" of all players lives in runner-ensemble.mjs, the private
//   "Termin-Kiste" for an own commitment to an event (`runnerEventCrates`) in runner-event-crates.mjs.
// - Unique figures (`runnerUniqueFigures`, `rarity: "unique"`): one non-human character per play,
//   unlocked by owning all of the play's active role figures, a secret until then; see
//   runner-unique.mjs. Apps ask for them with `unique`; apps from before never see them.

export const runnerUnlocks = Object.freeze({
  // Crates of the own runs count points (`runnerCratePoints`): the n-th crate needs
  // `firstPoints + stepPoints·√(n−1)` points more than the one before (rounded to `stepRound`), so the
  // way grows with the square root and gets less steep the further one is. Calibrated on a run's
  // points: one point per metre plus about half of the ~1 point per metre the course lays out as
  // pickups, i.e. ~1.5 points per metre; the first crate needs about as many runs as 2000 m did.
  firstPoints: 3000, stepPoints: 300, stepRound: 10,
  // The metre curve before (`firstMeters + stepMeters·(n−1)`), only to move records over.
  firstMeters: 2000, stepMeters: 100,
  // Most pickup points a section holds (a star; 3 roses 15, 2 masks 20) and the shortest section (a
  // gap of 0.6 stage heights plus an obstacle, 6.7 m; counted as 6 m, plus 2 sections of slack):
  // a run's points beyond its metres can never be more (the same count as checkRunStats).
  pickupRowPoints: 25, sectionMeters: 6, extraSections: 2,
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
// Defaults of the catalog's `dupes`: chance of a shine per draw by crate kind (`costume` for the
// crates of the own metres, `ensemble`, …; a kind not listed has the chance of `costume`), and how
// many duplicates of a rarity (its `gage` each) a trade and a purchase cost.
export const dupeDefaults = Object.freeze({ shinyChance: Object.freeze({ costume: 0.03, ensemble: 0.03 }), tradeDupes: 5, buyDupes: 10 });
/** The chance of a shine for one draw from a crate of [kind]. */
export const shinyChanceOf = (c, kind) => c.dupes.shinyChance[kind] ?? c.dupes.shinyChance.costume;
// The runner's poses in a character atlas (`RunnerSprite` in the app).
export const runnerPoses = Object.freeze(['fly', 'dangle', 'runA', 'passA', 'runB', 'passB', 'cheer', 'crash']);

const fail = (status, message, code) => { throw new AppError(status, message, code); };
const list = value => Array.isArray(value) ? value : [];

/** Points between the ([n]−1)-th and the [n]-th crate (n ≥ 1): grows with the square root. */
export const crateGap = n => {
  const { firstPoints: b, stepPoints: d, stepRound: r } = runnerUnlocks;
  return b + Math.round(d * Math.sqrt(Math.max(0, n - 1)) / r) * r;
};
// Milestones computed so far (index n: points for the n-th crate); they only ever grow.
const milestones = [0];
/** Total points needed for the [n]-th crate (0 for none). */
export const crateMilestone = n => {
  if (!(n > 0)) return 0;
  while (milestones.length <= n) milestones.push(milestones.at(-1) + crateGap(milestones.length));
  return milestones[n];
};
/** How many crates [points] have earned in total. */
export const cratesEarned = points => {
  const p = Number.isFinite(points) ? Math.max(0, points) : 0;
  // Double up to a milestone beyond, then halve the way back.
  let low = 0, high = 1;
  while (crateMilestone(high) <= p) { low = high; high *= 2; }
  while (high - low > 1) {
    const mid = Math.floor((low + high) / 2);
    if (crateMilestone(mid) <= p) low = mid; else high = mid;
  }
  return low;
};

/** The metre curve before `runnerCratePoints`: total metres for the [n]-th crate. */
export const legacyCrateMilestone = n => {
  const { firstMeters: b, stepMeters: d } = runnerUnlocks;
  return n <= 0 ? 0 : n * b + d * n * (n - 1) / 2;
};
/** How many crates [meters] had earned on the metre curve. */
export const legacyCratesEarned = meters => {
  const { firstMeters: b, stepMeters: d } = runnerUnlocks, m = Math.max(0, meters);
  // Solve n·b + d·n(n−1)/2 ≤ m, then correct rounding at the edges.
  let n = d ? Math.floor(((d / 2 - b) + Math.sqrt((b - d / 2) ** 2 + 2 * d * m)) / d) : Math.floor(m / b);
  while (n > 0 && legacyCrateMilestone(n) > m) n--;
  while (legacyCrateMilestone(n + 1) <= m) n++;
  return n;
};

/** Most points a run of [meters] can hold: its metres and one row of pickups per section. */
export const maxRunPoints = meters => {
  const { pickupRowPoints, sectionMeters, extraSections } = runnerUnlocks;
  return meters + Math.floor(pickupRowPoints * (meters / sectionMeters + extraSections));
};

/**
 * The crate points of a finished run: its score, which must fit its metres (`maxRunPoints`, else 400
 * `implausible`, like metres that do not fit the time). Older clients without metres get their score
 * up to what the estimated metres allow.
 */
export function runPoints(b, meters) {
  if (b.meters === undefined || b.meters === null) return Math.min(b.score, maxRunPoints(meters));
  if (b.score > maxRunPoints(meters)) fail(400, 'So viele Punkte sind auf dieser Strecke nicht möglich.', 'implausible');
  return b.score;
}

/** The progress model whose crates count points. */
export const cratePointsModel = 1;
/** The old "Kistenstrecke" of [p]: metres run plus Tagesbonus and mission metres. */
export const legacyCrateMeters = p => (p.meters ?? 0) + (p.bonusMeters ?? 0) + (p.missionMeters ?? 0);

/**
 * [p] moved from crate metres to crate points, or null if it is there already. Nobody loses: the
 * crates earned on the metre curve and the share of the way to the next one become `basePoints` on
 * the point curve (rounded up), so `earned` stays and the bar stands where it stood; `opened`, the
 * metres and everything else stay as they are. Once per record (`crateModel`), on its first use.
 */
export function migrateToCratePoints(p, at) {
  if ((p.crateModel ?? 0) >= cratePointsModel) return null;
  const meters = legacyCrateMeters(p), earned = legacyCratesEarned(meters);
  const from = legacyCrateMilestone(earned), span = legacyCrateMilestone(earned + 1) - from;
  // Whole numbers throughout: ceil((meters − from) · gap / span) is exact.
  const way = Math.ceil((meters - from) * crateGap(earned + 1) / span);
  return {
    ...p, crateModel: cratePointsModel, basePoints: crateMilestone(earned) + way, points: 0, bonusPoints: 0, missionPoints: 0,
    cratePointsAt: at.toISOString(), crateMetersBefore: { meters, earned, share: Math.round((meters - from) / span * 1000) / 1000 },
  };
}

const fileName = /^[a-z0-9][a-z0-9._-]{0,80}\.(?:webp|png)$/;
const hex = /^#[0-9A-Fa-f]{6}$/;
const imageTypes = { '.webp': 'image/webp', '.png': 'image/png' };
// A backdrop's music: AAC in M4A (loops without a gap in browsers and on Android) or MP3.
const musicName = /^[a-z0-9][a-z0-9._-]{0,80}\.(?:m4a|mp3)$/;
const musicTypes = { '.m4a': 'audio/mp4', '.mp3': 'audio/mpeg' };

/**
 * The role a character or variant plays, e.g. `{ role: 'Lucy', play: 'Creepshow', year: 2026 }`.
 * All three are optional (older catalogs, older apps); a bad value breaks the catalog.
 */
function roleFields(x, bad, what) {
  const text = v => v === undefined || (typeof v === 'string' && v.trim() !== '');
  if (!text(x.role) || !text(x.play)) bad(`role or play of ${what}`);
  if (x.year !== undefined && !(Number.isInteger(x.year) && x.year >= 1900 && x.year <= 2100)) bad(`year of ${what}`);
  return roleOf(x);
}
const roleOf = x => Object.fromEntries(['role', 'play', 'year'].filter(k => x[k] !== undefined).map(k => [k, x[k]]));
export { roleName } from './runner-role-figures.mjs';

/**
 * Checks and indexes a catalog. Pictures are looked up in [imageDir], music in [musicDir]; a missing
 * file is left out, so an entry may come before its picture (the app then draws the default art,
 * tinted if `tint` is set) or its music (the app plays the game's own tune).
 */
export function loadCatalog(data, imageDir = null, musicDir = imageDir) {
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
      // `count`: that many owned items of the rarity open it; without it all of them.
      ...(r.requires ? { requires: { rarity: String(r.requires.rarity), ...(r.requires.kind ? { kind: String(r.requires.kind) } : {}), ...(r.requires.count !== undefined ? { count: r.requires.count } : {}) } } : {}),
      ...(typeof r.hint === 'string' && r.hint ? { hint: r.hint } : {}),
      ...(typeof r.style === 'string' && r.style ? { style: r.style } : {}),
      ...(r.exclusive === true ? { exclusive: true } : {}),
      // The technicians' rarity: its figures carry a function as `role`, never a play or year.
      ...(r.crew === true ? { crew: true } : {}),
    };
  });
  if (!rarities.length) bad('no rarities');
  const rarity = new Map(rarities.map(r => [r.id, r]));
  if (rarity.size !== rarities.length) bad('duplicate rarity');
  for (const r of rarities) if (r.requires && (!rarity.has(r.requires.rarity) || r.requires.rarity === r.id || (r.requires.kind && !wardrobeKinds.includes(r.requires.kind)) || (r.requires.count !== undefined && !(Number.isInteger(r.requires.count) && r.requires.count > 0)))) bad(`requires of ${r.id}`);
  // The rarest rarity whose limit a score reaches.
  const scored = rarities.filter(r => r.minScore !== undefined).sort((x, y) => y.minScore - x.minScore || y.rank - x.rank);
  const byScore = score => scored.find(r => score >= r.minScore)?.id;
  const departments = list(data?.departments).map(d => {
    if (typeof d?.id !== 'string' || !d.id || typeof d.name !== 'string') bad(`invalid department ${JSON.stringify(d)}`);
    return { id: d.id, name: d.name, icon: typeof d.icon === 'string' ? d.icon : null };
  });
  const department = new Set(departments.map(d => d.id));
  const dupes = { ...dupeDefaults, shinyChance: { ...dupeDefaults.shinyChance } };
  const chance = value => typeof value === 'number' && value >= 0 && value <= 1;
  for (const [key, value] of Object.entries(data?.dupes ?? {})) {
    if (key === 'note') continue;
    if (key === 'shinyChance') {
      // One number for every crate kind, or one per kind.
      if (chance(value)) { for (const kind of Object.keys(dupes.shinyChance)) dupes.shinyChance[kind] = value; continue; }
      if (!value || typeof value !== 'object' || Array.isArray(value)) bad('dupes.shinyChance');
      for (const [kind, v] of Object.entries(value)) {
        if (!/^[a-z][a-z0-9-]{0,30}$/.test(kind) || !chance(v)) bad(`dupes.shinyChance.${kind}`);
        dupes.shinyChance[kind] = v;
      }
      continue;
    }
    if (!(key in dupeDefaults) || typeof value !== 'number' || !Number.isInteger(value) || value < 1) bad(`dupes.${key}`);
    dupes[key] = value;
  }
  const rawIds = new Set(list(data?.items).map(x => x?.id));
  // Role figures: every figure of a person is one role, waiting ones (`disabled`) included.
  const roleFigures = data?.roleFigures === true;
  if (roleFigures) for (const x of list(data?.items)) checkRoleFigure(x, rarity, rawIds, list(data?.items), bad);
  const ensemble = parseEnsemble(data?.ensemble, rawIds, bad);
  // The unique figures' look: apart from the draw's rarities, like the ensemble's.
  const uniqueRarity = parseUniqueRarity(data?.uniqueFigures, rarity, bad);
  // Every unique figure is checked, waiting ones (`disabled`) included.
  for (const x of list(data?.items)) if (isUniqueEntry(x, uniqueRarity)) checkUniqueEntry(x, uniqueRarity, list(data?.items), bad);
  const rewardIds = new Set((ensemble?.milestones ?? []).map(m => m.item).filter(Boolean));
  const files = new Map(), byId = new Map();
  // Pictures and music share one route (`/games/runner/skins/<file>`); their names never overlap.
  const asset = (name, dir, pattern, types) => {
    if (name === undefined || name === null) return undefined;
    if (typeof name !== 'string' || !pattern.test(name)) bad(`invalid file name ${JSON.stringify(name)}`);
    if (!files.has(name)) {
      const path = dir ? new URL(name, dir) : null;
      if (!path || !existsSync(path)) return undefined;
      const bytes = readFileSync(path);
      files.set(name, { bytes, mime: types[name.slice(name.lastIndexOf('.'))], hash: createHash('sha256').update(bytes).digest('hex').slice(0, 16) });
    }
    return `/games/runner/skins/${name}?v=${files.get(name).hash}`;
  };
  const picture = name => asset(name, imageDir, fileName, imageTypes);
  const tune = name => asset(name, musicDir, musicName, musicTypes);
  // `disabled` entries wait for their pictures: they are not part of the catalog at all, so nobody
  // draws, sees or wears them; one owned before falls back to the default when worn.
  const items = list(data?.items).filter(x => x?.disabled !== true).map(x => {
    if (typeof x?.id !== 'string' || !x.id || byId.has(x.id)) bad(`invalid or duplicate item id ${JSON.stringify(x?.id)}`);
    if (!wardrobeKinds.includes(x.kind)) bad(`unknown kind of ${x.id}`);
    if (typeof x.name !== 'string' || !x.name) bad(`name of ${x.id} missing`);
    if (x.score !== undefined && typeof x.score !== 'number') bad(`score of ${x.id}`);
    // How much the role carries its play (0–100), from which its rarity was chosen; only shown.
    if (x.importance !== undefined && !(typeof x.importance === 'number' && x.importance >= 0 && x.importance <= 100)) bad(`importance of ${x.id}`);
    if (x.variants !== undefined) bad(`variants of ${x.id}: a role is a figure of its own now (an item with variantOf)`);
    // An ensemble reward: owned by everyone once its milestone is reached, never drawn or bought.
    const reward = x.reward === true;
    if (reward !== rewardIds.has(x.id) || (reward && x.default === true)) bad(`reward ${x.id} needs exactly one ensemble milestone`);
    // A unique figure: unlocked by all role figures of its play, never drawn, traded or bought.
    const unique = isUniqueEntry(x, uniqueRarity), unlock = unique ? checkUniqueEntry(x, uniqueRarity, list(data?.items), bad) : null;
    const fixed = x.rarities !== undefined ? list(x.rarities) : x.rarity !== undefined ? [x.rarity] : [];
    const own = reward && !fixed.length ? [ensemble.rarity.id] : [...new Set([...fixed, ...(x.score !== undefined && byScore(x.score) ? [byScore(x.score)] : [])])];
    if (!own.length || own.some(id => !rarity.has(id) && !(reward && id === ensemble.rarity.id) && !(unique && id === uniqueRarity.id))) bad(`unknown rarity of ${x.id}`);
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
      ...(unique ? { unique: true, unlock } : {}),
      ...(departmentIds.length ? { departments: [...departmentIds] } : {}),
      ...(typeof x.rarityReason === 'string' && x.rarityReason ? { rarityReason: x.rarityReason } : {}),
      // A free label instead of the department names, e.g. "Bühnentechnik · Ensemble".
      ...(typeof x.label === 'string' && x.label ? { label: x.label } : {}),
      ...(typeof x.description === 'string' && x.description ? { description: x.description } : {}),
      ...(x.personId !== undefined ? { personId: x.personId } : {}),
      // The person's role on this figure (`role`, `play`, `year`); `name` stays the person's name.
      ...roleFields(x, bad, x.id),
      ...(x.importance !== undefined ? { importance: x.importance } : {}),
      ...(x.tint && typeof x.tint === 'object' ? { tint: { hue: Number(x.tint.hue) || 0, saturation: Number(x.tint.saturation ?? 1), brightness: Number(x.tint.brightness ?? 1) } } : {}),
      ...(x.effect && typeof x.effect === 'object' ? { effect: { trail: String(x.effect.trail ?? 'sparkle'), colors: list(x.effect.colors).filter(c => hex.test(c)) } } : {}),
    };
    // The rarities it can be drawn through: only the exclusive ones if it has any.
    const exclusive = own.filter(id => rarity.get(id)?.exclusive);
    Object.defineProperty(item, 'drawnBy', { value: reward || unique ? [] : exclusive.length ? exclusive : own, enumerable: false });
    // `image`: the atlas (or backdrop); `portrait`: a square picture for the cards.
    const image = picture(x.image), portrait = picture(x.portrait);
    if (image) item.image = image;
    if (portrait) item.portrait = portrait;
    // A backdrop's own obstacle set (`obstacles`: an atlas in the layout of the obstacles, only an
    // asset, never drawn or worn on its own) and the colour of its border, the short curtain the
    // game draws (`borderColor`). Both optional; older apps ignore them.
    if (x.obstacles !== undefined) {
      if (x.kind !== 'backdrop') bad(`obstacles of ${x.id}`);
      const set = picture(x.obstacles);
      if (set) item.obstacles = set;
    }
    if (x.borderColor !== undefined) {
      if (x.kind !== 'backdrop' || !hex.test(x.borderColor)) bad(`borderColor of ${x.id}`);
      item.borderColor = x.borderColor;
    }
    // Its own collectibles (`collectibles`: an atlas in the same layout, only the pickups used) and
    // what they are called (`collectibleNames`: { rose, mask, star }); the points stay the same.
    if (x.collectibles !== undefined) {
      if (x.kind !== 'backdrop') bad(`collectibles of ${x.id}`);
      const set = picture(x.collectibles);
      if (set) item.collectibles = set;
    }
    if (x.collectibleNames !== undefined) {
      const names = x.collectibleNames;
      if (x.kind !== 'backdrop' || !names || typeof names !== 'object' || Array.isArray(names)
        || Object.entries(names).some(([k, v]) => !['rose', 'mask', 'star'].includes(k) || typeof v !== 'string' || !v.trim())) bad(`collectibleNames of ${x.id}`);
      item.collectibleNames = { ...names };
    }
    // A backdrop's own music, which the app loops while the backdrop is worn (`music`, optional;
    // older apps ignore it and play the game's own tune, as does a backdrop without one).
    if (x.music !== undefined) {
      if (x.kind !== 'backdrop') bad(`music of ${x.id}`);
      const music = tune(x.music);
      if (music) item.music = music;
    }
    // Where the flying wire meets a character's harness per pose, if it differs from the default.
    if (x.harness !== undefined) {
      if (!x.harness || typeof x.harness !== 'object' || Object.entries(x.harness).some(([pose, at]) => !runnerPoses.includes(pose) || !Array.isArray(at) || at.length !== 2 || !at.every(Number.isFinite))) bad(`harness of ${x.id}`);
      item.harness = x.harness;
    }
    // A role figure that apps from before role figures show as a role variant of `variantOf` (the
    // person's figure they knew); only for that view, never part of an item.
    if (x.variantOf !== undefined) {
      const base = list(data?.items).find(o => o?.id === x.variantOf);
      if (x.kind !== 'character' || base?.kind !== 'character' || base.variantOf !== undefined || base.default === true) bad(`variantOf of ${x.id}`);
      Object.defineProperty(item, 'variantOf', { value: x.variantOf, enumerable: false });
    }
    byId.set(item.id, item);
    return item;
  });
  for (const kind of wardrobeKinds) if (items.filter(x => x.kind === kind && x.default).length !== 1) bad(`exactly one default ${kind} needed`);
  // What crates, trades and purchases can bring: all but the default outfit, ensemble rewards and unique figures.
  const collectible = items.filter(x => !x.default && !x.reward && !x.unique);
  const uniques = items.filter(x => x.unique);
  // For apps before role figures: figure → the person's figure it is a variant of (both available),
  // and that figure → its variants in catalog order.
  const baseOf = new Map(items.filter(x => x.variantOf && byId.has(x.variantOf)).map(x => [x.id, x.variantOf]));
  const rolesOf = new Map();
  for (const [id, base] of baseOf) rolesOf.set(base, [...(rolesOf.get(base) ?? []), byId.get(id)]);
  // Files only ensemble rewards use (name → their ids): not served before a milestone reveals one.
  const users = new Map();
  for (const x of items) for (const key of ['image', 'portrait', 'obstacles', 'collectibles', 'music']) {
    const name = typeof x[key] === 'string' ? x[key].match(/\/skins\/([^?]+)/)?.[1] : null;
    if (name) users.set(name, [...(users.get(name) ?? []), x]);
  }
  const rewardFiles = new Map([...users].filter(([, xs]) => xs.every(x => x.reward)).map(([name, xs]) => [name, xs.map(x => x.id)]));
  // Files only unique figures use: served only to those who unlocked one of them.
  const uniqueFiles = new Map([...users].filter(([, xs]) => xs.every(x => x.unique)).map(([name, xs]) => [name, xs.map(x => x.id)]));
  const { crateTargets, targetItems } = crateTargetsOf(collectible, rarity, data?.crates, picture, bad);
  return { rarities, departments, items, collectible, uniques, uniqueRarity, byId, files, rewardFiles, uniqueFiles, rarity, dupes, ensemble, roleFigures, baseOf, rolesOf, crateTargets, targetItems, defaults: Object.fromEntries(wardrobeKinds.map(k => [k, items.find(x => x.kind === k && x.default).id])) };
}

// Crate targets (`runnerCrateTargets`): a crate of the own runs is opened as the Zufallskiste (all
// collectible items, as before) or aimed at one pool: a play (its role figures, derived from the
// catalog: every play with active role figures) or the Technik-Kiste (the technicians, a `crew`
// rarity). Unique figures, ensemble rewards and the default outfit are in no pool.
/** The animations an app knows for opening a crate; anything else plays `generic`. */
export const crateAnimations = Object.freeze(['generic', 'burst', 'flightcase', 'maw', 'glitch', 'heavy', 'threads']);
/** A play's name as part of an id or file name: "Schicksalsfäden" → "schicksalsfaeden". */
export const playSlug = name => name.toLowerCase().replace(/ä/g, 'ae').replace(/ö/g, 'oe').replace(/ü/g, 'ue').replace(/ß/g, 'ss')
  .normalize('NFKD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || 'stueck';

/**
 * The targets of [collectible], newest play first: `{ id, kind: 'random' | 'tech' | 'play', name,
 * play?, year?, animation, image?, openImage?, fxImage? }`, and their items by id. Pictures by name
 * if they exist: `crate-<x>.webp` (closed), `crate-<x>-open.webp` (open, the same frame) and
 * `crate-<x>-fx.webp` (particles), `<x>` being `random`, `tech` or `play-<slug>`. The catalog's
 * `crates` (by target id) chooses an `animation` of `crateAnimations`; without one `generic`. Its
 * `box` (`[x0, y0, x1, y1]`, pixels of the closed picture) is where the crate stands on its canvas,
 * which leaves room above for the open lid: the choice shows just that part (`imageBox`).
 */
function crateTargetsOf(collectible, rarity, data, picture, bad) {
  if (data !== undefined && (!data || typeof data !== 'object' || Array.isArray(data))) bad('crates');
  const looks = Object.fromEntries(Object.entries(data ?? {}).filter(([key]) => key !== 'note'));
  for (const [key, look] of Object.entries(looks)) {
    if (!look || typeof look !== 'object' || (look.animation !== undefined && !crateAnimations.includes(look.animation))) bad(`crates.${key}`);
    const box = look.box;
    if (box !== undefined && !(Array.isArray(box) && box.length === 4 && box.every(v => Number.isInteger(v) && v >= 0 && v <= 4096) && box[0] < box[2] && box[1] < box[3])) bad(`crates.${key}.box`);
  }
  const crew = x => x.rarities.some(id => rarity.get(id)?.crew);
  const plays = new Map();
  for (const x of collectible) {
    if (x.kind !== 'character' || typeof x.play !== 'string' || crew(x)) continue;
    const key = `${x.play}\u0000${x.year ?? ''}`;
    if (!plays.has(key)) plays.set(key, { play: x.play, year: x.year, items: [] });
    plays.get(key).items.push(x);
  }
  // The same name in two years gets the year in its id.
  const slugs = new Map();
  for (const p of plays.values()) slugs.set(playSlug(p.play), (slugs.get(playSlug(p.play)) ?? 0) + 1);
  const sorted = [...plays.values()].sort((a, b) => (b.year ?? 0) - (a.year ?? 0) || a.play.localeCompare(b.play, 'de'));
  const tech = collectible.filter(x => x.kind === 'character' && crew(x));
  const entries = [
    { id: 'random', kind: 'random', name: 'Zufallskiste', file: 'random', items: collectible },
    ...(tech.length ? [{ id: 'tech', kind: 'tech', name: 'Technik-Kiste', file: 'tech', items: tech }] : []),
    ...sorted.map(p => {
      const slug = slugs.get(playSlug(p.play)) > 1 && p.year !== undefined ? `${playSlug(p.play)}-${p.year}` : playSlug(p.play);
      return { id: `play:${slug}`, kind: 'play', name: p.play, play: p.play, ...(p.year !== undefined ? { year: p.year } : {}), file: `play-${slug}`, items: p.items };
    }),
  ];
  for (const key of Object.keys(looks)) if (!entries.some(e => e.id === key)) bad(`crates.${key}: no such crate`);
  const targetItems = new Map(entries.map(e => [e.id, e.items]));
  const crateTargets = entries.map(({ file, items, ...e }) => {
    const [image, openImage, fxImage] = ['', '-open', '-fx'].map(part => picture(`crate-${file}${part}.webp`));
    const box = image && looks[e.id]?.box;
    return { ...e, animation: looks[e.id]?.animation ?? 'generic', ...(image ? { image } : {}), ...(box ? { imageBox: [...box] } : {}), ...(openImage ? { openImage } : {}), ...(fxImage ? { fxImage } : {}) };
  });
  return { crateTargets, targetItems };
}

/**
 * What the app shows of each target for [owned] and the [open] rarities: `owned`/`total` (all its
 * items, locked ones included), `locked` (missing ones not to be drawn yet), `complete`, `available`
 * (something can be drawn: a complete pool still gives duplicates), its shine chance and the
 * chance of each rarity within it.
 */
export function crateTargetsView(c, owned, open) {
  return c.crateTargets.map(target => {
    const items = c.targetItems.get(target.id), drawable = items.filter(x => x.drawnBy.some(r => open.has(r)));
    const have = items.filter(x => owned.has(x.id)).length;
    const present = c.rarities.filter(r => open.has(r.id) && drawable.some(x => x.drawnBy.includes(r.id)));
    const total = present.reduce((sum, r) => sum + r.weight, 0);
    return {
      ...target, owned: have, total: items.length, locked: items.filter(x => !owned.has(x.id) && !drawable.includes(x)).length,
      complete: have === items.length, available: drawable.length > 0,
      shinyChance: shinyChanceOf(c, target.kind === 'random' ? 'costume' : 'targeted'),
      odds: present.map(r => ({ rarity: r.id, chance: r.weight / total })),
    };
  });
}

/**
 * With role figures: an actor's figure (a character with `personId`) is one role, with `role`, `play`
 * and `year`; a technician's (a `crew` rarity) has the function as `role` and no play or year.
 */
function checkRoleFigure(x, rarity, rawIds, raw, bad) {
  if (x?.kind !== 'character' || x.personId === undefined) return;
  const own = x.rarities !== undefined ? list(x.rarities) : x.rarity !== undefined ? [x.rarity] : [];
  const text = v => typeof v === 'string' && v.trim() !== '';
  if (!text(x.role)) bad(`role of ${x.id} missing`);
  if (own.some(id => rarity.get(id)?.crew)) {
    if (x.play !== undefined || x.year !== undefined) bad(`${x.id}: a technician has a function, no play or year`);
    if (own.length > 1) bad(`${x.id}: a technician is one figure of one rarity`);
  } else if (!text(x.play) || !Number.isInteger(x.year)) bad(`${x.id}: an actor's figure needs role, play and year`);
  // One figure per person, play and role.
  const same = raw.filter(o => o?.kind === 'character' && o.personId === x.personId && o.role === x.role && o.play === x.play && o.year === x.year);
  if (same.length > 1) bad(`${x.id}: the same role twice (${same.map(o => o.id).join(', ')})`);
  if (x.variantOf !== undefined && !rawIds.has(x.variantOf)) bad(`variantOf of ${x.id}`);
}

let bundled = null;
/** The catalog shipped with the server (server/src/wardrobe). */
export const bundledCatalog = () => bundled ??= loadCatalog(JSON.parse(readFileSync(new URL('./wardrobe/catalog.json', import.meta.url), 'utf8')), new URL('./wardrobe/images/', import.meta.url), new URL('./wardrobe/music/', import.meta.url));

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
export function drawWithDupes(c, owned, random, open, pool = c.collectible) {
  // [pool]: the items of a chosen crate target; the rarity weights hold among the rarities in it.
  const present = c.rarities.filter(r => open.has(r.id) && pool.some(x => x.drawnBy.includes(r.id)));
  if (!present.length) return null;
  const tier = weightedPick(present, random);
  const inTier = pool.filter(x => x.drawnBy.includes(tier.id)), missing = inTier.filter(x => !owned.has(x.id));
  return missing.length ? { tier, item: pickOne(missing, random), duplicate: false } : { tier, item: pickOne(inTier, random), duplicate: true };
}

const catalog = t => t.runnerCatalog;
const credit = runnerUnlocks.creditPerRound;

/**
 * The person's progress record; created on first use with the credit for earlier runs. A record
 * from before role figures is moved over once (runner-role-figures.mjs), whoever asks first.
 */
export function runnerProgress(t, personId) {
  const existing = t.store.get('runnerProgress', personId);
  if (existing) {
    // Each move once, whoever asks first: role figures, then crate points.
    const roles = migrateToRoleFigures(catalog(t), existing, t.clock()) ?? existing;
    const moved = migrateToCratePoints(roles, t.clock()) ?? roles;
    return moved !== existing ? t.store.put('runnerProgress', personId, moved) : existing;
  }
  const rounds = t.store.get('runnerScores', personId)?.rounds ?? 0;
  const credited = rounds * credit;
  // The credit for earlier runs is metres: it becomes crate points the same way as an old record.
  const fresh = { personId, meters: credited, creditedMeters: credited, creditedRounds: rounds, opened: 0, owned: [], selected: {}, deaths: {}, createdAt: t.clock().toISOString(), ...(catalog(t).roleFigures ? { model: roleFiguresModel } : {}) };
  return t.store.put('runnerProgress', personId, migrateToCratePoints(fresh, t.clock()));
}

/**
 * The crate points of [p]: what the crates of the own runs count. The base moved over from the
 * metres, the points of all runs since, the Tagesbonus points and the mission points.
 */
export const cratePoints = p => (p.basePoints ?? 0) + (p.points ?? 0) + (p.bonusPoints ?? 0) + (p.missionPoints ?? 0);
/** Missionskisten (all three Tagesmissionen of a day) [p] has waiting. */
export const missionCrates = p => Math.max(0, (p.missionCrates ?? 0) - (p.missionOpened ?? 0));
/** Whether [p]'s Tagesbonus of the Berlin calendar day of [at] is still open. */
export const bonusOpen = (p, at) => p.bonusDay !== berlinDay(at.toISOString());

/**
 * The progress record with the Ensemble-Kisten of reached milestones credited and rarities whose
 * `requires` is met kept open for good.
 */
const progressOf = (t, personId) => {
  const p = grantEnsembleCrates(t, runnerProgress(t, personId), credit), settled = settleUnlocks(t, p);
  return settled === p ? p : t.store.put('runnerProgress', personId, settled);
};

/**
 * Item ids [p] owns: the defaults, what crates brought, the person's own character, the ensemble's
 * rewards and the unique figures unlocked.
 */
const ownedIds = (t, p) => {
  const c = catalog(t);
  return new Set([...Object.values(c.defaults), ...list(p.owned).filter(id => c.byId.has(id)), ...c.items.filter(x => x.personId === p.personId).map(x => x.id), ...ownedRewards(t, credit), ...ownedUniques(c, p)]);
};
/**
 * Whether [owned] meets a rarity's `requires`: `count` items of its rarity (and kind), or all of them
 * without a count; a catalog with fewer than `count` asks for all it has.
 */
const requirementMet = (c, q, owned) => {
  const needed = c.items.filter(x => !x.default && !x.reward && x.rarities.includes(q.rarity) && (!q.kind || x.kind === q.kind));
  const have = needed.filter(x => owned.has(x.id)).length;
  return have >= (q.count === undefined ? needed.length : Math.min(q.count, needed.length));
};
/**
 * Rarities that take part in [p]'s draws: all but those whose `requires` is not met yet; [unlocked]
 * (the person's `unlockedRarities`) stay open once they were.
 */
export const openRarities = (c, owned, unlocked = []) => new Set(c.rarities.filter(r => !r.requires || list(unlocked).includes(r.id) || requirementMet(c, r.requires, owned)).map(r => r.id));
/** The rarities open for [p]. */
const openFor = (c, p, owned) => openRarities(c, owned, p.unlockedRarities);
/**
 * [p] with every rarity whose `requires` is met now remembered as open and every unique figure whose
 * play is complete now unlocked for good (or [p] itself).
 */
function settleUnlocks(t, p, owned = ownedIds(t, p)) {
  const c = catalog(t), have = list(p.unlockedRarities);
  const fresh = c.rarities.filter(r => r.requires && !have.includes(r.id) && requirementMet(c, r.requires, owned)).map(r => r.id);
  return settleUniques(c, fresh.length ? { ...p, unlockedRarities: [...have, ...fresh] } : p, owned, t.clock());
}
const pool = (t, p, owned = ownedIds(t, p)) => {
  const c = catalog(t), open = openFor(c, p, owned);
  return { items: c.collectible.filter(x => !owned.has(x.id) && x.drawnBy.some(r => open.has(r))), open };
};

export function progressView(t, p) {
  const points = cratePoints(p), earned = cratesEarned(points), poolSize = pool(t, p).items.length;
  // `complete`: nothing new left. Apps with duplicates open crates anyway (`dupes`).
  // `meters`, `previousAt` and `nextAt` are crate points since `runnerCratePoints` (`unit`), so older
  // apps still draw their bar and count their crates right (only their texts say "m");
  // `runMeters` stays the real metres, `bonusMeters` and `missionMeters` what was earned in metres
  // before (they grow no more).
  return {
    meters: points, earned, opened: p.opened, crates: Math.max(0, earned - p.opened), previousAt: crateMilestone(earned), nextAt: crateMilestone(earned + 1), poolSize, complete: poolSize === 0, ensembleCrates: ensembleCrates(p), dupes: true,
    runMeters: p.meters, bonusMeters: p.bonusMeters ?? 0, bonusOpen: bonusOpen(p, t.clock()),
    // Added with `runnerMissions`: Missionskisten waiting.
    missionMeters: p.missionMeters ?? 0, missionCrates: missionCrates(p),
    // Added with `runnerEventCrates`: Termin-Kisten waiting.
    eventCrates: waitingEventCrates(t, p.personId).length,
    // Added with `runnerCratePoints`: the crate points and where they come from (`base`: moved over
    // from the metres before; `runs`: the points of every run since; `bonus`: Tagesbonus; `missions`).
    unit: 'points',
    points: { total: points, base: p.basePoints ?? 0, runs: p.points ?? 0, bonus: p.bonusPoints ?? 0, missions: p.missionPoints ?? 0 },
  };
}

const selection = (t, p, owned = ownedIds(t, p)) => {
  const c = catalog(t);
  return Object.fromEntries(wardrobeKinds.map(k => {
    const id = p.selected?.[k];
    return [k, id && owned.has(id) && c.byId.get(id).kind === k ? id : c.defaults[k]];
  }));
};

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
  // `meters`: real metres only; the Tagesbonus is listed apart (`bonusMeters`). The crate points
  // (`runnerCratePoints`) apart as well: `basePoints` moved over from `crateMeters` before.
  return {
    rounds, best: score?.best ?? 0, meters: p.meters, creditedMeters: p.creditedMeters ?? 0, bonusMeters: p.bonusMeters ?? 0, missionMeters: p.missionMeters ?? 0, deaths, unknown: p.deaths?.unknown ?? 0, untracked: Math.max(0, rounds - counted),
    points: p.points ?? 0, bonusPoints: p.bonusPoints ?? 0, missionPoints: p.missionPoints ?? 0, basePoints: p.basePoints ?? 0, crateMeters: p.crateMetersBefore?.meters ?? 0,
  };
}

// Ensemble rewards come apart from `items`, so older apps neither count nor show them; only those
// of reached milestones: until then a reward is a surprise (name, pictures and id stay on the server).
// Unique figures likewise, and only the person's own ([owned]) for apps that ask with [unique].
const catalogView = (t, owned, unique) => {
  const c = catalog(t), revealed = revealedRewards(t, credit);
  return {
    kinds: [...wardrobeKinds], rarities: c.rarities.map(({ rank, ...r }) => r), departments: c.departments,
    items: c.items.filter(x => !x.reward && !x.unique), rewards: c.items.filter(x => x.reward && revealed.has(x.id)), dupes: c.dupes,
    ...(c.ensemble ? { ensembleRarity: c.ensemble.rarity } : {}),
    ...(unique ? { uniqueRarity: c.uniqueRarity, uniques: c.uniques.filter(x => owned.has(x.id)) } : {}),
  };
};

/**
 * The wardrobe of [p]. [roles]: the app knows role figures (`runnerRoleFigures`) and gets them as
 * they are; apps from before get one figure per person with its roles as variants (see
 * runner-role-figures.mjs), all from the same ownership. [unique]: the app knows unique figures
 * (`runnerUniqueFigures`); apps from before neither see nor wear them.
 */
function view(t, p, roles = false, unique = false) {
  const c = catalog(t), all = ownedIds(t, p), owned = unique ? all : withoutUniques(c, all), open = openFor(c, p, owned);
  const ensemble = ensembleView(t, p, credit);
  const plain = {
    progress: progressView(t, p), catalog: catalogView(t, owned, unique), lockedRarities: c.rarities.filter(r => !open.has(r.id)).map(r => r.id),
    owned: c.items.filter(x => owned.has(x.id)).map(x => x.id), selected: selection(t, p, owned), stats: statsView(t, p),
    // Added with `runnerDupes` and `runnerEnsemble`; older apps ignore them. Role figures have no
    // variants: both stay empty for apps that know them.
    shiny: list(p.shiny).filter(id => owned.has(id)), variants: [], selectedVariants: {},
    gage: { balance: p.gage ?? 0, earned: p.gageEarned ?? 0 }, trades: tradeOptions(c, owned, open),
    ...(ensemble ? { ensemble } : {}),
    // Added with `runnerEventCrates`: the Termin-Kisten waiting, the earliest event first.
    eventCrates: waitingEventCrates(t, p.personId).map(crateView),
    ...(c.roleFigures ? { roleFigures: true } : {}),
    // Added with `runnerUniqueFigures`: per play the progress towards its unique figure.
    ...(unique ? { uniqueFigures: uniqueView(c, p, all) } : {}),
    // Added with `runnerCrateTargets`: what a crate of the own runs can be opened as.
    crateTargets: crateTargetsView(c, owned, open),
  };
  return roles ? plain : olderAppView(c, plain, p, owned);
}

/**
 * GET /games/runner/wardrobe: progress, catalog, inventory, selection and statistics; `roles`
 * (`?roles=1`) for apps that know role figures, `unique` (`?unique=1`) for apps that know unique figures.
 */
export function wardrobe(t, uid, { roles = false, unique = false } = {}) {
  return t.store.transaction(() => view(t, progressOf(t, t.account(uid).personId), roles === true, unique === true));
}

/** Plausible metres of a finished run; without `meters` (older clients) a conservative estimate. */
export function runMeters(b, elapsedMs, maxMeters, { slackSeconds, tolerance }) {
  if (b.meters === undefined || b.meters === null) return Math.floor(Math.min(b.score, maxMeters(elapsedMs / 1000)) * runnerUnlocks.legacyMetersFactor);
  if (!Number.isInteger(b.meters) || b.meters < 0 || b.meters > b.score || b.meters > maxMeters(elapsedMs / 1000 + slackSeconds) * tolerance) fail(400, 'So viele Meter sind in dieser Zeit nicht möglich.', 'implausible');
  return b.meters;
}

/**
 * Adds a finished run to the person's progress and to the ensemble (inside runnerScore's transaction).
 * Its points ([run].points, checked by `runPoints`; else its score) count for the crates, its metres
 * for the statistics and the ensemble. The first run of the Berlin calendar day of [at] with more
 * than 0 m also brings its points again as Tagesbonus, for the crates only.
 */
export function recordRun(t, personId, meters, hitBy, at = t.clock(), run = {}) {
  // First: on its first use the shared distance counts what was run before, without this run.
  ensembleState(t, credit);
  const p = countSection(t, runnerProgress(t, personId), meters, credit), before = cratesEarned(cratePoints(p));
  const points = run.points ?? run.score ?? meters;
  const kind = runnerObstacleKinds.includes(hitBy) ? hitBy : 'unknown';
  const daily = meters > 0 && bonusOpen(p, at), bonus = daily ? points : 0;
  const reachedNow = addEnsembleMeters(t, meters, credit);
  // Tagesmissionen (runner-missions.mjs): their crate points and the Missionskiste, never the ensemble's.
  const mission = recordMissionRun(t, personId, { meters, score: run.score ?? meters, stats: run.stats ?? null, statsSent: run.statsSent === true, at });
  const next = grantEnsembleCrates(t, t.store.put('runnerProgress', personId, {
    ...p, meters: p.meters + meters, points: (p.points ?? 0) + points, deaths: { ...p.deaths, [kind]: (p.deaths?.[kind] ?? 0) + 1 },
    ...(daily ? { bonusPoints: (p.bonusPoints ?? 0) + bonus, bonusDay: berlinDay(at.toISOString()) } : {}),
    ...(mission.rewardPoints ? { missionPoints: (p.missionPoints ?? 0) + mission.rewardPoints } : {}),
    ...(mission.crate ? { missionCrates: (p.missionCrates ?? 0) + mission.crate } : {}),
  }), credit);
  const progress = progressView(t, next), ensemble = ensembleRunView(t, meters, reachedNow, credit);
  // `gained` and `bonus` stay metres for older apps ("+812 m · Tagesbonus +812 m"); `missionBonus`
  // and `gainedPoints` are crate points.
  return {
    ...progress, gained: meters, bonus: daily ? meters : 0, missionBonus: mission.rewardPoints, newCrates: progress.earned - before,
    gainedPoints: { run: points, bonus, missions: mission.rewardPoints },
    ...(ensemble ? { ensemble } : {}),
    ...(mission.record ? { missions: missionsView(t, mission.record, mission.completed) } : {}),
  };
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
 * What a drawn duplicate brings [p]: a shiny one makes a plain item shiny; else the gage of the
 * rarity it was drawn through. (Roles are figures of their own: no variant step any more.)
 */
function duplicate(p, draw, shiny) {
  const { item, tier } = draw, shinyOwned = list(p.shiny).includes(item.id);
  if (shiny && !shinyOwned) return { next: { ...p, shiny: [...list(p.shiny), item.id] }, outcome: { type: 'shine' } };
  return { next: { ...p, gage: (p.gage ?? 0) + tier.gage, gageEarned: (p.gageEarned ?? 0) + tier.gage }, outcome: { type: 'gage', gage: tier.gage } };
}

/**
 * POST /games/runner/crates: opens one crate. A repeated Idempotency-Key returns the same opening.
 * `{ dupes: true }` (apps with `runnerDupes`) draws with duplicates and shine; `crate: 'ensemble'`
 * opens an Ensemble-Kiste instead of a crate of the own metres, `crate: 'event'` a Termin-Kiste (the
 * one of `eventId`, else the earliest waiting; see runner-event-crates.mjs). Each kind shines with
 * its own chance (`shinyChanceOf`). `roles: true`: the app knows role figures; for older apps a won
 * role figure shows as a role of the person's figure (runner-role-figures.mjs).
 *
 * `target` (`runnerCrateTargets`, only for a crate of the own runs and with `dupes`): `'random'` or
 * none is the Zufallskiste as before (all items; shine chance `costume`), a play's id or `'tech'`
 * draws only from that pool (shine chance `targeted`), the rarity weights among the rarities in it.
 * A complete pool still opens and brings a duplicate (shine or gage), like a complete rarity.
 */
export function openCrate(t, uid, requestId, b = {}) {
  const dupes = b?.dupes === true, ensemble = b?.crate === 'ensemble', mission = b?.crate === 'mission', event = b?.crate === 'event', roles = b?.roles === true, unique = b?.unique === true;
  const targetId = b?.target ?? null;
  if (event && !dupes) fail(400, 'Termin-Kisten gibt es nur in der neuen App.');
  if (mission && !dupes) fail(400, 'Missionskisten gibt es nur in der neuen App.');
  if (ensemble && !dupes) fail(400, 'Ensemble-Kisten gibt es nur in der neuen App.');
  if (targetId !== null) {
    if (typeof targetId !== 'string') fail(400, 'Diese Kiste gibt es nicht.', 'unknown_target');
    if (event || mission || ensemble) fail(400, 'Nur Kostümkisten lassen sich gezielt wählen.', 'unknown_target');
    if (!dupes && targetId !== 'random') fail(400, 'Gezielte Kisten gibt es nur in der neuen App.');
  }
  return once(t, uid, crateRequestPrefix, requestId, 'runner.crate', a => {
    const c = catalog(t), p = progressOf(t, a.personId);
    const target = targetId && targetId !== 'random' ? c.crateTargets.find(x => x.id === targetId && x.kind !== 'random') : null;
    if (targetId && targetId !== 'random' && !target) fail(400, 'Diese Kiste gibt es nicht.', 'unknown_target');
    const eventCrate = event ? nextEventCrate(t, a.personId, b.eventId ?? null) : null;
    if (event ? !eventCrate : mission ? missionCrates(p) <= 0 : ensemble ? ensembleCrates(p) <= 0 : cratesEarned(cratePoints(p)) - p.opened <= 0) fail(409, event ? 'Gerade ist keine Termin-Kiste da.' : mission ? 'Gerade ist keine Missionskiste da.' : ensemble ? 'Gerade ist keine Ensemble-Kiste da.' : 'Gerade ist keine Kostümkiste da. Lauf weiter!', 'no_crate');
    if (!dupes) {
      // Older apps: only what is still missing; with nothing left the crates stay closed.
      const { items: candidates, open } = pool(t, p);
      if (!candidates.length) fail(409, 'Der Fundus ist komplett. Neue Kostüme kommen bald – die Kisten bleiben so lange zu.', 'wardrobe_complete');
      const item = drawItem(c, candidates, t.random, 1, open);
      const next = t.store.put('runnerProgress', a.personId, settleUnlocks(t, { ...p, opened: p.opened + 1, owned: [...list(p.owned), item.id] }));
      const result = { item, ...reel(t, item, open), wardrobe: view(t, next, roles, unique) };
      return { result: roles ? result : olderAppOpening(c, result), subject: item.id };
    }
    const owned = ownedIds(t, p), open = openFor(c, p, owned);
    const items = target ? c.targetItems.get(target.id) : c.collectible;
    if (target && !items.some(x => x.drawnBy.some(r => open.has(r)))) {
      // Everything of it still locked (e.g. only Legacy figures): the rarity's hint.
      fail(409, c.rarity.get(items[0]?.rarity)?.hint ?? 'Diese Kiste ist noch gesperrt.', 'target_locked');
    }
    const draw = drawWithDupes(c, owned, t.random, open, items);
    if (!draw) fail(409, 'Im Fundus ist noch nichts.', 'wardrobe_complete');
    const crate = event ? 'event' : mission ? 'mission' : ensemble ? 'ensemble' : 'costume';
    // The Zufallskiste keeps the shine chance of the own crates (`costume`); an aimed one has `targeted`.
    const shiny = t.random() < shinyChanceOf(c, target ? 'targeted' : crate);
    const { next, outcome } = draw.duplicate ? duplicate(p, draw, shiny)
      : { next: { ...p, owned: [...list(p.owned), draw.item.id], ...(shiny ? { shiny: [...list(p.shiny), draw.item.id] } : {}) }, outcome: { type: 'new' } };
    const counted = event ? {} : mission ? { missionOpened: (p.missionOpened ?? 0) + 1 } : ensemble ? { ensembleOpened: (p.ensembleOpened ?? 0) + 1 } : { opened: p.opened + 1 };
    if (eventCrate) markEventCrateOpened(t, eventCrate, draw.item.id);
    const saved = t.store.put('runnerProgress', a.personId, settleUnlocks(t, { ...next, ...counted }));
    const aim = crate === 'costume' ? { target: target?.id ?? 'random' } : {};
    const result = { item: draw.item, ...reel(t, draw.item, open, items), outcome: { ...outcome, duplicate: draw.duplicate, shiny, rarity: draw.tier.id, crate, ...aim, ...(eventCrate ? { event: crateView(eventCrate) } : {}) }, wardrobe: view(t, saved, roles, unique) };
    return { result: roles ? result : olderAppOpening(c, result), subject: `${draw.item.id}${draw.duplicate ? ` ${outcome.type}` : ''}${shiny ? ' shiny' : ''}${target ? ` ${target.id}` : ''}` };
  });
}

/** POST /games/runner/trade `{ rarity }`: gage for a random missing item of the next rarity up. */
export function tradeGage(t, uid, requestId, b) {
  return once(t, uid, tradeRequestPrefix, requestId, 'runner.trade', a => {
    const c = catalog(t), from = c.rarity.get(b?.rarity);
    if (!from) fail(400, 'Unbekannte Stufe.');
    const p = progressOf(t, a.personId), owned = ownedIds(t, p), open = openFor(c, p, owned);
    const target = tradeTarget(c, owned, open, from.rank);
    if (!target) fail(409, 'Darüber fehlt dir nichts mehr.', 'nothing_to_trade');
    const cost = tradeCost(c, target);
    if (!(cost > 0)) fail(409, 'Diese Stufe bringt keine Gage.', 'nothing_to_trade');
    if ((p.gage ?? 0) < cost) fail(409, 'Dafür reicht die Gage noch nicht.', 'not_enough_gage');
    const item = pickOne(c.collectible.filter(x => x.drawnBy.includes(target.id) && !owned.has(x.id)), t.random);
    const next = t.store.put('runnerProgress', a.personId, settleUnlocks(t, { ...p, gage: p.gage - cost, owned: [...list(p.owned), item.id] }));
    const result = { item, outcome: { type: 'trade', rarity: target.id, cost }, wardrobe: view(t, next, b?.roles === true, b?.unique === true) };
    return { result: b?.roles === true ? result : olderAppDeal(c, result), subject: `${item.id} -${cost}` };
  });
}

/** POST /games/runner/buy `{ itemId }`: one chosen missing item for gage; not gold. */
export function buyItem(t, uid, requestId, b) {
  return once(t, uid, buyRequestPrefix, requestId, 'runner.buy', a => {
    const c = catalog(t), item = c.byId.get(b?.itemId);
    // A unique figure is unlocked, never bought: the same answer as an unknown id, it stays a secret.
    if (!item || item.default || item.reward || item.unique) fail(404, 'Dieses Teil gibt es nicht.');
    const p = progressOf(t, a.personId), owned = ownedIds(t, p), open = openFor(c, p, owned);
    if (owned.has(item.id)) fail(409, 'Das hast du schon.', 'already_owned');
    const cost = buyCost(c, item);
    if (cost === null) fail(409, `${c.rarity.get(item.rarity)?.name ?? 'Diese Stufe'} gibt es nur aus Kisten und Tauschverträgen.`, 'not_buyable');
    if (!item.drawnBy.some(r => open.has(r))) fail(409, c.rarity.get(item.rarity)?.hint ?? 'Noch gesperrt.', 'locked');
    if ((p.gage ?? 0) < cost) fail(409, 'Dafür reicht die Gage noch nicht.', 'not_enough_gage');
    const next = t.store.put('runnerProgress', a.personId, settleUnlocks(t, { ...p, gage: p.gage - cost, owned: [...list(p.owned), item.id] }));
    const result = { item, outcome: { type: 'buy', rarity: item.rarity, cost }, wardrobe: view(t, next, b?.roles === true, b?.unique === true) };
    return { result: b?.roles === true ? result : olderAppDeal(c, result), subject: `${item.id} -${cost}` };
  });
}

/** PUT /games/runner/ensemble/seen `{ km }`: the celebration of milestones up to [km] was shown. */
export function ensembleSeen(t, uid, b) {
  if (!(typeof b?.km === 'number' && b.km >= 0)) fail(400, 'Ungültiger Meilenstein.');
  return t.store.transaction(() => {
    const a = t.account(uid), c = catalog(t), p = progressOf(t, a.personId);
    const highest = c.ensemble ? reachedMilestones(c.ensemble, ensembleState(t, credit).meters).at(-1)?.km ?? 0 : 0;
    const seen = Math.max(p.ensembleSeen ?? 0, Math.min(b.km, highest));
    return view(t, seen === (p.ensembleSeen ?? 0) ? p : t.store.put('runnerProgress', a.personId, { ...p, ensembleSeen: seen }), b.roles === true, b.unique === true);
  });
}

/** PUT /games/runner/unique/seen `{ itemIds }`: the celebration of these unlocked unique figures was shown. */
export function uniqueSeen(t, uid, b) {
  if (!Array.isArray(b?.itemIds) || b.itemIds.length > 100 || b.itemIds.some(id => typeof id !== 'string')) fail(400, 'Ungültige Figuren.');
  return t.store.transaction(() => {
    const a = t.account(uid), c = catalog(t), p = progressOf(t, a.personId), next = markUniquesSeen(c, p, b.itemIds);
    return view(t, next === p ? p : t.store.put('runnerProgress', a.personId, next), b.roles === true, true);
  });
}

/** Cards for the opening animation; only the one at `winnerIndex` was drawn, the rest is show. */
function reel(t, item, open, pool = catalog(t).collectible) {
  const { reelLength, reelWinner, fillerFlatten, nearMissChance } = runnerUnlocks, c = catalog(t);
  // Only what could be won (from this crate's pool): locked rarities are not teased.
  const all = pool.filter(x => x.drawnBy.some(r => open.has(r)));
  const cards = Array.from({ length: reelLength }, () => drawItem(c, all, t.random, fillerFlatten, open).id);
  cards[reelWinner] = item.id;
  const rarest = all.filter(x => x.id !== item.id).sort((x, y) => c.rarity.get(y.rarity).rank - c.rarity.get(x.rarity).rank)[0];
  if (rarest && c.rarity.get(rarest.rarity).rank > c.rarity.get(item.rarity).rank && t.random() < nearMissChance) {
    cards[reelWinner + (t.random() < 0.5 ? -1 : 1)] = rarest.id;
  }
  return { reel: cards, winnerIndex: reelWinner };
}

/**
 * PUT /games/runner/outfit: wears an owned item; `{ kind, itemId, roles: true }` from apps that know
 * role figures. Older apps name the person's figure and optionally `variant` (one of its roles, or
 * null for the figure itself); runner-role-figures.mjs turns that into the role figure to wear.
 */
export function selectOutfit(t, uid, b) {
  return t.store.transaction(() => {
    const a = t.account(uid), c = catalog(t), roles = b?.roles === true, unique = b?.unique === true;
    if (!wardrobeKinds.includes(b?.kind)) fail(400, 'Unbekannte Art.');
    const item = c.byId.get(b.itemId);
    if (!item || item.kind !== b.kind) fail(404, 'Dieses Teil gibt es nicht.');
    const p = progressOf(t, a.personId), owned = ownedIds(t, p);
    // A unique figure not unlocked (or asked for by an app from before) is no known item.
    if (item.unique && (!unique || !owned.has(item.id))) fail(404, 'Dieses Teil gibt es nicht.');
    const { wear, selectedVariant } = roles || !c.rolesOf.has(item.id) ? { wear: item.id, selectedVariant: p.selectedVariant } : olderAppOutfit(c, p, owned, item, b.variant);
    if (!owned.has(wear)) fail(409, 'Dieses Teil ist noch nicht in deiner Garderobe.', 'not_owned');
    return view(t, t.store.put('runnerProgress', a.personId, { ...p, selected: { ...p.selected, [b.kind]: wear }, ...(selectedVariant ? { selectedVariant } : {}) }), roles, unique);
  });
}

/**
 * GET /games/runner/skins/<file>: a picture of the catalog, for signed-in members; one only ensemble
 * rewards use not before one of them is revealed, one only unique figures use only for those who
 * unlocked one of them (both the same 404 as an unknown file).
 */
export function skinFile(t, uid, name) {
  const a = t.account(uid);
  const c = catalog(t), file = c.files.get(name), rewards = c.rewardFiles?.get(name), uniques = c.uniqueFiles?.get(name);
  if (!file) fail(404, 'Nicht gefunden.');
  if (rewards && !t.store.transaction(() => { const revealed = revealedRewards(t, credit); return rewards.some(id => revealed.has(id)); })) fail(404, 'Nicht gefunden.');
  if (uniques) {
    const mine = new Set(a.personId == null ? [] : list(t.store.get('runnerProgress', a.personId)?.uniques));
    if (!uniques.some(id => mine.has(id))) fail(404, 'Nicht gefunden.');
  }
  return file;
}
