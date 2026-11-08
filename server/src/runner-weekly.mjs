import { AppError, runnerMaxMeters, stageRunner } from './theater.mjs';
import { berlinParts, fromBerlin } from './event-series.mjs';
import { creditGage, shinyChanceOf } from './runner-wardrobe.mjs';

// "Wochenprobe" of the stage runner (`runnerWeekly`): one course a week for everybody, three ranked
// runs per person, unlimited training on the same course.
//
// - The week: Monday 00:00 to Monday 00:00 Europe/Berlin, summer and winter time included, named by
//   its ISO week (`2026-W46`, the ISO year of its Thursday). Store kind `runnerWeeks`, id = week,
//   `{ week, seed, createdAt }`: a random uint32 made on the first request of the week, then fixed.
//   The app builds the course from it alone (`StageRunner` with its own PRNG), so everybody runs the
//   same one.
// - Attempts: `weeklyRules.attempts` ranked runs per person and week, the one exception to "never
//   limit how often someone plays" (the normal runs and training stay unlimited). An attempt counts
//   when the run starts (POST /games/runner/rounds `{ weekly: { week, ranked: true } }`): giving up,
//   closing the app or a crash cost it. Counted in runnerStart's transaction (BEGIN IMMEDIATE), so
//   starts at the same moment never get beyond the limit. 409 `attempts_used` once they are used,
//   409 `week_over` for any week but the current one.
// - The run knows its mode from its start (`weekly` on the run, runner-rounds.mjs): a result cannot
//   switch it. A run started in a week counts for that week, also when its result arrives after the
//   week ended (`roundTtlMs` at most).
// - Store kind `runnerWeekRuns`, id `${week}:${personId}`, `{ personId, week, used, attempts, best,
//   meters, bestAt, ghost, ranked, training, rewardSeen? }`: `best` only rises with ranked runs,
//   `bestAt` is when the server counted it. Equal scores: the earlier one ranks first.
// - Ghosts (`weeklyGhost`): the runner's height at 20 Hz of the run's own time (`StageRunner.time`),
//   one byte per sample, `(y − ceiling) / (floor − ceiling) · 255`, the bytes in base64; the app sends
//   a last byte 0 or 1 behind them: whether the run ended in a crash (a height never comes out as 0
//   or 1, the runner's middle stays more than 0.05 below the fly loft; without that byte: a crash).
//   Checked against the metres claimed (distance after that time, `runnerMaxMeters`) and the time the
//   server measured, like the score; a ghost that does not fit makes the run implausible (400). Only
//   the run that raises the person's best keeps its ghost, so each person has at most one; closing
//   the week drops them (only the current week's are ever shown).
// - Leaderboard and ghosts: active members with a ranked best above zero (as the other lists), by
//   their current name. Weekly runs count for the progress like any other run (`recordRun`: crate
//   points, Tagesbonus, Tagesmissionen, gage of duplicates), never for the all-time list
//   (`runnerScores`), the Monatsrangliste or the Monatsgala.
// - Rewards (`runnerWeeklyRewards`): a week is closed `roundTtlMs` after its end (results still on
//   their way are in by then), lazily on the next GET /games/runner/weekly and with the job of the
//   push worker (`settleWeeks`). Store kind `runnerWeekAwards`, id = week, written once in one
//   transaction with all its rewards (`{ week, closedAt, rules, players, placements }`, a placement
//   `{ rank, personId, name, score, meters, gage, crates, trophy? }`): nothing is given twice, also
//   not after a restart. Every ranked player gets `weeklyRules.crates` Wochenkiste, ranks 1 to 3
//   on top the gage and trophy of `weeklyRules.places` (gold, silver, bronze). The gage is credited
//   at once like the Monatsgala's Applaus (`creditGage`), so apps from before have it as well.
// - Wochenkisten: store kind `runnerWeekPrizes`, id `${week}:${personId}`, `{ week, personId, rank,
//   crates, opened, trophy? }`, written with the week's record; they never lapse, the earliest week
//   opens first (POST /games/runner/crates `{ crate: 'weekly', dupes: true }`, runner-wardrobe.mjs).
//   A crate is a normal draw of everything collectible (as the Zufallskiste) with the shine chance
//   `dupes.shinyChance.weekly`. Apps from before neither see nor count them (`weeklyCrates` is a
//   field of its own).
// - Trophies: counted from the frozen records (`placements[].trophy`), never stored apart, so a
//   deleted person takes theirs along. Shown beside every name of the weekly list and as the own
//   count (`trophies: { gold, silver, bronze }`).
// - Weeks closed by the rules before (`rules` missing: 30/20/10 gage for the places, 5 for every
//   other ranked player) are topped up once to these (`topUpWeek`): the crate, the trophy and the
//   gage missing to the new amount (nobody gives any back: an old 5 for taking part stays), in one
//   transaction that marks the record (`rules`, `toppedUpAt`, per placement `topUp`). The banner of
//   such a week shows again with what it brings now.
// - The app shows the latest closed week once (`lastWeek` `{ week, rank, score, gage, trophy,
//   crates }`, until PUT /games/runner/weekly/seen). No push of any kind.
// - Deleting a person (`forgetWeekly`) removes their records, ghosts, Wochenkisten and their entry of
//   every closed week (their trophies with it); the others keep their rank.

export const weeksKind = 'runnerWeeks';
export const weekRunsKind = 'runnerWeekRuns';
export const weekAwardsKind = 'runnerWeekAwards';
export const weekPrizesKind = 'runnerWeekPrizes';

/** All numbers of the Wochenprobe. */
export const weeklyRules = Object.freeze({
  attempts: 3,
  // Ghost samples per second of the run's own time, and the most a ghost may have (2000 s).
  hz: 20, maxSamples: 40000,
  // Claimed metres against the ghost's length: this share and these metres either way, plus a sample
  // more or less (whether the first one was taken at 0 s).
  ghostTolerance: 0.03, ghostSlackMeters: 10,
  // After the week: Wochenkisten for every ranked player, gage and a trophy on top for the places.
  // The version of these rules on every record (`rules`); records without it are topped up.
  rules: 2, crates: 1,
  places: Object.freeze({
    1: Object.freeze({ trophy: 'gold', gage: 100 }),
    2: Object.freeze({ trophy: 'silver', gage: 50 }),
    3: Object.freeze({ trophy: 'bronze', gage: 25 }),
  }),
  participant: Object.freeze({ gage: 0 }),
});

/** The kinds of weekly trophy, best first. */
export const weeklyTrophies = Object.freeze(['gold', 'silver', 'bronze']);

const fail = (status, message, code) => { throw new AppError(status, message, code); };
const dayMs = 86400000;
const pad = n => String(n).padStart(2, '0');
const weekPattern = /^(\d{4})-W(0[1-9]|[1-4]\d|5[0-3])$/;
const key = (week, personId) => `${week}:${personId}`;

/** The ISO week (`YYYY-Www`) of the Europe/Berlin calendar day of an instant. */
export function berlinWeek(at) {
  const p = berlinParts(+new Date(at)), day = Date.UTC(p.y, p.m, p.d), weekday = (new Date(day).getUTCDay() + 6) % 7;
  const thursday = new Date(day + (3 - weekday) * dayMs), year = thursday.getUTCFullYear();
  return `${year}-W${pad(1 + Math.floor((+thursday - Date.UTC(year, 0, 1)) / dayMs / 7))}`;
}

/** Start and end of [week] as ISO instants (Berlin midnight on its Monday and the next), or null. */
export function weekBounds(week) {
  const match = typeof week === 'string' && week.match(weekPattern);
  if (!match) return null;
  const year = +match[1], jan4 = Date.UTC(year, 0, 4), monday = jan4 - ((new Date(jan4).getUTCDay() + 6) % 7) * dayMs + (+match[2] - 1) * 7 * dayMs;
  const midnight = ms => { const d = new Date(ms); return new Date(fromBerlin({ y: d.getUTCFullYear(), m: d.getUTCMonth(), d: d.getUTCDate(), h: 0, mi: 0, s: 0, ms: 0 })).toISOString(); };
  const bounds = { startsAt: midnight(monday), endsAt: midnight(monday + 7 * dayMs) };
  // A week 53 of a year with 52 is the next year's first.
  return berlinWeek(bounds.startsAt) === week ? bounds : null;
}

/** When the results of [week] are all in and it is closed. */
const closesAt = week => Date.parse(weekBounds(week).endsAt) + stageRunner.roundTtlMs;

/** The record of [week] with its seed, made on the first request. */
function weekOf(t, week) {
  const s = t.store, old = s.get(weeksKind, week);
  if (old) return old;
  return s.put(weeksKind, week, { week, seed: Math.floor(t.random() * 4294967296) >>> 0, createdAt: t.clock().toISOString() });
}

const emptyRecord = (week, personId) => ({ personId, week, used: 0, attempts: [], best: 0, meters: 0, bestAt: null, ghost: null, ranked: 0, training: 0 });
const recordOf = (t, week, personId) => t.store.get(weekRunsKind, key(week, personId)) ?? emptyRecord(week, personId);
const recordsOf = (t, week) => t.store.db.prepare('SELECT data FROM entities WHERE kind=? AND id LIKE ? ORDER BY id').all(weekRunsKind, `${week}:%`).map(r => JSON.parse(r.data));

/** The ranked players of [week]: active members with a best above zero; earlier first on a tie. */
function rankedWeek(t, week) {
  const members = new Map(t.store.all('members').filter(m => m.active === true).map(m => [m.id, m]));
  return recordsOf(t, week).filter(x => x.best > 0 && members.has(x.personId))
    .sort((x, y) => y.best - x.best || String(x.bestAt).localeCompare(String(y.bestAt)) || x.personId - y.personId)
    .map((x, i) => ({ ...x, rank: i + 1, name: members.get(x.personId).name }));
}

/** What [rank] gets after the week: `{ gage, crates, trophy? }`. */
const rewardFor = rank => {
  const place = weeklyRules.places[rank] ?? weeklyRules.participant;
  return { gage: place.gage, crates: weeklyRules.crates, ...(place.trophy ? { trophy: place.trophy } : {}) };
};

/** Gives [personId] the Wochenkisten (and trophy) of [placement] in [week], once. */
function grantPrize(t, week, placement) {
  const id = key(week, placement.personId);
  if (!placement.crates || t.store.get(weekPrizesKind, id)) return;
  t.store.put(weekPrizesKind, id, { week, personId: placement.personId, rank: placement.rank, crates: placement.crates, opened: 0, ...(placement.trophy ? { trophy: placement.trophy } : {}) });
}

/** Writes the result of [week] with its rewards, once. */
function closeWeek(t, week, now) {
  const s = t.store;
  if (s.get(weekAwardsKind, week)) return;
  const placements = rankedWeek(t, week).map(x => ({ rank: x.rank, personId: x.personId, name: x.name, score: x.best, meters: x.meters, ...rewardFor(x.rank) }));
  for (const x of placements) {
    if (x.gage) creditGage(t, x.personId, x.gage);
    grantPrize(t, week, x);
  }
  for (const x of recordsOf(t, week).filter(x => x.ghost)) s.put(weekRunsKind, key(week, x.personId), { ...x, ghost: null });
  s.put(weekAwardsKind, week, { week, closedAt: now.toISOString(), rules: weeklyRules.rules, players: placements.length, placements });
}

/**
 * Brings [week], closed by the rules before, to the current ones, once: the crate, the trophy and
 * the gage missing to the new amount for every placement; the record is marked with it.
 */
function topUpWeek(t, week, now) {
  const s = t.store, awards = s.get(weekAwardsKind, week);
  if (!awards || (awards.rules ?? 1) >= weeklyRules.rules) return;
  const placements = awards.placements.map(x => {
    const reward = rewardFor(x.rank), extra = Math.max(0, reward.gage - (x.gage ?? 0)), trophy = reward.trophy ? { trophy: reward.trophy } : {};
    const next = { ...x, gage: (x.gage ?? 0) + extra, crates: reward.crates, ...trophy, topUp: { gage: extra, crates: reward.crates, ...trophy } };
    if (extra) creditGage(t, x.personId, extra);
    grantPrize(t, week, next);
    // The banner of the week shows again, now with the crate and trophy.
    const record = s.get(weekRunsKind, key(week, x.personId));
    if (record?.rewardSeen) s.put(weekRunsKind, key(week, x.personId), { ...record, rewardSeen: false });
    return next;
  });
  s.put(weekAwardsKind, week, { ...awards, rules: weeklyRules.rules, toppedUpAt: now.toISOString(), placements });
}

const dueWeeks = (t, now) => t.store.all(weeksKind).map(x => x.week).filter(week => closesAt(week) <= +now && !t.store.get(weekAwardsKind, week));
const oldWeeks = t => t.store.all(weekAwardsKind).filter(x => (x.rules ?? 1) < weeklyRules.rules).map(x => x.week);

/**
 * The job, run with the push worker: tops up weeks closed by the rules before and closes every
 * week due, each in its own transaction that reads the record again; no push.
 */
export function settleWeeks(t, now = t.clock()) {
  for (const week of oldWeeks(t)) t.store.transaction(() => topUpWeek(t, week, now));
  for (const week of dueWeeks(t, now)) t.store.transaction(() => closeWeek(t, week, now));
}

const noTrophies = () => Object.fromEntries(weeklyTrophies.map(kind => [kind, 0]));

/** Weekly trophies by person, counted from the frozen records: `Map(personId → { gold, silver, bronze })`. */
function trophyCounts(t) {
  const counts = new Map();
  for (const awards of t.store.all(weekAwardsKind)) for (const x of awards.placements) {
    if (!weeklyTrophies.includes(x.trophy)) continue;
    if (!counts.has(x.personId)) counts.set(x.personId, noTrophies());
    counts.get(x.personId)[x.trophy]++;
  }
  return counts;
}

/** The weekly trophies of [personId]: `{ gold, silver, bronze }`. */
export const weeklyTrophiesOf = (t, personId) => trophyCounts(t).get(personId) ?? noTrophies();

/** The latest closed week's result for [personId] while not seen, else null. */
function lastWeekOf(t, personId) {
  const awards = t.store.all(weekAwardsKind).at(-1), mine = awards?.placements.find(x => x.personId === personId);
  if (!mine || t.store.get(weekRunsKind, key(awards.week, personId))?.rewardSeen) return null;
  return { week: awards.week, rank: mine.rank, score: mine.score, gage: mine.gage, trophy: mine.trophy ?? null, crates: mine.crates ?? 0 };
}

const ownPrizes = (t, personId) => t.store.all(weekPrizesKind).filter(x => x.personId === personId);
const waiting = x => Math.max(0, x.crates - (x.opened ?? 0));

/** Wochenkisten [personId] has waiting. */
export const weeklyCrates = (t, personId) => ownPrizes(t, personId).reduce((sum, x) => sum + waiting(x), 0);

/** The prize with the earliest Wochenkiste waiting, or null; `all` is ordered by id, so by week. */
export const nextWeeklyCrate = (t, personId) => ownPrizes(t, personId).find(x => waiting(x) > 0) ?? null;

/** Uses one crate of [prize]; a repeated request never gets here (`once` in openCrate). */
export function markWeeklyCrateOpened(t, prize) {
  t.store.put(weekPrizesKind, key(prize.week, prize.personId), { ...prize, opened: (prize.opened ?? 0) + 1 });
}

/** What the wardrobe tells of the Wochenprobe, for [p] alone: crates, trophies and the crate's look. */
export function weeklyWardrobe(t, p) {
  const c = t.runnerCatalog;
  return {
    crates: weeklyCrates(t, p.personId), trophies: weeklyTrophiesOf(t, p.personId),
    crate: { ...(c.weeklyCrate ?? { id: 'weekly', kind: 'weekly', name: 'Wochenkiste', animation: 'generic' }), shinyChance: shinyChanceOf(c, 'weekly') },
  };
}

const attemptsOf = record => ({ used: record.used, max: weeklyRules.attempts });
const bestOf = record => record.best > 0 ? { score: record.best, meters: record.meters } : null;

/** What GET /games/runner/weekly answers (inside a transaction). */
function view(t, personId, now) {
  for (const week of oldWeeks(t)) topUpWeek(t, week, now);
  for (const week of dueWeeks(t, now)) closeWeek(t, week, now);
  const week = berlinWeek(now), { seed } = weekOf(t, week), record = recordOf(t, week, personId), ranked = rankedWeek(t, week);
  const trophies = trophyCounts(t), trophiesOf = id => trophies.get(id) ?? noTrophies();
  return {
    week, seed, ...weekBounds(week), attempts: attemptsOf(record), best: bestOf(record),
    leaderboard: ranked.map(x => ({ rank: x.rank, personId: x.personId, name: x.name, score: x.best, meters: x.meters, at: x.bestAt, me: x.personId === personId, trophies: trophiesOf(x.personId) })),
    ghosts: ranked.filter(x => x.ghost).map(x => ({ personId: x.personId, name: x.name, rank: x.rank, score: x.best, meters: x.meters, hz: weeklyRules.hz, y: x.ghost.y, crashed: x.ghost.crashed, me: x.personId === personId })),
    lastWeek: lastWeekOf(t, personId),
    // Added with `runnerWeeklyRewards`: the own weekly trophies of all weeks.
    trophies: trophiesOf(personId),
  };
}

/** GET /games/runner/weekly: the week, its seed, the own attempts, the list and all ghosts. */
export function weeklyView(t, uid) {
  return t.store.transaction(() => view(t, t.account(uid).personId, t.clock()));
}

/** PUT /games/runner/weekly/seen `{ week }`: the banner of that week's result was shown. */
export function weeklySeen(t, uid, b) {
  if (!weekBounds(b?.week)) fail(400, 'Bitte eine Woche als JJJJ-Www angeben.');
  return t.store.transaction(() => {
    const personId = t.account(uid).personId, id = key(b.week, personId), record = t.store.get(weekRunsKind, id);
    if (record && !record.rewardSeen) t.store.put(weekRunsKind, id, { ...record, rewardSeen: true });
    return view(t, personId, t.clock());
  });
}

/**
 * Starts a run of the Wochenprobe (inside runnerStart's transaction): [weekly] is the request's
 * `{ week, ranked }`, [start] opens the run with what it is to keep. A ranked one counts its attempt.
 */
export function startWeeklyRound(t, personId, weekly, at, start) {
  if (!weekly || typeof weekly !== 'object' || Array.isArray(weekly) || typeof weekly.ranked !== 'boolean' || !weekBounds(weekly.week)) fail(400, 'Ungültige Wochenprobe.');
  const week = berlinWeek(at), ranked = weekly.ranked;
  if (weekly.week !== week) fail(409, 'Diese Wochenprobe ist vorbei. Die neue Strecke wartet schon.', 'week_over');
  const { seed } = weekOf(t, week), record = recordOf(t, week, personId);
  if (ranked && record.used >= weeklyRules.attempts) fail(409, `Deine ${weeklyRules.attempts} Wertungsläufe dieser Woche sind gelaufen. Training geht weiter.`, 'attempts_used');
  const attempt = ranked ? record.used + 1 : null;
  const { roundId, startedAt } = start({ weekly: { week, ranked, attempt } });
  if (ranked) t.store.put(weekRunsKind, key(week, personId), { ...record, used: attempt, attempts: [...record.attempts, { roundId, startedAt, attempt }] });
  return { roundId, startedAt, weekly: { week, seed, ranked, attempt } };
}

/**
 * The ghost of a ranked run, checked: 400 `implausible` if it is missing (only apps with the
 * Wochenprobe start its runs, and they always send one), malformed or does not fit the run's
 * [meters] or the [elapsed] time the server measured.
 */
export function checkGhost(raw, { meters, elapsed }) {
  const { hz, maxSamples, ghostTolerance, ghostSlackMeters } = weeklyRules;
  const bad = () => fail(400, 'Die Aufzeichnung passt nicht zum Lauf.', 'implausible');
  if (typeof raw !== 'string' || raw.length > Math.ceil((maxSamples + 1) / 3) * 4 || raw.length % 4 || !/^[A-Za-z0-9+/]*={0,2}$/.test(raw)) bad();
  const bytes = Buffer.from(raw, 'base64'), flagged = bytes.length > 0 && bytes.at(-1) <= 1;
  const samples = flagged ? bytes.subarray(0, -1) : bytes, n = samples.length;
  if (n < 1 || n > maxSamples) bad();
  if (n / hz > (elapsed / 1000 + stageRunner.slackSeconds) * stageRunner.tolerance) bad();
  const low = runnerMaxMeters((n - 2) / hz) * (1 - ghostTolerance) - ghostSlackMeters;
  const high = runnerMaxMeters((n + 1) / hz) * (1 + ghostTolerance) + ghostSlackMeters;
  if (meters < low || meters > high) bad();
  return { y: Buffer.from(samples).toString('base64'), crashed: flagged ? bytes.at(-1) === 1 : true, samples: n };
}

/** What a weekly result tells the app: the own best, rank and attempts as they are now. */
export function weeklyAnswer(t, personId, { week, ranked, improved }) {
  const record = recordOf(t, week, personId);
  return { week, ranked, improved, best: bestOf(record), rank: rankedWeek(t, week).find(x => x.personId === personId)?.rank ?? null, attempts: attemptsOf(record) };
}

/**
 * Counts a finished run of the Wochenprobe (inside runnerScore's transaction) for the week it was
 * started in ([weekly] of the run). A ranked one may raise the best and keeps its [ghost] with it.
 */
export function recordWeeklyRun(t, personId, weekly, { score, meters, ghost, at }) {
  const record = recordOf(t, weekly.week, personId), improved = weekly.ranked && score > record.best;
  t.store.put(weekRunsKind, key(weekly.week, personId), {
    ...record, ...(weekly.ranked ? { ranked: record.ranked + 1 } : { training: record.training + 1 }),
    ...(improved ? { best: score, meters, bestAt: at, ghost } : {}),
  });
  return { week: weekly.week, ranked: weekly.ranked, improved };
}

/**
 * Removes the person's records, ghosts and Wochenkisten and their entry of every closed week, their
 * trophies with it (with the person).
 */
export function forgetWeekly(s, personId) {
  for (const x of s.all(weekRunsKind).filter(x => x.personId === personId)) s.delete(weekRunsKind, key(x.week, personId));
  for (const x of s.all(weekPrizesKind).filter(x => x.personId === personId)) s.delete(weekPrizesKind, key(x.week, personId));
  for (const awards of s.all(weekAwardsKind).filter(x => x.placements.some(o => o.personId === personId))) {
    s.put(weekAwardsKind, awards.week, { ...awards, placements: awards.placements.filter(o => o.personId !== personId) });
  }
}
