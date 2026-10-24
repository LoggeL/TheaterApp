import { createHash } from 'node:crypto';
import { AppError } from './theater.mjs';
import { berlinDay } from './event-series.mjs';

// "Tagesmissionen" of the stage runner (`runnerMissions`): every person gets three missions per
// Europe/Berlin calendar day, easy, medium and hard, measured on their own best runs.
//
// - The server keeps per person (`runnerMissions`) the best per run of every measured value, which
//   only ever rises: metres, points and, from apps that send plausible statistics, pickups by kind,
//   metres on the floor and right below the fly loft, obstacles passed by kind, metres without a
//   pickup. Targets are a share of these bests by slot, rounded to even figures and kept within
//   each type's limits; with fewer than `minRuns` counted runs the start values are their floor.
//   Bad runs on purpose therefore lower nothing. A new best counts from the next day's missions on.
// - Records of the earlier version (a window of the last runs) start their bests once from that
//   window's maxima and the high score.
// - Which missions: deterministic from person and day (and yesterday's types, which are avoided),
//   never two of a type on one day. One mission per day may be rerolled for free.
// - A run's statistics are checked for plausibility (sums, pickup points, obstacles per metre,
//   debuts only with their points); implausible ones count for no mission, the run itself counts.
// - Apps without statistics (older ones) only get the types the server can check from metres and
//   points; the kind of client is decided when the day's missions are made.
// - Rewards are crate metres (like the Tagesbonus: crates only, not the Ensemble-Strecke), once per
//   mission; all three on one day also bring a "Missionskiste" (shine chance by crate kind
//   `mission` in the catalog's `dupes.shinyChance`).

const fail = (status, message, code) => { throw new AppError(status, message, code); };
const list = value => Array.isArray(value) ? value : [];
export const missionRequestPrefix = 'runner-mission:';
export const missionSlots = Object.freeze(['easy', 'medium', 'hard']);
// The points at which an obstacle joins the course (`StageRunner.debuts` in the app).
export const runnerDebuts = Object.freeze([[250, 'drum'], [500, 'pile'], [750, 'truss'], [1000, 'drop']]);
export const missionPickups = Object.freeze({ rose: 5, mask: 10, star: 25 });
export const missionObstacles = Object.freeze(['crate', 'flat', 'lamp', 'border', 'sandbag', 'drum', 'pile', 'truss', 'drop']);

/**
 * All numbers of the missions. `start`: targets per slot (easy, medium, hard) without enough runs;
 * `min`/`max`: limits of a target (for counts and metres of a kind of play, a share below `min` means
 * the type is not offered in that slot, rather than made harder than intended); `weight`: how often
 * a type is chosen; `basic`: checkable without the run's statistics (older apps).
 */
export const missionRules = Object.freeze({
  // With fewer counted runs the start values are the floor of a target (a first lucky or unlucky
  // run says little).
  minRuns: 5,
  // Runs this short (an instant crash) count for nothing: no best, no counted run.
  minMeters: 20,
  slots: { easy: { reward: 300 }, medium: { reward: 600 }, hard: { reward: 1000 } },
  // A type of yesterday is chosen with this share of its weight.
  repeatWeight: 0.2,
  // `share`: the target as a share of the person's best per run, by slot; calibrated with a
  // simulation so that one run makes easy ≈ 50 %, medium ≈ 25 %, hard ≈ 9 % of the time.
  types: {
    distance: { weight: 3, basic: true, slots: missionSlots, share: { easy: 0.3, medium: 0.42, hard: 0.57 }, min: 100, max: 6000, start: [150, 250, 400] },
    points: { weight: 2, basic: true, slots: missionSlots, share: { easy: 0.3, medium: 0.44, hard: 0.58 }, min: 120, max: 9000, start: [200, 330, 500] },
    collect: { weight: 2, slots: missionSlots, share: { easy: 0.3, medium: 0.45, hard: 0.6 }, kinds: { rose: { min: 3, start: [5, 9, 14] }, mask: { min: 2, start: [2, 4, 6] }, star: { min: 1, start: [1, 2, 3] } }, max: 400 },
    ground: { weight: 1.5, slots: missionSlots, share: { easy: 0.25, medium: 0.38, hard: 0.55 }, min: 20, max: 4000, start: [20, 35, 55] },
    ceiling: { weight: 1.5, slots: missionSlots, share: { easy: 0.25, medium: 0.38, hard: 0.55 }, min: 10, max: 3000, start: [10, 20, 35] },
    // Obstacles of a debut only for those whose runs at this slot reach its points; `min` is 1 for them.
    pass: { weight: 2, slots: missionSlots, share: { easy: 0.3, medium: 0.45, hard: 0.65 }, min: 2, debutMin: 1, max: 400, start: { crate: [4, 7, 10], flat: [3, 5, 8], lamp: [4, 7, 10], border: [3, 6, 9], sandbag: [2, 4, 6] } },
    // Distance without one pickup: shares of the best such run or, if higher, of `ofDistance` times
    // the best run (avoiding every pickup costs distance).
    noPickup: { weight: 1, slots: missionSlots, share: { easy: 0.22, medium: 0.32, hard: 0.45 }, ofDistance: 0.6, min: 80, max: 4000, start: [100, 150, 220] },
    // Metres today in total: `ofBest` times the best run. Only easy.
    dailyDistance: { weight: 1.5, basic: true, slots: ['easy'], ofBest: 1, min: 500, max: 30000, start: [600] },
    // Reach an obstacle's points in a run, if they lie near this slot's points target: within
    // `band` times it (the highest such obstacle).
    debut: { weight: 1.5, basic: true, slots: ['medium', 'hard'], band: [0.95, 1.25] },
    // Own idea: a series, `count` runs today of at least `share` of the best run.
    runs: { weight: 1, basic: true, slots: ['easy', 'medium'], count: 3, share: { easy: 0.22, medium: 0.33 }, min: 60, max: 4000, start: [100, 150] },
  },
});

/** The rules a server uses: `missionRules`, other ones in tests, or none (null: no missions). */
const rulesOf = t => t.missionRules === undefined ? missionRules : t.missionRules;

/** The `YYYY-MM-DD` before [day]. */
const dayBefore = day => { const [y, m, d] = day.split('-').map(Number); return new Date(Date.UTC(y, m - 1, d - 1)).toISOString().slice(0, 10); };

/** Uniform numbers in [0, 1), the same for the same [parts]. */
export function seeded(...parts) {
  let s = createHash('sha256').update(parts.join(':')).digest().readUInt32LE(0);
  return () => {
    s = (s + 0x6D2B79F5) >>> 0;
    let x = Math.imul(s ^ (s >>> 15), s | 1);
    x ^= x + Math.imul(x ^ (x >>> 7), x | 61);
    return ((x ^ (x >>> 14)) >>> 0) / 4294967296;
  };
}

/** An even figure near [v]: whole numbers below 30, then steps of 5, 10, 25, 50 and 100. */
export function nice(v) {
  const step = v < 30 ? 1 : v < 100 ? 5 : v < 300 ? 10 : v < 1000 ? 25 : v < 3000 ? 50 : 100;
  return Math.max(1, Math.round(v / step) * step);
}
const within = (v, min, max) => Math.min(max, Math.max(min, nice(Math.min(max, Math.max(min, v)))));

/**
 * The checked statistics of a run, or null if they are missing or implausible: sums within the
 * metres, pickups exactly the points beyond the metres, no more pickup rows and obstacles than
 * sections fit in the distance, debut obstacles only with their points.
 */
export function checkRunStats(raw, { meters, score, metersSent }) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw) || !metersSent) return null;
  const count = v => v === undefined ? 0 : Number.isInteger(v) && v >= 0 ? v : NaN;
  const s = { rose: count(raw.rose), mask: count(raw.mask), star: count(raw.star), ground: count(raw.ground), ceiling: count(raw.ceiling), passed: {} };
  if (Object.values(s).some(Number.isNaN)) return null;
  const passed = raw.passed ?? {};
  if (!passed || typeof passed !== 'object' || Array.isArray(passed)) return null;
  for (const [kind, n] of Object.entries(passed)) {
    if (!missionObstacles.includes(kind) || Number.isNaN(count(n))) return null;
    if (n > 0) s.passed[kind] = n;
  }
  if (s.ground + s.ceiling > meters) return null;
  if (s.rose * missionPickups.rose + s.mask * missionPickups.mask + s.star * missionPickups.star !== score - meters) return null;
  // A section is at least 6.7 m long and holds at most one row (3 roses, 2 masks or a star).
  const sections = meters / 6 + 2;
  if (s.rose / 3 + s.mask / 2 + s.star > sections) return null;
  if (Object.values(s.passed).reduce((a, b) => a + b, 0) > sections) return null;
  for (const [points, kind] of runnerDebuts) if (s.passed[kind] && score < points) return null;
  // Borders join the course at 80 m, sandbags at 150 m (counted where they stand, a bit ahead).
  if ((s.passed.border && meters < 70) || (s.passed.sandbag && meters < 140)) return null;
  return s;
}

const debutOf = kind => runnerDebuts.find(([, k]) => k === kind)?.[0] ?? 0;

/**
 * Targets a type offers in [slot] for the person's bests in [ctx] (`best`: per run, only ever
 * rising; `runs`: runs counted): `[{ kind?, target, min? }]`, empty if none. A best not measured yet
 * means the type's start values.
 */
export function missionOptions(type, slot, ctx) {
  const r = ctx.rules ?? missionRules, d = r.types[type], i = missionSlots.indexOf(slot), best = ctx.best ?? {};
  const few = (ctx.runs ?? 0) < r.minRuns;
  // share × best within the limits; with few runs at least the start value. [strict]: a kind of play
  // the person hardly does (below the minimum) is not offered rather than made too hard.
  const target = (value, share, start, min, max, strict = false) => {
    if (!(value > 0)) return strict && value === 0 ? [] : start === undefined ? [] : [within(start, min, max)];
    if (!(share > 0) || (strict && value * share < min)) return [];
    return [within(Math.max(value * share, few && start !== undefined ? start : 0), min, max)];
  };
  const share = d.share?.[slot];
  const points = slotShare => best.s * r.types.points.share[slotShare];
  switch (type) {
    case 'distance': case 'points':
      return target(best[type === 'distance' ? 'm' : 's'], share, d.start[i], d.min, d.max).map(t => ({ target: t }));
    case 'ground': case 'ceiling':
      return target(best[type], share, d.start[i], d.min, d.max, true).map(t => ({ target: t }));
    case 'collect':
      return Object.entries(d.kinds).flatMap(([kind, k]) => target(best[kind], share, k.start[i], k.min, d.max, true).map(t => ({ kind, target: t })));
    case 'pass': {
      if (!best.passed) return Object.entries(d.start).map(([kind, start]) => ({ kind, target: within(start[i], d.min, d.max) }));
      // An obstacle of a debut only if a run at this slot's share of the best points gets there.
      return missionObstacles.filter(kind => !debutOf(kind) || points(slot) >= debutOf(kind))
        .flatMap(kind => target(best.passed[kind] ?? 0, share, undefined, debutOf(kind) ? d.debutMin : d.min, d.max, true).map(t => ({ kind, target: t })));
    }
    case 'noPickup': {
      const base = best.m > 0 ? Math.max(best.noPickup ?? 0, best.m * d.ofDistance) : undefined;
      return target(base, share, d.start[i], d.min, d.max).map(t => ({ target: t }));
    }
    case 'dailyDistance': return target(best.m, d.ofBest, d.start[0], d.min, d.max).map(t => ({ target: t }));
    case 'runs': return target(best.m, share, d.start[i], d.min, d.max).map(min => ({ target: d.count, min }));
    case 'debut': {
      if (!(best.s > 0) || few || !d.slots.includes(slot)) return [];
      const [low, high] = d.band.map(f => points(slot) * f);
      const hit = runnerDebuts.findLast(([p]) => p > low && p <= high);
      return hit ? [{ kind: hit[1], target: hit[0] }] : [];
    }
    default: return [];
  }
}

const max = (a, b) => a === undefined ? b : b === undefined ? a : Math.max(a, b);

/** The bests of [rec]; the first time taken once from the window of earlier runs (and the high score). */
export function bestsOf(rec, highScore = 0) {
  if (rec.best) return { best: { ...rec.best, s: max(rec.best.s, highScore || undefined) }, runs: rec.runs ?? 0 };
  const window = list(rec.window), best = {};
  for (const x of window) {
    best.m = max(best.m, x.m); best.s = max(best.s, x.s);
    if (!x.st) continue;
    for (const k of ['rose', 'mask', 'star', 'ground', 'ceiling']) best[k] = max(best[k], x.st[k]);
    best.passed ??= {};
    for (const kind of missionObstacles) best.passed[kind] = max(best.passed[kind], x.st.passed?.[kind] ?? 0);
    if (x.s === x.m) best.noPickup = max(best.noPickup, x.m);
  }
  if (highScore) best.s = max(best.s, highScore);
  return { best, runs: window.length };
}

/** [best] after a counted run: every value only rises; statistics only from plausible ones. */
export function raiseBest(best, run) {
  const next = { ...best, m: max(best.m, run.meters), s: max(best.s, run.score) };
  const st = run.stats;
  if (!st) return next;
  for (const k of ['rose', 'mask', 'star', 'ground', 'ceiling']) next[k] = max(best[k], st[k]);
  next.passed = Object.fromEntries(missionObstacles.map(kind => [kind, max(best.passed?.[kind] ?? 0, st.passed[kind] ?? 0)]));
  if (run.score === run.meters) next.noPickup = max(best.noPickup, run.meters);
  return next;
}

const pick = (entries, random, weight = () => 1) => {
  const w = entries.map(weight), total = w.reduce((a, b) => a + b, 0);
  let x = random() * total;
  for (const [i, v] of w.entries()) if ((x -= v) < 0) return entries[i];
  return entries.at(-1);
};

/** One mission for [slot]: a type not in [exclude], yesterday's types ([previous]) rarely. */
export function chooseMission(slot, ctx, exclude, previous, random) {
  const r = ctx.rules ?? missionRules;
  const types = Object.entries(r.types).filter(([type, d]) => d.slots.includes(slot) && (ctx.stats || d.basic) && !exclude.has(type))
    .map(([type, d]) => ({ type, d, options: missionOptions(type, slot, ctx) })).filter(x => x.options.length);
  if (!types.length) return null;
  const chosen = pick(types, random, x => x.d.weight * (previous.has(x.type) ? r.repeatWeight : 1));
  const option = chosen.options[Math.min(chosen.options.length - 1, Math.floor(random() * chosen.options.length))];
  return { slot, type: chosen.type, ...option, reward: r.slots[slot].reward, progress: 0, done: false };
}

/** The three missions of [day]: deterministic from person, day, the runs so far and yesterday's types. */
export function dayMissions(personId, day, ctx, previous = new Set()) {
  const taken = new Set();
  return missionSlots.map(slot => {
    const m = chooseMission(slot, ctx, taken, previous, seeded(personId, day, slot));
    if (m) taken.add(m.type);
    return m;
  }).filter(Boolean);
}

const context = (t, rec, stats) => ({ rules: rulesOf(t), stats, ...bestsOf(rec, t.store.get('runnerScores', rec.personId)?.best ?? 0) });

/**
 * The person's missions of the Berlin day of [at]; made on the first request of the day. [stats]:
 * whether the asking app sends run statistics (else only types checkable without them).
 */
export function missionsToday(t, personId, at, stats) {
  const rec = t.store.get('runnerMissions', personId) ?? { personId };
  const day = berlinDay(at.toISOString());
  if (rec.day === day) return rec;
  const previous = rec.day === dayBefore(day) ? list(rec.missions).map(m => m.type) : [];
  const missions = dayMissions(personId, day, context(t, rec, stats), new Set(previous));
  return t.store.put('runnerMissions', personId, { ...rec, day, stats, missions, rerolled: false, crate: false, todayMeters: 0, previousTypes: previous });
}

/** What a run brings a mission on its own; null if it cannot tell (no statistics). */
function runValue(m, { meters, score, stats }) {
  switch (m.type) {
    case 'distance': return meters;
    case 'points': case 'debut': return score;
    case 'collect': return stats ? stats[m.kind] : null;
    case 'ground': case 'ceiling': return stats ? stats[m.type] : null;
    case 'pass': return stats ? stats.passed[m.kind] ?? 0 : null;
    case 'noPickup': return stats ? (score === meters ? meters : 0) : null;
    default: return null;
  }
}

/**
 * Counts a finished run (inside runnerScore's transaction): the day's missions, rewards for those
 * it completes (once each) and the Missionskiste for all three; then the bests rise with the run.
 * [run]: `{ meters, score, stats (checked or null), statsSent, at }`.
 */
export function recordMissionRun(t, personId, run) {
  const rules = rulesOf(t);
  if (!rules) return { rewardMeters: 0, crate: 0, completed: [], record: null };
  const rec = missionsToday(t, personId, run.at, run.statsSent);
  const completed = [];
  const missions = list(rec.missions).map(m => {
    if (m.done) return m;
    let progress = m.progress;
    if (m.type === 'dailyDistance') progress += run.meters;
    else if (m.type === 'runs') progress += run.meters >= m.min ? 1 : 0;
    else { const v = runValue(m, run); if (v !== null) progress = Math.max(progress, v); }
    const done = progress >= m.target;
    if (done) completed.push(m.slot);
    return { ...m, progress, done, ...(done ? { doneAt: run.at.toISOString() } : {}) };
  });
  const rewardMeters = missions.filter(m => completed.includes(m.slot)).reduce((a, m) => a + m.reward, 0);
  const crate = !rec.crate && missions.length === missionSlots.length && missions.every(m => m.done);
  // The bests rise with this run for the coming days; today's missions stay as they are. The
  // window of earlier runs was only needed once, to start the bests.
  const { best, runs } = bestsOf(rec);
  const counted = run.meters >= rules.minMeters;
  const { window, ...kept } = rec;
  const next = t.store.put('runnerMissions', personId, {
    ...kept, missions, best: counted ? raiseBest(best, run) : best, runs: runs + (counted ? 1 : 0),
    todayMeters: (rec.todayMeters ?? 0) + run.meters, crate: rec.crate || crate,
  });
  return { rewardMeters, crate: crate ? 1 : 0, completed, record: next };
}

const plural = (n, one, many) => n === 1 ? one : many;
const number = new Intl.NumberFormat('de-DE');
const obstacleNames = {
  crate: ['Spring über %n Requisitenkiste', 'Spring über %n Requisitenkisten', 'Requisitenkisten'],
  flat: ['Spring über %n Kulisse', 'Spring über %n Kulissen', 'Kulissen'],
  lamp: ['Flieg unter %n Scheinwerfer hindurch', 'Flieg unter %n Scheinwerfern hindurch', 'Scheinwerfer'],
  border: ['Flieg durch %n Lücke unter den Soffitten', 'Flieg durch %n Lücken unter den Soffitten', 'Lücken'],
  sandbag: ['Lass %n Sandsack hinter dir', 'Lass %n Sandsäcke hinter dir', 'Sandsäcke'],
  drum: ['Komm an %n Kabeltrommel vorbei', 'Komm an %n Kabeltrommeln vorbei', 'Kabeltrommeln'],
  pile: ['Spring über %n Kistenstapel', 'Spring über %n Kistenstapel', 'Kistenstapel'],
  truss: ['Unterquere %n Traverse', 'Unterquere %n Traversen', 'Traversen'],
  drop: ['Unterquere %n Prospekt', 'Unterquere %n Prospekte', 'Prospekte'],
};
const debutNames = { drum: 'die Kabeltrommel', pile: 'den Kistenstapel', truss: 'die Traverse', drop: 'den Prospekt' };
const pickupNames = { rose: ['Rose', 'Rosen'], mask: ['Maske', 'Masken'], star: ['Stern', 'Sterne'] };

/** The mission's text and the unit of its progress, in German. */
export function missionText(m) {
  const n = number.format(m.target);
  switch (m.type) {
    case 'distance': return { text: `Lauf ${n} m in einem Durchgang`, unit: 'm' };
    case 'points': return { text: `Hol ${n} Punkte in einem Lauf`, unit: 'Punkte' };
    case 'collect': return { text: `Sammle ${n} ${plural(m.target, ...pickupNames[m.kind])} in einem Lauf`, unit: pickupNames[m.kind][1] };
    case 'ground': return { text: `Bleib ${n} m am Boden in einem Lauf`, unit: 'm' };
    case 'ceiling': return { text: `Flieg ${n} m unter der Decke in einem Lauf`, unit: 'm' };
    case 'pass': { const [one, many, unit] = obstacleNames[m.kind]; return { text: `${plural(m.target, one, many).replace('%n', n)} in einem Lauf`, unit }; }
    case 'noPickup': return { text: `Lauf ${n} m, ohne etwas einzusammeln`, unit: 'm' };
    case 'dailyDistance': return { text: `Lauf heute insgesamt ${n} m`, unit: 'm' };
    case 'runs': return { text: `Schaff heute ${n} Läufe mit je mindestens ${number.format(m.min)} m`, unit: 'Läufe' };
    case 'debut': return { text: `Erreiche ${debutNames[m.kind]}: ${n} Punkte in einem Lauf`, unit: 'Punkte' };
    default: return { text: 'Mission', unit: '' };
  }
}

/** The shine chance of a Missionskiste: the catalog's `dupes.shinyChance.mission`. */
const missionShine = t => {
  const s = t.runnerCatalog?.dupes?.shinyChance;
  return typeof s === 'number' ? s : s?.mission ?? s?.costume ?? 0;
};

/** What the app shows of the day's missions; [completed]: slots a run just completed. */
export function missionsView(t, rec, completed = []) {
  if (!rec) return null;
  const missions = list(rec.missions).map(m => ({
    slot: m.slot, type: m.type, ...(m.kind ? { kind: m.kind } : {}), target: m.target, ...(m.min !== undefined ? { min: m.min } : {}),
    progress: Math.min(m.progress, m.target), done: m.done, reward: m.reward, ...missionText(m),
    // Whether a single run must make it (`run`) or the day adds up (`day`).
    scope: m.type === 'dailyDistance' || m.type === 'runs' ? 'day' : 'run',
    ...(completed.includes(m.slot) ? { justDone: true } : {}),
    ...(m.rerolled ? { rerolled: true } : {}),
  }));
  return {
    day: rec.day, missions, rerollAvailable: !rec.rerolled && missions.some(m => !m.done), allDone: missions.length > 0 && missions.every(m => m.done),
    crate: { earned: rec.crate === true, shinyChance: missionShine(t) }, ...(completed.length ? { completed } : {}),
  };
}

/** GET /games/runner/missions: the day's missions; only apps that send run statistics ask. */
export function missions(t, uid) {
  if (!rulesOf(t)) fail(404, 'Nicht gefunden.');
  return t.store.transaction(() => missionsView(t, missionsToday(t, t.account(uid).personId, t.clock(), true)));
}

/** POST /games/runner/missions/reroll `{ slot }`: once a day, a new mission for an open one. */
export function rerollMission(t, uid, requestId, b) {
  if (typeof requestId !== 'string' || !requestId || requestId.length > 150) fail(400, 'Ein gültiger Änderungsschlüssel fehlt.');
  if (!rulesOf(t)) fail(404, 'Nicht gefunden.');
  if (!missionSlots.includes(b?.slot)) fail(400, 'Unbekannte Mission.');
  const key = missionRequestPrefix + requestId;
  return t.store.transaction(() => {
    const a = t.account(uid);
    const previous = t.store.db.prepare('SELECT result FROM requests WHERE uid=? AND request_id=?').get(uid, key);
    if (previous) return JSON.parse(previous.result);
    const rec = missionsToday(t, a.personId, t.clock(), true), old = list(rec.missions).find(m => m.slot === b.slot);
    if (rec.rerolled) fail(409, 'Heute wurde schon neu gewürfelt.', 'reroll_used');
    if (!old) fail(404, 'Diese Mission gibt es heute nicht.');
    if (old.done) fail(409, 'Diese Mission ist schon geschafft.', 'mission_done');
    const fresh = chooseMission(b.slot, context(t, rec, rec.stats !== false), new Set(rec.missions.map(m => m.type)), new Set(list(rec.previousTypes)), seeded(a.personId, rec.day, b.slot, 'reroll'));
    if (!fresh) fail(409, 'Für diese Mission gibt es gerade keine andere.', 'nothing_to_reroll');
    // A new mission starts at zero; the day's distance counts all of today (and is rewarded, if
    // already reached, with the next run, which is what credits missions).
    const mission = { ...fresh, rerolled: true, progress: fresh.type === 'dailyDistance' ? rec.todayMeters ?? 0 : 0 };
    const result = missionsView(t, t.store.put('runnerMissions', a.personId, { ...rec, rerolled: true, missions: rec.missions.map(m => m.slot === b.slot ? mission : m) }));
    t.store.db.prepare('INSERT INTO requests VALUES(?,?,?,?,?)').run(uid, key, 'runner.mission.reroll', JSON.stringify(result), t.clock().toISOString());
    t.store.audit(uid, 'runner.mission.reroll', `${b.slot} ${old.type}->${fresh.type}`);
    return result;
  });
}
