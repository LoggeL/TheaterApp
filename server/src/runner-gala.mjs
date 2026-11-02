import { latestGala, monthAwardsKind, monthEntries, rankedPlayers } from './runner-monthly.mjs';
import { fromBerlin } from './event-series.mjs';
import { creditGage, shinyChanceOf } from './runner-wardrobe.mjs';

// "Monatsgala" of the stage runner (`runnerMonthlyGala`): at the end of each month the players get
// prizes from the Monatsrangliste (runner-monthly.mjs). No game limit: this only rewards.
//
// - When: a month's gala opens at 10:00 Berlin on the first of the next month (`galaOpensAt`). The
//   job (`settleGala`) runs with the push worker every 15 s; a server that was down catches up,
//   every month in order. Months before `galaFirstMonth` never have a gala; moving that one line
//   moves the start.
// - Frozen: store kind `runnerMonthAwards`, id = month, written once in one transaction with all its
//   prizes (`{ month, opensAt, closedAt, players, placements }`). Later changes of the list change
//   nothing, nothing is given twice, also not after a restart. A month with nobody on the list gets
//   its record too. Records of October 2026 may still carry `pushedAt` and `recipients` from the
//   push it had then; nothing reads them.
// - Late results: a run counts for the month its result reaches the server (`runnerScore`, no client
//   time; a result older than `roundTtlMs` is rejected), so results from the app's outbox and runs
//   still open at midnight belong to the new month. The time until 10:00 is not there for them:
//   the month's list was already final at midnight, the job only reads it later.
// - Who: as the list (`rankedPlayers`): active members with a score above zero. Equal scores share a
//   rank and the prize of that rank. Each person gets exactly one prize (`galaPrizes`): a place on
//   the podium, else Aufsteiger, else Applaus.
// - Aufsteiger: from rank 4, a best in the month before and a real gain; the largest gain in percent
//   (compared as whole numbers), then the higher best, then the list's order. None: no such prize. The
//   month before counts from `galaPrizes.recordsSince`: earlier months only have the all-time bests
//   that fell into them, too little to compare, so October 2026 has no Aufsteiger.
// - Store kind `runnerGalaPrizes`, id `${month}:${personId}`, for prizes with crates: `{ month,
//   personId, prize, trophy?, crates, opened }`. Trophies (month and kind) stay there for good; Gala-
//   Kisten never lapse, the earliest opens first. A crate is a normal draw of everything collectible
//   (as the Zufallskiste) with the shine chance `dupes.shinyChance.gala`, only for apps with `dupes`.
// - Applaus: gage like a duplicate brings (`p.gage`, `p.gageEarned`), at once.
// - Visible: the winners of the latest gala show their mask in both rankings until the next one
//   (`rankedBoard`, field `trophy`). The wardrobe has `gala` (`galaWardrobe`): only the person's own
//   crates, trophies and the month not celebrated yet, as it is stored with every opening
//   (`requests`). Names of others are served only by GET /games/runner/gala (`galaView`). The
//   celebration is remembered on the server (`p.galaSeen`, the latest month shown). Who never
//   played gets none. Apps from before ignore all of it; their Applaus shows as gage.
// - Deleting a person (`forgetGala`) removes their prizes and their entry of every record; the
//   others keep their rank, `players` stays a mere count.
// - No push: the gala is found in the game (the celebration on the next opening), never announced
//   by a push, also not with `pushEnabled` or when catching up.

/** The first month with a gala (`YYYY-MM`). */
export const galaFirstMonth = '2026-10';

/** Everything the Monatsgala gives; a rank not listed gets `climber` or `applause`. */
export const galaPrizes = Object.freeze({
  opensAtHour: 10,
  // The first month whose records can be compared with for the Aufsteiger (`runnerMonthScores`).
  recordsSince: '2026-10',
  places: Object.freeze({
    1: Object.freeze({ prize: 'gold', trophy: 'gold', crates: 3, gage: 0 }),
    2: Object.freeze({ prize: 'silver', trophy: 'silver', crates: 2, gage: 0 }),
    3: Object.freeze({ prize: 'bronze', trophy: 'bronze', crates: 1, gage: 0 }),
  }),
  climber: Object.freeze({ prize: 'climber', crates: 1, gage: 0 }),
  applause: Object.freeze({ prize: 'applause', crates: 0, gage: 50 }),
});

/** The kinds of trophy, as they name the pictures `trophy-mask-<kind>.webp`. */
export const galaTrophies = Object.freeze(['gold', 'silver', 'bronze']);

const prizesKind = 'runnerGalaPrizes';
const monthNames = ['Januar', 'Februar', 'März', 'April', 'Mai', 'Juni', 'Juli', 'August', 'September', 'Oktober', 'November', 'Dezember'];
const key = (month, personId) => `${month}:${personId}`;
const pad = n => String(n).padStart(2, '0');
const shift = (month, by) => {
  const [y, m] = month.split('-').map(Number), index = y * 12 + m - 1 + by;
  return `${Math.floor(index / 12)}-${pad(index % 12 + 1)}`;
};

/** When the gala of [month] opens, as an ISO instant. */
export function galaOpensAt(month) {
  const [y, m] = shift(month, 1).split('-').map(Number);
  return new Date(fromBerlin({ y, m: m - 1, d: 1, h: galaPrizes.opensAtHour, mi: 0, s: 0, ms: 0 })).toISOString();
}

/** The months whose gala has opened by [now], the oldest first. */
function dueMonths(now) {
  const months = [];
  for (let month = galaFirstMonth; Date.parse(galaOpensAt(month)) <= +now; month = shift(month, 1)) months.push(month);
  return months;
}

/** Each person's best of the month before [month]; nothing while there is no record to compare. */
function bestsBefore(t, month) {
  const before = shift(month, -1);
  return new Map(before < galaPrizes.recordsSince ? [] : monthEntries(t, before).map(x => [x.personId, x.score]));
}

/** The Aufsteiger among [ranked], or undefined: see the rules above. */
function climberOf(ranked, before) {
  const gain = x => ({ ...x, previous: before.get(x.personId) });
  return ranked.filter(x => x.rank > 3 && before.get(x.personId) < x.score).map(gain)
    .sort((x, y) => y.score * x.previous - x.score * y.previous || y.score - x.score)[0];
}

/** One line of the record with its prize: exactly one for each person. */
function placement(x, climber) {
  const won = galaPrizes.places[x.rank] ?? (x.personId === climber?.personId ? galaPrizes.climber : galaPrizes.applause);
  return { ...x, prize: won.prize, ...(won.trophy ? { trophy: won.trophy } : {}), crates: won.crates, gage: won.gage, ...(won === galaPrizes.climber ? { previous: climber.previous } : {}) };
}

/** Writes the record of [month] with all its prizes; no push. */
function closeMonth(t, month, now) {
  const s = t.store;
  if (s.get(monthAwardsKind, month)) return;
  const ranked = rankedPlayers(t, monthEntries(t, month));
  const climber = climberOf(ranked, bestsBefore(t, month));
  const placements = ranked.map(x => placement(x, climber));
  for (const x of placements) {
    if (x.crates) s.put(prizesKind, key(month, x.personId), { month, personId: x.personId, prize: x.prize, ...(x.trophy ? { trophy: x.trophy } : {}), crates: x.crates, opened: 0 });
    if (x.gage) creditGage(t, x.personId, x.gage);
  }
  s.put(monthAwardsKind, month, { month, opensAt: galaOpensAt(month), closedAt: now.toISOString(), players: placements.length, placements });
}

/** The job, run with the push worker: closes every month due; repeated calls change nothing. */
export function settleGala(t, now = t.clock()) {
  const s = t.store;
  // Each month in a transaction of its own that reads the record again; none while nothing is due.
  for (const month of dueMonths(now).filter(month => !s.get(monthAwardsKind, month))) s.transaction(() => closeMonth(t, month, now));
}

const ownPrizes = (t, personId) => t.store.all(prizesKind).filter(x => x.personId === personId);
const waiting = x => Math.max(0, x.crates - (x.opened ?? 0));

/** Gala-Kisten [personId] has waiting. */
export const galaCrates = (t, personId) => ownPrizes(t, personId).reduce((sum, x) => sum + waiting(x), 0);

/** The prize with the earliest crate waiting, or null; `all` is ordered by id, so by month. */
export const nextGalaCrate = (t, personId) => ownPrizes(t, personId).find(x => waiting(x) > 0) ?? null;

/** Uses one crate of [prize]; a repeated request never gets here (`once` in openCrate). */
export function markGalaCrateOpened(t, prize) {
  t.store.put(prizesKind, key(prize.month, prize.personId), { ...prize, opened: (prize.opened ?? 0) + 1 });
}

/** [p] with the celebration up to [month] shown, never beyond the latest gala. */
export function markGalaSeen(t, p, month) {
  const latest = latestGala(t)?.month, seen = latest && month > latest ? latest : month;
  return latest && seen > (p.galaSeen ?? '') ? { ...p, galaSeen: seen } : p;
}

/** The latest gala's month if [p] has not seen its celebration yet; for those who ever played. */
function unseenGala(t, p) {
  const gala = latestGala(t);
  return gala?.placements.length && gala.month > (p.galaSeen ?? '') && t.store.get('runnerScores', p.personId)?.rounds > 0 ? gala.month : null;
}

/** What the wardrobe tells of the gala, for [p] alone: see the rules above. */
export function galaWardrobe(t, p) {
  const c = t.runnerCatalog;
  return {
    crates: galaCrates(t, p.personId), unseen: unseenGala(t, p),
    trophies: ownPrizes(t, p.personId).filter(x => x.trophy).map(x => ({ month: x.month, trophy: x.trophy })).reverse(),
    crate: { ...c.galaCrate, shinyChance: shinyChanceOf(c, 'gala') }, masks: c.galaMasks,
  };
}

/**
 * GET /games/runner/gala: the latest gala as the celebration shows it, `{ gala: null }` before the
 * first. The podium (ranks 1 to 3, more people with a shared rank) and the caller's own prize.
 */
export function galaView(t, uid) {
  const a = t.account(uid), gala = latestGala(t);
  if (!gala) return { gala: null };
  const mine = gala.placements.find(x => x.personId === a.personId);
  const podium = gala.placements.filter(x => x.trophy).map(x => ({ rank: x.rank, name: x.name, score: x.score, trophy: x.trophy, me: x.personId === a.personId }));
  const own = mine ? { rank: mine.rank, score: mine.score, prize: mine.prize, crates: mine.crates, gage: mine.gage, ...(mine.trophy ? { trophy: mine.trophy } : {}), ...(mine.previous ? { previous: mine.previous } : {}) } : null;
  return { gala: { month: gala.month, monthName: monthNames[+gala.month.slice(5) - 1], opensAt: gala.opensAt, players: gala.players, podium, own } };
}

/** Removes [personId] from every gala (with the person). */
export function forgetGala(s, personId) {
  for (const x of s.all(prizesKind).filter(x => x.personId === personId)) s.delete(prizesKind, key(x.month, personId));
  for (const gala of s.all(monthAwardsKind).filter(x => x.placements.some(o => o.personId === personId))) {
    s.put(monthAwardsKind, gala.month, { ...gala, placements: gala.placements.filter(o => o.personId !== personId) });
  }
}
