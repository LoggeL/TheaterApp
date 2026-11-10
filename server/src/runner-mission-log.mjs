// History of the stage runner's Tagesmissionen (runner-missions.mjs) for balancing: one row per
// mission per person and Berlin day in the `runner_mission_log` table (see store.mjs), written as
// the day goes on, so a day is complete even if the person never plays again (unfinished = not
// done). Nothing of it is shown in the app; scripts/mission-report.mjs reads it as aggregates.
//
// - Made (`logMissionsMade`): slot, type, target, reward, whether the app sends statistics and how
//   the target came about (the relevant best per run, the share of it and whether the start value,
//   a limit or the share decided), so target / best can be compared across types and slots.
// - Each run (`logMissionRun`): runs with the mission, the run that completed it and the minutes
//   from the day's first run until then, the progress, the Missionskiste on all of the day's rows.
// - Reroll (`logMissionReroll`): the old row gets `rerolled_to`, the new one `rerolled_from`.
// - A failure here never breaks the game: it is logged and the run or request goes on.

import { missionEffort } from './runner-mission-effort.mjs';

export const missionLog = Object.freeze({ retentionDays: 180 });

const slots = ['easy', 'medium', 'hard'];
const list = value => Array.isArray(value) ? value : [];
const num = v => typeof v === 'number' && Number.isFinite(v) ? v : null;
const flag = v => v ? 1 : 0;
const guard = (name, fn) => { try { fn(); } catch (e) { console.error(`runner-mission-log ${name}:`, e?.message ?? e); } };

/**
 * How the target of [m] came about from the bests in [ctx] (`missionOptions` in
 * runner-missions.mjs): `best` the person's relevant best per run, `share` the share of it, `value`
 * the measured figure (the minimum metres for `runs`), `source`: `start` (no best yet or the start
 * value as floor with few runs), `min`/`max` (a limit), `share`, `band` (`reach`, an obstacle's metres).
 */
export function missionDerivation(m, ctx) {
  const r = ctx?.rules, d = r?.types?.[m.type];
  if (!d) return {};
  const best = ctx.best ?? {}, i = slots.indexOf(m.slot), few = (ctx.runs ?? 0) < r.minRuns;
  const value = m.type === 'runs' ? m.min : m.target;
  let basis, share = d.share?.[m.slot], start = Array.isArray(d.start) ? d.start[i] : undefined, min = d.min, max = d.max;
  switch (m.type) {
    case 'distance': basis = best.m; break;
    case 'points': basis = best.s; break;
    case 'ground': case 'ceiling': basis = best[m.type]; break;
    case 'collect': basis = best[m.kind]; start = d.kinds?.[m.kind]?.start?.[i]; min = d.kinds?.[m.kind]?.min; break;
    case 'pass': basis = best.passed?.[m.kind]; start = d.start?.[m.kind]?.[i]; break;
    case 'noPickup': basis = best.noPickup; break;
    case 'dailyDistance': basis = best.m; share = d.ofBest; start = d.start?.[0]; break;
    case 'runs': basis = best.m; break;
    // `reach` (runner-missions.mjs): the obstacle's metres against the distance share of the slot.
    case 'reach': basis = best.m; share = r.types.distance?.share?.[m.slot]; break;
    default: break;
  }
  const adaptive = (ctx.recent?.length ?? 0) >= missionEffort.minSamples;
  const raw = !adaptive && basis > 0 && share > 0 ? basis * share : null;
  const source = adaptive ? 'recentQuantile' : m.type === 'reach' ? 'band' : !(basis > 0) ? 'start' : start !== undefined && raw > start ? 'coldCap'
    : raw !== null && min !== undefined && raw < min ? 'min' : raw !== null && max !== undefined && raw > max ? 'max' : 'share';
  return {
    best: num(basis), share: adaptive ? null : num(share), raw: raw === null ? null : Math.round(raw * 10) / 10, value: num(value),
    ratio: basis > 0 && num(value) !== null ? Math.round(value / basis * 1000) / 1000 : null,
    source, few, countedRuns: ctx.runs ?? 0, ...(start !== undefined ? { start } : {}),
    // The two bests every type relates to, for comparisons the report does not make yet.
    bests: { m: num(best.m), s: num(best.s) },
    effort: { version: missionEffort.version, completionRuns: missionEffort.completionRuns,
      samples: ctx.recent?.length ?? 0, ...(adaptive ? { quantile: missionEffort.quantile[m.type === 'runs' || m.type === 'dailyDistance' ? 'easy' : m.slot] } : {}) },
  };
}

const insert = (db, row) => db.prepare(`INSERT INTO runner_mission_log(day, person_id, slot, type, kind, target, reward, best, client_stats, rerolled, rerolled_from, rerolled_to, done, runs, runs_to_done, progress, minutes_to_done, crate, created_at, updated_at, data)
  VALUES (?,?,?,?,?,?,?,?,?,?,?,NULL,0,0,NULL,?,NULL,0,?,?,?)
  ON CONFLICT(person_id, day, slot, rerolled) DO NOTHING`)
  .run(row.day, row.personId, row.m.slot, row.m.type, row.m.kind ?? null, row.m.target, row.m.reward ?? 0, row.derivation.best ?? null, flag(row.stats), flag(row.m.rerolled),
    row.from ?? null, row.m.progress ?? 0, row.at, row.at, JSON.stringify({ ...(row.m.min !== undefined ? { min: row.m.min } : {}), unit: row.m.unit ?? null, derivation: row.derivation, ...row.extra }));

/** The new day's missions in [rec] (just made by `missionsToday`); [ctx]: the context they were made with. */
export function logMissionsMade(t, rec, ctx) {
  guard('made', () => {
    const at = t.clock().toISOString();
    for (const m of list(rec.missions)) insert(t.store.db, { day: rec.day, personId: rec.personId, m, stats: rec.stats, derivation: missionDerivation(m, ctx), at });
  });
  return rec;
}

const rowOf = (db, personId, day, m) => db.prepare('SELECT id, runs, done, data FROM runner_mission_log WHERE person_id=? AND day=? AND slot=? AND rerolled=? AND type=?')
  .get(personId, day, m.slot, flag(m.rerolled), m.type);

/**
 * A run counted by `recordMissionRun`: [before] the day's record before the run, [after] after it,
 * [run] `{ meters, at, ... }`.
 */
export function logMissionRun(t, before, after, run) {
  guard('run', () => {
    const db = t.store.db, at = run.at.toISOString(), personId = after.personId ?? before.personId, day = after.day;
    const firstRunAt = db.prepare("SELECT MIN(json_extract(data,'$.firstRunAt')) AS at FROM runner_mission_log WHERE person_id=? AND day=?").get(personId, day)?.at ?? at;
    const was = new Map(list(before.missions).map(m => [m.slot, m]));
    for (const m of list(after.missions)) {
      const row = rowOf(db, personId, day, m);
      if (!row) continue;
      const data = JSON.parse(row.data), justDone = m.done && !was.get(m.slot)?.done && !row.done;
      const runs = row.done ? row.runs : row.runs + 1;
      const next = { ...data, firstRunAt: data.firstRunAt ?? firstRunAt, dayRuns: (data.dayRuns ?? 0) + 1, ...(justDone ? { doneAt: m.doneAt ?? at } : {}) };
      const minutes = justDone ? Math.round((Date.parse(next.doneAt) - Date.parse(firstRunAt)) / 600) / 100 : null;
      db.prepare(`UPDATE runner_mission_log SET runs=?, progress=?, updated_at=?, data=?${justDone ? ', done=1, runs_to_done=?, minutes_to_done=?' : ''} WHERE id=?`)
        .run(runs, m.progress ?? 0, at, JSON.stringify(next), ...(justDone ? [runs, minutes] : []), row.id);
    }
    if (after.crate && !before.crate) {
      // Capture the absolute day-run count at the crate, not total runs played afterwards or
      // runs since a reroll. Unrerolled slots keep dayRuns throughout the day, including after done.
      const crateRuns = db.prepare("SELECT MAX(json_extract(data,'$.dayRuns')) AS n FROM runner_mission_log WHERE person_id=? AND day=?").get(personId, day)?.n;
      db.prepare("UPDATE runner_mission_log SET crate=1, updated_at=?, data=json_set(data,'$.crateRuns',?) WHERE person_id=? AND day=?").run(at, crateRuns, personId, day);
    }
  });
}

/** Balance is not a played run: preserve run counters and label the observed award separately. */
export function logMissionRebalance(t, before, after, instant) {
  guard('rebalance', () => {
    const db = t.store.db, at = instant.toISOString();
    for (const m of list(after.missions)) {
      const old = list(before.missions).find(x => x.slot === m.slot);
      if (old?.done) continue;
      const row = rowOf(db, after.personId, after.day, m);
      if (!row) continue;
      const data = JSON.parse(row.data);
      const balance = after.effortRebalance.changes.find(x => x.slot === m.slot);
      db.prepare('UPDATE runner_mission_log SET target=?, progress=?, done=?, updated_at=?, data=? WHERE id=?')
        .run(m.target, m.progress, flag(m.done), at, JSON.stringify({ ...data, ...(m.min !== undefined ? { min: m.min } : {}),
          effortRebalance: { ...balance, version: missionEffort.version, at }, ...(m.done ? { doneAt: at, completionSource: 'effortRebalance' } : {}) }), row.id);
    }
    if (after.crate && !before.crate) {
      // No fabricated historical time-to-crate: award happened on normalization, not on an old run.
      db.prepare("UPDATE runner_mission_log SET crate=1, updated_at=?, data=json_set(data,'$.crateCompletionSource','effortRebalance','$.crateAwardedAt',?) WHERE person_id=? AND day=?")
        .run(at, at, after.personId, after.day);
    }
  });
}

/** A reroll in [rec] (the day's record before it) of [old] to [fresh] (with `rerolled`); [ctx] as made. */
export function logMissionReroll(t, rec, old, fresh, ctx) {
  guard('reroll', () => {
    const db = t.store.db, at = t.clock().toISOString(), row = rowOf(db, rec.personId, rec.day, old);
    if (row) {
      const data = JSON.parse(row.data);
      db.prepare('UPDATE runner_mission_log SET rerolled_to=?, progress=?, updated_at=?, data=? WHERE id=?').run(fresh.type, old.progress ?? 0, at, JSON.stringify({ ...data, rerolledAt: at }), row.id);
    }
    const firstRunAt = db.prepare("SELECT MIN(json_extract(data,'$.firstRunAt')) AS at FROM runner_mission_log WHERE person_id=? AND day=?").get(rec.personId, rec.day)?.at;
    insert(db, { day: rec.day, personId: rec.personId, m: fresh, stats: rec.stats, derivation: missionDerivation(fresh, ctx), at, from: old.type, extra: { rerolledAt: at, ...(firstRunAt ? { firstRunAt } : {}) } });
  });
}

/** Deletes the rows of [personId] (account deletion). */
export function forgetMissionLog(store, personId) {
  return Number(store.db.prepare('DELETE FROM runner_mission_log WHERE person_id=?').run(personId).changes);
}

/** Deletes the rows of days before [firstKeptDay] (`YYYY-MM-DD`). */
export function purgeMissionLog(store, firstKeptDay) {
  return Number(store.db.prepare('DELETE FROM runner_mission_log WHERE day < ?').run(firstKeptDay).changes);
}
