import { AppError, runnerMaxMeters, stageRunner } from './theater.mjs';
import { berlinParts, fromBerlin } from './event-series.mjs';
import { creditGage } from './runner-wardrobe.mjs';

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
// - Rewards: a week is closed `roundTtlMs` after its end (results still on their way are in by then),
//   lazily on the next GET /games/runner/weekly and with the job of the push worker (`settleWeeks`).
//   Store kind `runnerWeekAwards`, id = week, written once in one transaction with all its gage
//   (`{ week, closedAt, players, placements }`): nothing is given twice, also not after a restart.
//   Ranks 1 to 3 get `weeklyRules.places`, every other ranked player `weeklyRules.participant`,
//   credited like the Monatsgala's Applaus (`creditGage`). Smaller than the Monatsgala: four weeks of
//   first places bring less than its gold. The app shows the latest closed week once (`lastWeek`,
//   until PUT /games/runner/weekly/seen). No push of any kind.
// - Deleting a person (`forgetWeekly`) removes their records and ghosts and their entry of every
//   closed week; the others keep their rank.

export const weeksKind = 'runnerWeeks';
export const weekRunsKind = 'runnerWeekRuns';
export const weekAwardsKind = 'runnerWeekAwards';

/** All numbers of the Wochenprobe. */
export const weeklyRules = Object.freeze({
  attempts: 3,
  // Ghost samples per second of the run's own time, and the most a ghost may have (2000 s).
  hz: 20, maxSamples: 40000,
  // Claimed metres against the ghost's length: this share and these metres either way, plus a sample
  // more or less (whether the first one was taken at 0 s).
  ghostTolerance: 0.03, ghostSlackMeters: 10,
  // Gage after the week: by rank, else for every ranked player.
  places: Object.freeze({ 1: 30, 2: 20, 3: 10 }), participant: 5,
});

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

const gageFor = rank => weeklyRules.places[rank] ?? weeklyRules.participant;

/** Writes the result of [week] with its gage, once. */
function closeWeek(t, week, now) {
  const s = t.store;
  if (s.get(weekAwardsKind, week)) return;
  const placements = rankedWeek(t, week).map(x => ({ rank: x.rank, personId: x.personId, name: x.name, score: x.best, meters: x.meters, gage: gageFor(x.rank) }));
  for (const x of placements) creditGage(t, x.personId, x.gage);
  for (const x of recordsOf(t, week).filter(x => x.ghost)) s.put(weekRunsKind, key(week, x.personId), { ...x, ghost: null });
  s.put(weekAwardsKind, week, { week, closedAt: now.toISOString(), players: placements.length, placements });
}

const dueWeeks = (t, now) => t.store.all(weeksKind).map(x => x.week).filter(week => closesAt(week) <= +now && !t.store.get(weekAwardsKind, week));

/** The job, run with the push worker: closes every week due, each in its own transaction; no push. */
export function settleWeeks(t, now = t.clock()) {
  for (const week of dueWeeks(t, now)) t.store.transaction(() => closeWeek(t, week, now));
}

/** The latest closed week's result for [personId] while not seen, else null. */
function lastWeekOf(t, personId) {
  const awards = t.store.all(weekAwardsKind).at(-1), mine = awards?.placements.find(x => x.personId === personId);
  if (!mine || t.store.get(weekRunsKind, key(awards.week, personId))?.rewardSeen) return null;
  return { week: awards.week, rank: mine.rank, score: mine.score, gage: mine.gage };
}

const attemptsOf = record => ({ used: record.used, max: weeklyRules.attempts });
const bestOf = record => record.best > 0 ? { score: record.best, meters: record.meters } : null;

/** What GET /games/runner/weekly answers (inside a transaction). */
function view(t, personId, now) {
  for (const week of dueWeeks(t, now)) closeWeek(t, week, now);
  const week = berlinWeek(now), { seed } = weekOf(t, week), record = recordOf(t, week, personId), ranked = rankedWeek(t, week);
  return {
    week, seed, ...weekBounds(week), attempts: attemptsOf(record), best: bestOf(record),
    leaderboard: ranked.map(x => ({ rank: x.rank, personId: x.personId, name: x.name, score: x.best, meters: x.meters, at: x.bestAt, me: x.personId === personId })),
    ghosts: ranked.filter(x => x.ghost).map(x => ({ personId: x.personId, name: x.name, rank: x.rank, score: x.best, meters: x.meters, hz: weeklyRules.hz, y: x.ghost.y, crashed: x.ghost.crashed, me: x.personId === personId })),
    lastWeek: lastWeekOf(t, personId),
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

/** Removes the person's records and ghosts and their entry of every closed week (with the person). */
export function forgetWeekly(s, personId) {
  for (const x of s.all(weekRunsKind).filter(x => x.personId === personId)) s.delete(weekRunsKind, key(x.week, personId));
  for (const awards of s.all(weekAwardsKind).filter(x => x.placements.some(o => o.personId === personId))) {
    s.put(weekAwardsKind, awards.week, { ...awards, placements: awards.placements.filter(o => o.personId !== personId) });
  }
}
