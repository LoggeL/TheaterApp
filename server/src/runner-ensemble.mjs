// "Ensemble-Strecke" of the stage runner: the metres of all players add up to one shared distance.
// Every milestone of the catalog (`ensemble.milestones`, then one every `ensemble.every` km) unlocks
// its reward for everyone and gives every active member one "Ensemble-Kiste" (a crate with a
// shine chance of its own, `dupes.shinyChance.ensemble`), credited on their next request and never twice (by the milestone's km).
//
// - The shared distance starts with everything run before it existed, the one-time credit of early
//   runs included (the same metres the players see as their own total), so nobody's runs are lost
//   and the first milestones come within reach at once. It is kept as a counter of its own: deleting
//   a person does not take their metres away from the ensemble, and reached milestones stay reached.
// - A reward is an item of the catalog marked `reward: true` (a backdrop of an earlier play, an
//   effect, …): never in crates, trades or purchases. Once its milestone is reached everybody owns
//   it, as soon as it is ready (a picture for backdrops and characters, the effect for effects);
//   until then the app shows "Belohnung wird vorbereitet" and it arrives with the picture.
// - A reward is a surprise until its milestone is reached: a milestone not reached yet shows only
//   its distance and that something waits there (`hidden: true`, `name: '???'`, `reward: null`,
//   no note), the catalog leaves the item out and its pictures and music are not served
//   (`revealedRewards`). Apps from before take it for a milestone with only the crate.
// - No ranking of contributors: the app shows one's own share of the current section and how many
//   took part (see docs/operations.md, „Bühnenlauf: Garderobe").

const state = ['runnerEnsemble', 'total'];
const list = value => Array.isArray(value) ? value : [];
const kmToMeters = 1000;

/** Checks the `ensemble` part of a catalog; [rawIds] are all item ids including disabled ones. */
export function parseEnsemble(data, rawIds, bad) {
  if (data === undefined || data === null) return null;
  if (typeof data !== 'object') bad('ensemble');
  let last = 0;
  const milestones = list(data.milestones).map(m => {
    if (!(m?.km > last)) bad(`ensemble milestone ${JSON.stringify(m)} (km must grow)`);
    last = m.km;
    if (m.item !== undefined && !rawIds.has(m.item)) bad(`ensemble reward ${m.item} missing`);
    return {
      km: m.km,
      ...(typeof m.item === 'string' ? { item: m.item } : {}),
      ...(typeof m.name === 'string' && m.name ? { name: m.name } : {}),
      ...(typeof m.note === 'string' && m.note ? { note: m.note } : {}),
    };
  });
  if (!milestones.length) bad('ensemble needs milestones');
  if (!(data.every > 0)) bad('ensemble.every');
  const r = data.rarity ?? {};
  return {
    milestones, every: data.every,
    rarity: { id: String(r.id ?? 'ensemble'), name: String(r.name ?? 'Ensemble'), color: /^#[0-9A-Fa-f]{6}$/.test(r.color ?? '') ? r.color : '#F28C28' },
    crateName: typeof data.crateName === 'string' && data.crateName ? data.crateName : 'Ensemble-Kiste',
  };
}

/** The [i]-th milestone (from 0): the listed ones, then one every `every` km. */
export function milestoneAt(e, i) {
  if (i < e.milestones.length) return e.milestones[i];
  const last = e.milestones.at(-1).km;
  return { km: last + e.every * (i - e.milestones.length + 1) };
}

/** Milestones reached with [meters] in total, in order. */
export function reachedMilestones(e, meters) {
  const reached = [];
  for (let i = 0; ; i++) {
    const m = milestoneAt(e, i);
    if (m.km * kmToMeters > meters) return reached;
    reached.push(m);
  }
}

/** The first milestone not reached yet. */
export const nextMilestone = (e, meters) => milestoneAt(e, reachedMilestones(e, meters).length);

/**
 * The shared distance; on first use everything run so far: the metres of each person's progress,
 * and for people who never opened the wardrobe their pending credit for earlier runs.
 */
export function ensembleState(t, creditPerRound) {
  const existing = t.store.get(...state);
  if (existing) return existing;
  const progress = t.store.all('runnerProgress'), known = new Set(progress.map(p => p.personId));
  const pending = t.store.all('runnerScores').filter(s => !known.has(s.personId)).reduce((sum, s) => sum + (s.rounds ?? 0) * creditPerRound, 0);
  const meters = progress.reduce((sum, p) => sum + (p.meters ?? 0), 0) + pending;
  const at = t.clock().toISOString(), e = t.runnerCatalog.ensemble;
  const reached = e ? Object.fromEntries(reachedMilestones(e, meters).map(m => [m.km, at])) : {};
  return t.store.put(...state, { meters, initialMeters: meters, startedAt: at, reached });
}

/** Adds a run's metres to the shared distance; returns the milestones it reached. */
export function addEnsembleMeters(t, meters, creditPerRound) {
  const s = ensembleState(t, creditPerRound), e = t.runnerCatalog.ensemble;
  const before = e ? reachedMilestones(e, s.meters).length : 0;
  const total = s.meters + meters;
  const now = e ? reachedMilestones(e, total).slice(before) : [];
  const at = t.clock().toISOString();
  t.store.put(...state, { ...s, meters: total, reached: { ...s.reached, ...Object.fromEntries(now.map(m => [m.km, at])) } });
  return now;
}

/** Whether the reward item of a reached milestone can be used: it has its picture or effect. */
export const rewardReady = item => !!item && (item.kind === 'fx' ? !!item.effect : !!item.image);

/** Reward items everybody owns: reached and ready. */
export function ownedRewards(t, creditPerRound) {
  const c = t.runnerCatalog, e = c.ensemble;
  if (!e) return [];
  return reachedMilestones(e, ensembleState(t, creditPerRound).meters).map(m => m.item && c.byId.get(m.item)).filter(rewardReady).map(x => x.id);
}

/**
 * Credits an Ensemble-Kiste for every reached milestone [p] has not had one for, if the person is
 * an active member; returns the (possibly) updated record.
 */
export function grantEnsembleCrates(t, p, creditPerRound) {
  const e = t.runnerCatalog.ensemble;
  if (!e || t.store.get('members', p.personId)?.active !== true) return p;
  const granted = new Set(list(p.ensembleGranted));
  const missing = reachedMilestones(e, ensembleState(t, creditPerRound).meters).map(m => m.km).filter(km => !granted.has(km));
  if (!missing.length) return p;
  return t.store.put('runnerProgress', p.personId, { ...p, ensembleGranted: [...granted, ...missing] });
}

/** Ensemble crates [p] has waiting. */
export const ensembleCrates = p => Math.max(0, list(p.ensembleGranted).length - (p.ensembleOpened ?? 0));

/** The section a run counts towards: from the last reached milestone (0 before the first). */
export const sectionStart = (e, meters) => reachedMilestones(e, meters).at(-1)?.km ?? 0;

/** Adds a run to the person's share of the current section. */
export function countSection(t, p, meters, creditPerRound) {
  const e = t.runnerCatalog.ensemble;
  if (!e) return p;
  const from = sectionStart(e, ensembleState(t, creditPerRound).meters);
  const own = p.section?.from === from ? p.section.meters : 0;
  return { ...p, section: { from, meters: own + meters } };
}

/** What a milestone not reached yet is called while its reward is a surprise. */
export const hiddenName = '???';

/** Ids of the reward items whose milestone is reached: the only ones anybody may see. */
export function revealedRewards(t, creditPerRound) {
  const e = t.runnerCatalog.ensemble;
  if (!e) return new Set();
  return new Set(reachedMilestones(e, ensembleState(t, creditPerRound).meters).map(m => m.item).filter(Boolean));
}

function milestoneView(c, m, s) {
  const reached = s.meters >= m.km * kmToMeters;
  // Not reached yet: only the distance; name, note, item, kind and picture stay a surprise.
  // `name` and `reward: null` keep apps from before working (they show "???" and the crate).
  if (!reached && m.item) return { km: m.km, name: hiddenName, hidden: true, reward: null, reached: false };
  const item = m.item ? c.byId.get(m.item) : null;
  return {
    km: m.km,
    name: m.name ?? item?.name ?? c.ensemble.crateName,
    ...(m.note ? { note: m.note } : {}),
    // `kind` came with the hidden rewards: what was unlocked ("Bühnenbild"), for the reveal.
    reward: m.item ? { itemId: m.item, ready: rewardReady(item), ...(item ? { kind: item.kind } : {}) } : null,
    reached,
    ...(reached && s.reached?.[m.km] ? { reachedAt: s.reached[m.km] } : {}),
  };
}

/** What the app shows of the shared distance for [p]. */
export function ensembleView(t, p, creditPerRound) {
  const c = t.runnerCatalog, e = c.ensemble;
  if (!e) return null;
  const s = ensembleState(t, creditPerRound);
  const reached = reachedMilestones(e, s.meters), next = milestoneAt(e, reached.length);
  // The listed milestones and the periodic ones up to the one after next.
  const shown = Array.from({ length: Math.max(e.milestones.length, reached.length + 2) }, (_, i) => milestoneAt(e, i));
  const from = reached.at(-1)?.km ?? 0;
  const players = t.store.all('runnerProgress').filter(x => x.section?.from === from && x.section.meters > 0).length;
  return {
    meters: s.meters,
    previousKm: from,
    next: milestoneView(c, next, s),
    milestones: shown.map(m => milestoneView(c, m, s)),
    crates: ensembleCrates(p),
    unseen: reached.map(m => m.km).filter(km => km > (p.ensembleSeen ?? 0)),
    section: { from, own: p.section?.from === from ? p.section.meters : 0, players },
  };
}

/** The run reply's view: what the run added and how far the next milestone is. */
export function ensembleRunView(t, gained, reachedNow, creditPerRound) {
  const c = t.runnerCatalog, e = c.ensemble;
  if (!e) return null;
  const s = ensembleState(t, creditPerRound);
  return { gained, meters: s.meters, next: milestoneView(c, nextMilestone(e, s.meters), s), reached: reachedNow.map(m => milestoneView(c, m, s)) };
}
