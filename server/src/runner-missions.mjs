import { createHash } from 'node:crypto';
import { missionEffort, recentMissionOptions } from './runner-mission-effort.mjs';
import { AppError } from './theater.mjs';
import { berlinDay } from './event-series.mjs';
import { logMissionRebalance, logMissionReroll, logMissionRun, logMissionsMade } from './runner-mission-log.mjs';
import { runnerProgress } from './runner-wardrobe.mjs';

// "Tagesmissionen" of the stage runner (`runnerMissions`): every person gets three missions per
// Europe/Berlin calendar day, easy, medium and hard, measured on recent ordinary performance.
//
// - Records remain intact, but do not permanently ratchet goals. Five or more timestamped ordinary
//   runs enable per-dimension quantiles from at most ten samples, at most 30 days old. Zeros count;
//   missing statistics do not become fabricated specialty performance. Before that, conservative
//   start goals cap record-derived targets. No high-score/admin or timestamp-less retry bootstrap.
// - The whole crate targets median completion <= ten runs (not merely a ten-run sample window).
//   See runner-mission-effort.mjs and docs/daily-mission-effort.md for assumptions and validation.
// - The basis freezes for the Berlin day, including its reroll. Legacy open goals are lowered once,
//   with progress/rewards and explicit admin overrides preserved; completed missions stay intact.
// - Which missions: deterministic from person and day (and yesterday's types, which are avoided),
//   never two of a type on one day. One mission per day may be rerolled for free.
// - A run's statistics are checked for plausibility (sums, pickup points, obstacles per metre,
//   debuts only with their metres, or for older apps their points); implausible ones count for no
//   mission, the run itself counts.
// - Apps without statistics (older ones) only get the types the server can check from metres and
//   points; the kind of client is decided when the day's missions are made.
// - "Without a pickup" (`noPickup`) is the only condition a run can break after it was met, so it is
//   measured up to the first pickup (`beforePickup` in the statistics): whatever is collected after
//   the target does not take the mission back. Apps that do not send it (older ones) keep the old
//   measure, the whole run if it has no pickup at all, else nothing.
// - Rewards are crate points (`runnerCratePoints`; like the Tagesbonus: crates only, not the
//   Ensemble-Strecke), once per mission; all three on one day also bring a "Missionskiste" (shine
//   chance by crate kind `mission` in the catalog's `dupes.shinyChance`). Missions made before kept
//   their reward in metres (no `unit`): they pay it times `legacyRewardPointsPerMeter`.

const fail = (status, message, code) => { throw new AppError(status, message, code); };
/** What a mission's reward in metres (made before `runnerCratePoints`) is worth in crate points. */
export const legacyRewardPointsPerMeter = 1.5;
/** The crate points mission [m] brings: its `reward`, which was metres for missions without `unit`. */
export const rewardPoints = m => m.unit === 'points' ? m.reward : Math.round(m.reward * legacyRewardPointsPerMeter);
const list = value => Array.isArray(value) ? value : [];
export const missionRequestPrefix = 'runner-mission:';
export const missionSlots = Object.freeze(['easy', 'medium', 'hard']);
// The metres at which an obstacle joins the course (`StageRunner.debuts` in the app, course rule
// `runnerCourse`): where it stands, so the course is the same for every run of a seed. Calibrated
// so that a typical run meets each one about where the points of before (`legacyRunnerDebuts`) did:
// halfway between a careful run and one that takes every pickup. The app's course test simulates
// it (test/runner_course_test.dart) and checks that these are the app's values.
export const runnerDebuts = Object.freeze([[185, 'drum'], [370, 'pile'], [555, 'truss'], [740, 'drop']]);
// The points at which an obstacle joined the course in apps up to 0.14 (no `course` sent).
export const legacyRunnerDebuts = Object.freeze([[250, 'drum'], [500, 'pile'], [750, 'truss'], [1000, 'drop']]);
// The course rule of apps whose obstacles join by metres (`course: 2` with the score).
export const runnerCourse = 2;
// A debut obstacle counts as passed where it stands, a bit ahead of the runner (as the borders).
const debutSlack = 10;
export const missionPickups = Object.freeze({ rose: 5, mask: 10, star: 25 });
export const missionObstacles = Object.freeze(['crate', 'flat', 'lamp', 'border', 'sandbag', 'drum', 'pile', 'truss', 'drop']);

/**
 * All numbers of the missions. `start`: targets per slot (easy, medium, hard) without enough runs;
 * `min`/`max`: limits of a target (for counts and metres of a kind of play, a share below `min` means
 * the type is not offered in that slot, rather than made harder than intended); `weight`: how often
 * a type is chosen; `basic`: checkable without the run's statistics (older apps).
 */
export const missionRules = Object.freeze({
  // Legacy record context; comparable recent samples have their own minimum in missionEffort.
  minRuns: 5,
  // Runs this short (an instant crash) count for nothing: no best, no counted run.
  minMeters: 20,
  // Crate points, the 300/600/1000 crate metres of before at ~1.5 points per metre.
  slots: { easy: { reward: 450 }, medium: { reward: 900 }, hard: { reward: 1500 } },
  // A type of yesterday is chosen with this share of its weight.
  repeatWeight: 0.2,
  // `share`: conservative cold-start record fractions, capped by start. Once sampled, the effort
  // policy uses the 40th/60th/80th per-dimension percentile instead of lifetime fractions.
  types: {
    distance: { weight: 3, basic: true, slots: missionSlots, share: { easy: 0.3, medium: 0.42, hard: 0.57 }, min: 20, max: 6000, start: [100, 150, 200] },
    points: { weight: 2, basic: true, slots: missionSlots, share: { easy: 0.3, medium: 0.44, hard: 0.58 }, min: 20, max: 9000, start: [120, 200, 300] },
    collect: { weight: 2, slots: missionSlots, share: { easy: 0.3, medium: 0.45, hard: 0.6 }, kinds: { rose: { min: 3, start: [5, 9, 14] }, mask: { min: 2, start: [2, 4, 6] }, star: { min: 1, start: [1, 2, 3] } }, max: 400 },
    ground: { weight: 1.5, slots: missionSlots, share: { easy: 0.25, medium: 0.38, hard: 0.55 }, min: 20, max: 4000, start: [20, 35, 55] },
    ceiling: { weight: 1.5, slots: missionSlots, share: { easy: 0.25, medium: 0.38, hard: 0.55 }, min: 10, max: 3000, start: [10, 20, 35] },
    // Obstacles of a debut only for those whose runs at this slot reach its metres; `min` is 1 for them.
    pass: { weight: 2, slots: missionSlots, share: { easy: 0.3, medium: 0.45, hard: 0.65 }, min: 2, debutMin: 1, max: 400, start: { crate: [4, 7, 10], flat: [3, 5, 8], lamp: [4, 7, 10], border: [3, 6, 9], sandbag: [2, 4, 6] } },
    // Distance before the first pickup: its OWN measured dimension, never normal distance.
    noPickup: { weight: 1, slots: missionSlots, share: { easy: 0.22, medium: 0.32, hard: 0.45 }, min: 5, max: 4000, start: [10, 15, 20] },
    // Metres today: three recent median runs, or a capped cold-start goal. Only easy.
    dailyDistance: { weight: 1.5, basic: true, slots: ['easy'], ofBest: 1, min: 60, max: 30000, start: [300] },
    // Reach an obstacle's metres in a run, if they lie near this slot's distance target: within
    // `band` times it (the highest such obstacle). A type of its own: apps up to 0.14 count the
    // missions of type `debut` (made before, by points) live with the score, and this one not at all.
    reach: { weight: 1.5, basic: true, slots: ['medium', 'hard'], band: [0.95, 1.25] },
    // Two qualifying runs at the recent median, not three rare record-fraction successes.
    runs: { weight: 1, basic: true, slots: ['easy', 'medium'], count: 2, share: { easy: 0.22, medium: 0.33 }, min: 20, max: 4000, start: [60, 80] },
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

const debutOf = kind => runnerDebuts.find(([, k]) => k === kind)?.[0] ?? 0;
const legacyDebutOf = kind => legacyRunnerDebuts.find(([, k]) => k === kind)?.[0] ?? 0;

/**
 * The checked statistics of a run, or null if they are missing or implausible: sums within the
 * metres, pickups exactly the points beyond the metres, no more pickup rows and obstacles than
 * sections fit in the distance, debut obstacles only with their metres (older apps: or their points,
 * [course] is not `runnerCourse`). `beforePickup` (newer apps
 * only, absent stays absent): within the metres, all of them in a run without pickups, and the
 * pickups must fit the way left after it.
 */
export function checkRunStats(raw, { meters, score, metersSent, course }) {
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
  const sections = meters / 6 + 2, rows = s.rose / 3 + s.mask / 2 + s.star;
  if (rows > sections) return null;
  if (Object.values(s.passed).reduce((a, b) => a + b, 0) > sections) return null;
  // Debut obstacles by metres (`course: 2`); older apps sent their points, so for them either rule
  // will do (they cannot tell which one their app had).
  const reached = kind => meters + debutSlack >= debutOf(kind) || (course !== runnerCourse && score >= legacyDebutOf(kind));
  for (const [, kind] of runnerDebuts) if (s.passed[kind] && !reached(kind)) return null;
  // Borders join the course at 80 m, sandbags at 150 m (counted where they stand, a bit ahead).
  if ((s.passed.border && meters < 70) || (s.passed.sandbag && meters < 140)) return null;
  if (raw.beforePickup !== undefined) {
    const before = count(raw.beforePickup);
    if (Number.isNaN(before) || before > meters || (score === meters && before !== meters)) return null;
    // The same count as above, on the way from the first pickup on: too high a claim would turn any
    // run into a `noPickup` one.
    if (rows > (meters - before) / 6 + 2) return null;
    s.beforePickup = before;
  }
  return s;
}


/**
 * The metres of a run with statistics before its first pickup. Older apps do not say: then the whole
 * run if it has no pickup at all, else nothing.
 */
const metersBeforePickup = ({ meters, score, stats }) => stats.beforePickup ?? (score === meters ? meters : 0);

/**
 * Targets a type offers in [slot]: recent comparable quantiles when available; otherwise
 * conservative start-capped record fractions. Returns `[{ kind?, target, min? }]`, empty when
 * a measured specialty is too rare or unknown no-pickup performance cannot justify an offer.
 */
export function missionOptions(type, slot, ctx) {
  const r = ctx.rules ?? missionRules, d = r.types[type], i = missionSlots.indexOf(slot), best = ctx.best ?? {};
  if (!d) return [];
  const adaptive = recentMissionOptions(type, slot, { ...ctx, rules: r }, nice, runnerDebuts);
  if (adaptive !== null) return adaptive;
  const few = (ctx.runs ?? 0) < r.minRuns;
  // Cold-start share × best, capped by start. [strict]: a kind of play
  // the person hardly does (below the minimum) is not offered rather than made too hard.
  const target = (value, share, start, min, max, strict = false) => {
    if (!(value > 0)) return strict && value === 0 ? [] : start === undefined ? [] : [within(start, min, max)];
    if (!(share > 0) || (strict && value * share < min)) return [];
    // Until comparable recent samples exist, lifetime records may only LOWER the conservative
    // starting goal, never ratchet it upward. Unknown debut-count goals are not offered.
    if (start === undefined && strict) return [];
    return [within(Math.min(start ?? max, value * share), min, max)];
  };
  const share = d.share?.[slot];
  const reach = slotShare => Math.min(best.m * r.types.distance.share[slotShare], r.types.distance.start[missionSlots.indexOf(slotShare)]);
  switch (type) {
    case 'distance': case 'points':
      return target(best[type === 'distance' ? 'm' : 's'], share, d.start[i], d.min, d.max).map(t => ({ target: t }));
    case 'ground': case 'ceiling':
      return target(best[type], share, d.start[i], d.min, d.max, true).map(t => ({ target: t }));
    case 'collect':
      return Object.entries(d.kinds).flatMap(([kind, k]) => target(best[kind], share, k.start[i], k.min, d.max, true).map(t => ({ kind, target: t })));
    case 'pass': {
      if (!best.passed) return Object.entries(d.start).map(([kind, start]) => ({ kind, target: within(start[i], d.min, d.max) }));
      // An obstacle of a debut only if a run at this slot's share of the best distance gets there.
      return missionObstacles.filter(kind => !debutOf(kind) || reach(slot) >= debutOf(kind))
        .flatMap(kind => target(best.passed[kind] ?? 0, share, d.start[kind]?.[i], debutOf(kind) ? d.debutMin : d.min, d.max, true).map(t => ({ kind, target: t })));
    }
    case 'noPickup': {
      const base = best.noPickup;
      return base > 0 ? target(base, share, d.start[i], d.min, d.max, true).map(t => ({ target: t })) : [];
    }
    case 'dailyDistance': return target(best.m, d.ofBest, d.start[0], d.min, d.max).map(t => ({ target: t }));
    case 'runs': return target(best.m, share, d.start[i], d.min, d.max).map(min => ({ target: d.count, min }));
    case 'reach': {
      if (!(best.m > 0) || few || !d.slots.includes(slot)) return [];
      const [low, high] = d.band.map(f => reach(slot) * f);
      const hit = runnerDebuts.findLast(([m]) => m > low && m <= high && m <= reach(slot));
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
  const clean = metersBeforePickup(run);
  if (clean > 0) next.noPickup = max(best.noPickup, clean);
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
  return { slot, type: chosen.type, ...option, reward: r.slots[slot].reward, unit: 'points', progress: 0, done: false };
}

/** The three missions of [day]: deterministic from person, day, the runs so far and yesterday's types. */
export function dayMissions(personId, day, ctx, previous = new Set()) {
  const taken = new Set();
  // Allocate the most restricted slot first so easy cannot consume hard's only eligible type.
  const chosen = new Map();
  for (const slot of [...missionSlots].reverse()) {
    const m = chooseMission(slot, ctx, taken, previous, seeded(personId, day, slot));
    if (m) { taken.add(m.type); chosen.set(slot, m); }
  }
  return missionSlots.map(slot => chosen.get(slot)).filter(Boolean);
}

const recentOf = (rec, at) => list(rec.recent).filter(x => Number.isFinite(Date.parse(x.at)) && Date.parse(x.at) <= +at && +at - Date.parse(x.at) <= missionEffort.maxAgeDays * 86400000).slice(-missionEffort.window);
const context = (t, rec, stats, at = t.clock()) => ({
  rules: rulesOf(t), stats,
  ...(rec.day === berlinDay(at.toISOString()) && rec.effortBasis ? rec.effortBasis : {
    ...bestsOf(rec), recent: recentOf(rec, at),
  }),
});

/**
 * The person's missions of the Berlin day of [at]; made on the first request of the day. [stats]:
 * whether the asking app sends run statistics (else only types checkable without them).
 */
/** Shared completion/idempotence rules for runs and downward balancing. */
function completeMissions(rec, candidates, at, source) {
  const completed = [];
  const missions = candidates.map(m => {
    if (m.done || m.progress < m.target) return m;
    completed.push(m.slot);
    return { ...m, done: true, doneAt: at.toISOString(), ...(source ? { completionSource: source } : {}) };
  });
  return { missions, completed,
    rewardPoints: missions.filter(m => completed.includes(m.slot)).reduce((n, m) => n + rewardPoints(m), 0),
    crate: !rec.crate && missions.length === missionSlots.length && missions.every(m => m.done) ? 1 : 0 };
}

/** Once per legacy day, lower open goals without replacing slots or reconstructing old runs. */
function rebalanceToday(t, rec, at) {
  if ((rec.effortVersion ?? 0) >= missionEffort.version) return rec;
  const basis = { rules: rulesOf(t), stats: rec.stats, ...bestsOf(rec), recent: recentOf(rec, at) };
  const changes = [];
  const candidates = list(rec.missions).map(m => {
    if (m.done) return m;
    if (m.targetOverride?.source === 'admin' && m.targetOverride.day === rec.day) {
      changes.push({ slot: m.slot, type: m.type, reason: 'explicit-admin-override' });
      return m;
    }
    let option = missionOptions(m.type, m.slot, basis).find(o => o.kind === m.kind);
    // Do not replace an existing specialty just because it would no longer be generated.
    // Keep its meaning and use its conservative starting cap, without claiming measured support.
    if (!option) {
      const d = basis.rules.types[m.type], i = missionSlots.indexOf(m.slot);
      const start = m.type === 'collect' ? d?.kinds?.[m.kind]?.start?.[i]
        : m.type === 'pass' ? d?.start?.[m.kind]?.[i]
        : ['ground', 'ceiling', 'noPickup'].includes(m.type) ? d?.start?.[i] : undefined;
      if (Number.isFinite(start) && start > 0) option = { target: start, fallback: true };
    }
    if (!option) { changes.push({ slot: m.slot, type: m.type, reason: 'unsupported-or-ineligible' }); return m; }
    const next = { ...m, target: Math.min(m.target, option.target), ...(m.type === 'runs' ? { min: Math.min(m.min, option.min) } : {}) };
    changes.push({ slot: m.slot, type: m.type, before: { target: m.target, ...(m.min !== undefined ? { min: m.min } : {}) },
      after: { target: next.target, ...(next.min !== undefined ? { min: next.min } : {}) }, progress: m.progress, ...(option.fallback ? { source: 'coldStartFallback' } : {}) });
    return next;
  });
  const settled = completeMissions(rec, candidates, at, 'effortRebalance');
  const { best, runs, recent } = basis;
  const next = t.store.put('runnerMissions', rec.personId, { ...rec, missions: settled.missions, crate: rec.crate || !!settled.crate,
    effortVersion: missionEffort.version, effortBasis: { best, runs, recent }, effortRebalance: { version: missionEffort.version, at: at.toISOString(), changes } });
  if (settled.rewardPoints || settled.crate) {
    const p = runnerProgress(t, rec.personId);
    t.store.put('runnerProgress', rec.personId, { ...p, missionPoints: (p.missionPoints ?? 0) + settled.rewardPoints,
      missionCrates: (p.missionCrates ?? 0) + settled.crate });
  }
  logMissionRebalance(t, rec, next, at);
  t.store.audit('system', 'runner.mission.rebalance', JSON.stringify({ personId: rec.personId, day: rec.day, version: missionEffort.version, changes, completed: settled.completed }));
  return next;
}

export function missionsToday(t, personId, at, stats) {
  const rec = t.store.get('runnerMissions', personId) ?? { personId };
  const day = berlinDay(at.toISOString());
  if (rec.day === day) return rebalanceToday(t, rec, at);
  const previous = rec.day === dayBefore(day) ? list(rec.missions).map(m => m.type) : [];
  const basis = context(t, rec, stats, at);
  const missions = dayMissions(personId, day, basis, new Set(previous));
  const { best, runs, recent } = basis;
  const made = t.store.put('runnerMissions', personId, { ...rec, day, stats, missions, effortBasis: { best, runs, recent }, effortVersion: missionEffort.version, rerolled: false, crate: false, todayMeters: 0, previousTypes: previous });
  // History for balancing (runner-mission-log.mjs), using the exact frozen generation basis.
  return logMissionsMade(t, made, basis);
}

/** What a run brings a mission on its own; null if it cannot tell (no statistics). */
function runValue(m, run) {
  const { meters, score, stats } = run;
  switch (m.type) {
    case 'distance': return meters;
    case 'points': case 'debut': return score;
    case 'reach': return meters;
    case 'collect': return stats ? stats[m.kind] : null;
    case 'ground': case 'ceiling': return stats ? stats[m.type] : null;
    case 'pass': return stats ? stats.passed[m.kind] ?? 0 : null;
    case 'noPickup': return stats ? metersBeforePickup(run) : null;
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
  if (!rules) return { rewardPoints: 0, crate: 0, completed: [], record: null };
  const rec = missionsToday(t, personId, run.at, run.statsSent);
  const candidates = list(rec.missions).map(m => {
    if (m.done) return m;
    let progress = m.progress;
    if (m.type === 'dailyDistance') progress += run.meters;
    else if (m.type === 'runs') progress += run.meters >= m.min ? 1 : 0;
    else { const v = runValue(m, run); if (v !== null) progress = Math.max(progress, v); }
    return { ...m, progress };
  });
  const { missions, completed, rewardPoints: reward, crate } = completeMissions(rec, candidates, run.at);
  // Preserve records separately from timestamped ordinary calibration samples. Neither changes
  // today's frozen missions or reroll basis. The old timestamp-less window is no longer needed.
  const { best, runs } = bestsOf(rec);
  const counted = run.meters >= rules.minMeters;
  const { window, ...kept } = rec;
  const next = t.store.put('runnerMissions', personId, {
    ...kept, missions, best: counted ? raiseBest(best, run) : best, runs: runs + (counted ? 1 : 0),
    recent: (counted && !run.weekly ? [...recentOf(rec, run.at), {
      at: run.at.toISOString(), m: run.meters, s: run.score, ...(run.stats ? { st: run.stats } : {}),
    }] : recentOf(rec, run.at)).slice(-missionEffort.window),
    todayMeters: (rec.todayMeters ?? 0) + run.meters, crate: rec.crate || !!crate,
  });
  logMissionRun(t, rec, next, run);
  return { rewardPoints: reward, crate: crate ? 1 : 0, completed, record: next };
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
    case 'reach': return { text: `Erreiche ${debutNames[m.kind]}: ${n} m in einem Lauf`, unit: 'm' };
    // Made before the debuts went by metres.
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
    // `reward` in crate points (`rewardUnit`, from `runnerCratePoints`; older apps say "m").
    progress: Math.min(m.progress, m.target), done: m.done, reward: rewardPoints(m), rewardUnit: 'points', ...missionText(m),
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
    logMissionReroll(t, rec, old, mission, context(t, rec, rec.stats !== false));
    return result;
  });
}
