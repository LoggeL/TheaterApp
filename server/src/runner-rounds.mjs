import { randomUUID } from 'node:crypto';
import { AppError } from './theater.mjs';

// The runs of the stage runner per person (store kind `runnerRounds`).
//
// - Several runs may be open at once: "Nochmal" starts the next run while the result of the last
//   one is still on its way (or waits for a retry). A new start therefore never closes an open run.
// - The measured time of a run ends at the latest when the person's next run starts (`until`):
//   whoever plays one run at a time loses nothing, while parallel open runs cannot multiply the
//   plausible points and metres (the credited times never overlap).
// - The starts reach the server in any order: the request of a run may stall and arrive after the
//   one of the run the app started next. Apps therefore name the order of their starts (`order`:
//   `{ client, seq }`, a random name per app session and a growing number). A start never ends the
//   time of a run the same app session started after it; having been overtaken, its own time ends
//   where it starts (that run was over before the next one began). Starts without `order` and those
//   of other app sessions end each other's time as they arrive.
// - A finished run keeps its result for a while: the same result sent again (a retry whose answer
//   got lost) gets that answer back and counts no second time; a different result is rejected.
// - Older records (`{ roundId, startedAt, starts }`, one open run) are read as one open run.
// - A run of the Wochenprobe (runner-weekly.mjs) carries `weekly: { week, ranked, attempt }` from its
//   start on, so its result cannot change the mode or the week.
export const runnerRounds = Object.freeze({ open: 20, finished: 10 });

const fail = (status, message, code) => { throw new AppError(status, message, code); };
const list = value => Array.isArray(value) ? value : [];

function load(t, personId) {
  const r = t.store.get('runnerRounds', personId), open = list(r?.open);
  if (typeof r?.roundId === 'string' && r.roundId && r.startedAt && !open.some(x => x.roundId === r.roundId)) open.push({ roundId: r.roundId, startedAt: r.startedAt });
  return { starts: list(r?.starts), open, finished: list(r?.finished) };
}
/** The `order` of a start as the app sends it (`{ client, seq }`); null if missing or malformed. */
export const roundOrder = o => typeof o?.client === 'string' && o.client.length >= 1 && o.client.length <= 64 && Number.isSafeInteger(o.seq) && o.seq >= 0
  ? { client: o.client, seq: o.seq } : null;

const save = (t, personId, r) => t.store.put('runnerRounds', personId, { personId, starts: r.starts, open: r.open, finished: r.finished });

/**
 * Opens a run at [at] (inside runnerStart's transaction); `startBurst` starts per `startWindowMs` at
 * most. Open runs beyond `roundTtlMs` are dropped, the others end their measured time here, except
 * those the same app session started after this one ([order], see `roundOrder`). [extra] is kept
 * with the run (the Wochenprobe's `weekly`).
 */
export function startRound(t, personId, at, { startBurst, startWindowMs, roundTtlMs }, extra = {}, order = null) {
  const r = load(t, personId), now = +at, since = now - startWindowMs;
  const starts = r.starts.filter(x => Date.parse(x) > since).slice(-startBurst);
  if (starts.length >= startBurst) fail(429, 'Das waren gerade sehr viele Starts auf einmal. Bitte einen Moment warten.', 'rate_limited');
  const startedAt = at.toISOString(), live = r.open.filter(x => now - Date.parse(x.startedAt) <= roundTtlMs);
  // Runs of this app session that it started after this one: their start got here first.
  const later = x => order !== null && x.client === order.client && x.seq > order.seq;
  const round = { roundId: randomUUID(), startedAt, ...extra, ...(order ?? {}), ...(live.some(later) ? { until: startedAt } : {}) };
  const open = live.map(x => x.until || later(x) ? x : { ...x, until: startedAt });
  save(t, personId, { starts: [...starts, startedAt], open: [...open, round].slice(-runnerRounds.open), finished: r.finished });
  return round;
}

/**
 * The run [roundId] a result is sent for: `{ repeat }` with the stored answer when exactly this
 * result was already counted, else `{ round, elapsed }` with the measured time in ms.
 */
export function findRound(t, personId, roundId, b, at, { roundTtlMs }) {
  const r = load(t, personId), unknown = () => fail(409, 'Dieser Lauf ist nicht bekannt.', 'round_unknown');
  if (typeof roundId !== 'string' || !roundId) unknown();
  const done = r.finished.find(x => x.roundId === roundId);
  if (done) return done.score === b.score && done.meters === (b.meters ?? null) ? { repeat: done.result } : unknown();
  const round = r.open.find(x => x.roundId === roundId) ?? unknown();
  if (at - Date.parse(round.startedAt) > roundTtlMs) fail(409, 'Der Lauf ist abgelaufen.', 'round_expired');
  return { round, elapsed: Math.min(at, round.until ? Date.parse(round.until) : at) - Date.parse(round.startedAt) };
}

/** Closes the run [roundId] with its counted result [result], so a repeat gets the same answer. */
export function finishRound(t, personId, roundId, b, result) {
  const r = load(t, personId);
  save(t, personId, {
    starts: r.starts, open: r.open.filter(x => x.roundId !== roundId),
    finished: [...r.finished, { roundId, score: b.score, meters: b.meters ?? null, result }].slice(-runnerRounds.finished),
  });
}
