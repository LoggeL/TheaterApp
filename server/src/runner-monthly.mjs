import { AppError, stageRunner } from './theater.mjs';
import { berlinParts, fromBerlin } from './event-series.mjs';

// Monatsrangliste of the stage runner (`runnerMonthlyLeaderboard`): per person the best run of a
// calendar month in Europe/Berlin. The month changes at midnight German time on the first, summer
// and winter time included. Everybody starts again each month; the all-time list stays as it was.
//
// - Store kind `runnerMonthScores`, id `${month}:${personId}`, `{ personId, month, best, bestAt,
//   rounds, lastPlayedAt }`: written with every counted run, beside the all-time `runnerScores`.
//   `best` only rises within its month, `bestAt` is when it was first reached.
// - No history of single runs was kept before (only the all-time best with its time), so a month
//   before these records is filled where it can be told exactly: whoever set their all-time best in
//   that month had exactly that as the month's best. Other runs of that month before the deploy
//   are not known; those people join the month's list with their next run.
// - Same rules as the all-time list: active members with a score above zero, by their current
//   name; equal scores share a rank, the earlier best comes first.

const fail = (status, message, code) => { throw new AppError(status, message, code); };
export const monthScoresKind = 'runnerMonthScores';
const pad = n => String(n).padStart(2, '0');

/** `YYYY-MM` of the Europe/Berlin calendar month of an instant. */
export const berlinMonth = at => { const p = berlinParts(+new Date(at)); return `${p.y}-${pad(p.m + 1)}`; };

/** Start of [month] and of the month after it, as instants (Berlin midnight on the first). */
export function monthBounds(month) {
  const [y, m] = month.split('-').map(Number);
  const midnight = (year, index) => fromBerlin({ y: year, m: index, d: 1, h: 0, mi: 0, s: 0, ms: 0 });
  return { startsAt: new Date(midnight(y, m - 1)).toISOString(), endsAt: new Date(m === 12 ? midnight(y + 1, 0) : midnight(y, m)).toISOString() };
}

/**
 * Counts a run of [score] at [when] (ISO) for the month. [scores]: the person's all-time record
 * before this run; a first record of a month starts from it if that best was set in this month.
 */
export function recordMonthRun(t, personId, score, when, scores) {
  const month = berlinMonth(when), id = `${month}:${personId}`;
  const seeded = scores?.bestAt && scores.best > 0 && berlinMonth(scores.bestAt) === month ? { best: scores.best, bestAt: scores.bestAt } : { best: 0, bestAt: null };
  const old = t.store.get(monthScoresKind, id) ?? { ...seeded, rounds: 0 };
  const improved = score > (old.best ?? 0);
  return t.store.put(monthScoresKind, id, { personId, month, best: improved ? score : old.best, bestAt: improved ? when : old.bestAt, rounds: (old.rounds ?? 0) + 1, lastPlayedAt: when });
}

/** Removes the person's month records (with the person). */
export function forgetMonthScores(s, personId) {
  for (const x of s.all(monthScoresKind).filter(x => x.personId === personId)) s.delete(monthScoresKind, `${x.month}:${personId}`);
}

/**
 * The list of [entries] (`{ personId, score, at }`) for account [a]: active members with a score
 * above zero, equal scores share a rank, the earlier best comes first.
 */
export function rankedBoard(t, a, entries) {
  const members = new Map(t.store.all('members').filter(m => m.active === true).map(m => [m.id, m]));
  const ranked = entries.filter(x => x.score > 0 && members.has(x.personId))
    .sort((x, y) => y.score - x.score || String(x.at).localeCompare(String(y.at)) || x.personId - y.personId)
    .map((x, i, all) => ({ rank: all.findIndex(o => o.score === x.score) + 1, personId: x.personId, name: members.get(x.personId).name, score: x.score, achievedAt: x.at }));
  const own = ranked.find(x => x.personId === a.personId) ?? null;
  return { players: ranked.length, top: ranked.slice(0, stageRunner.leaderboardSize), own };
}

/** Each person's best of [month]: their month record, or an all-time best set in that month. */
function monthEntries(t, month) {
  const best = new Map();
  const take = (personId, score, at) => {
    const cur = best.get(personId);
    if (!(score > 0)) return;
    if (!cur || score > cur.score || (score === cur.score && String(at) < String(cur.at))) best.set(personId, { personId, score, at });
  };
  for (const x of t.store.all(monthScoresKind)) if (x.month === month) take(x.personId, x.best, x.bestAt);
  for (const x of t.store.all('runnerScores')) if (x.bestAt && berlinMonth(x.bestAt) === month) take(x.personId, x.best, x.bestAt);
  return [...best.values()];
}

/**
 * GET /games/runner/leaderboard?period=month[&month=YYYY-MM]: the all-time list's format plus
 * `period`, `month`, `startsAt` and `endsAt` (the instant the month ends). Without `month` the
 * current one; months after it do not exist yet. `period=all` is the all-time list with `period`.
 */
export function periodBoard(t, a, period, month) {
  if (period === 'all') return { period: 'all', ...t.runnerBoard(a) };
  if (period !== 'month') fail(400, 'Unbekannter Zeitraum der Rangliste.');
  const current = berlinMonth(t.clock());
  if (month != null && month !== '' && !/^\d{4}-(0[1-9]|1[0-2])$/.test(month)) fail(400, 'Bitte einen Monat als JJJJ-MM angeben.');
  const chosen = month || current;
  if (chosen > current) fail(400, 'Dieser Monat hat noch nicht begonnen.');
  return { period: 'month', month: chosen, ...monthBounds(chosen), ...rankedBoard(t, a, monthEntries(t, chosen)) };
}
