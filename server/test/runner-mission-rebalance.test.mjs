import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { missionSlots } from '../src/runner-missions.mjs';
import { logMissionsMade } from '../src/runner-mission-log.mjs';

function setup(t, missions, extra = {}) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => new Date('2026-11-10T09:00:00Z') });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  const personId = app.account('admin').personId;
  store.put('runnerMissions', personId, { personId, day: '2026-11-10', best: { m: 2000, s: 3000, noPickup: 500 }, runs: 50, todayMeters: 500, rerolled: true, crate: false,
    missions: missions.map((m, i) => ({ slot: missionSlots[i], reward: 10, unit: 'points', progress: 0, done: false, id: `keep-${i}`, ...m })), ...extra });
  logMissionsMade(app, store.get('runnerMissions', personId), {});
  return { app, store, personId };
}

test('an explicit per-mission admin override survives balancing, without changing other players or future policy', t => {
  const { app, store, personId } = setup(t, [
    { type: 'distance', target: 575, progress: 575, done: true, doneAt: '2026-11-10T08:00:00Z' },
    { type: 'runs', target: 2, min: 350, progress: 1, targetOverride: { source: 'admin', day: '2026-11-10', target: 2, min: 350 } },
    { type: 'noPickup', target: 210, progress: 3 },
  ]);
  const original = store.get('runnerMissions', personId);
  const view = app.runnerMissions('admin');
  assert.equal(view.missions[1].min, 350);
  assert.equal(view.missions[1].target, 2);
  assert.equal(view.missions[1].progress, 1);
  assert.deepEqual(store.get('runnerMissions', personId).missions[0], original.missions[0]);
  assert.equal(view.missions[2].target, 20);
});

test('current legacy missions lower in place and award already-earned progress exactly once on fetch', t => {
  const { app, store, personId } = setup(t, [
    { type: 'distance', target: 575, progress: 120 },
    { type: 'runs', target: 3, min: 625, progress: 2 },
    { type: 'noPickup', target: 210, progress: 25 },
  ]);
  const view = app.runnerMissions('admin');
  assert.deepEqual(view.missions.map(m => m.target), [100, 2, 20]);
  assert.ok(view.allDone && view.crate.earned);
  const rec = store.get('runnerMissions', personId);
  assert.deepEqual(rec.missions.map(m => m.progress), [120, 2, 25]);
  assert.deepEqual(rec.missions.map(m => m.id), ['keep-0', 'keep-1', 'keep-2']);
  assert.equal(rec.missions[1].min, 80);
  assert.equal(rec.rerolled, true);
  const p = store.get('runnerProgress', personId);
  assert.equal(p.missionPoints, 30);
  assert.equal(p.missionCrates, 1);
  app.runnerMissions('admin');
  assert.deepEqual(store.get('runnerProgress', personId), p);
  assert.deepEqual(store.get('runnerMissions', personId), rec);
  const rows = store.db.prepare('SELECT * FROM runner_mission_log ORDER BY id').all();
  assert.deepEqual(rows.map(r => [r.target, r.done, r.runs, r.runs_to_done]), [[100, 1, 0, null], [2, 1, 0, null], [20, 1, 0, null]]);
  assert.ok(rows.every(r => JSON.parse(r.data).completionSource === 'effortRebalance'));
  assert.ok(rows.every(r => JSON.parse(r.data).crateRuns === undefined));
});

test('existing rare specialties get conservative same-kind fallback goals, unsupported legacy types are reported', t => {
  const { app, store, personId } = setup(t, [
    { type: 'collect', kind: 'star', target: 20 },
    { type: 'ceiling', target: 500 },
    { type: 'debut', kind: 'drop', target: 1000 },
  ], { best: { m: 100, s: 100, star: 0, ceiling: 0 } });
  const view = app.runnerMissions('admin');
  assert.deepEqual(view.missions.map(m => m.target), [1, 20, 1000]);
  assert.equal(store.get('runnerMissions', personId).effortRebalance.changes[2].reason, 'unsupported-or-ineligible');
});

test('a series preserves qualifying counts and never invents previous lower-threshold successes', t => {
  const { app, store, personId } = setup(t, [{ type: 'runs', target: 3, min: 625, progress: 1 }]);
  const view = app.runnerMissions('admin');
  assert.deepEqual([view.missions[0].target, view.missions[0].min, view.missions[0].progress, view.missions[0].done], [2, 60, 1, false]);
  assert.equal(store.get('runnerProgress', personId), null);
});

test('already easier targets, completed missions, claimed crates and other people stay intact', t => {
  const { app, store, personId } = setup(t, [
    { type: 'distance', target: 30, progress: 10 },
    { type: 'runs', target: 1, min: 25, progress: 0 },
    { type: 'ceiling', target: 500, progress: 501, done: true, doneAt: '2026-11-10T07:00:00Z' },
  ], { crate: true });
  const old = store.get('runnerMissions', personId);
  store.put('runnerMissions', 'other', { personId: 'other', ...old });
  const other = store.get('runnerMissions', 'other');
  app.runnerMissions('admin');
  const rec = store.get('runnerMissions', personId);
  assert.deepEqual(rec.missions, old.missions);
  assert.equal(rec.crate, true);
  assert.deepEqual(store.get('runnerMissions', 'other'), other);
  assert.equal(store.get('runnerProgress', personId), null);
});

test('past-day history is not rewritten or paid while a new day gets the normal policy', t => {
  const { app, store, personId } = setup(t, [{ type: 'distance', target: 575, progress: 500 }], { day: '2026-11-09' });
  const history = store.db.prepare('SELECT * FROM runner_mission_log ORDER BY id').all();
  app.runnerMissions('admin');
  assert.deepEqual(store.db.prepare("SELECT * FROM runner_mission_log WHERE day='2026-11-09' ORDER BY id").all(), history);
  assert.equal(store.get('runnerProgress', personId), null);
  assert.equal(store.get('runnerMissions', personId).day, '2026-11-10');
});

test('a legacy reroll uses the newly frozen recent basis and preserves used-reroll protection', t => {
  const recent = Array.from({ length: 5 }, () => ({ at: '2026-11-10T08:00:00Z', m: 80, s: 80 }));
  const { app, store, personId } = setup(t, [
    { type: 'distance', target: 575 }, { type: 'runs', target: 3, min: 625 }, { type: 'noPickup', target: 210 },
  ], { rerolled: false, recent, effortBasis: { best: { m: 9000, s: 9000 }, runs: 100, recent: [] } });
  const rerolled = app.runnerMissionReroll('admin', 'rebalance-reroll', { slot: 'hard' });
  assert.equal(rerolled.rerollAvailable, false);
  const rec = store.get('runnerMissions', personId);
  assert.deepEqual(rec.effortBasis.recent, recent);
  assert.equal(rec.effortBasis.best.m, 2000);
  assert.equal(rec.missions[2].type, 'points');
  assert.equal(rec.missions[2].target, 80);
  assert.deepEqual(app.runnerMissionReroll('admin', 'rebalance-reroll', { slot: 'hard' }), rerolled);
});

test('balancing on a score submission preserves its award and retries cannot duplicate it', t => {
  const { app, store, personId } = setup(t, [
    { type: 'distance', target: 575, progress: 120 },
    { type: 'runs', target: 3, min: 625, progress: 2 },
    { type: 'noPickup', target: 210, progress: 25 },
  ]);
  const { roundId } = app.runnerStart('admin');
  const body = { roundId, score: 0, meters: 0 };
  app.runnerScore('admin', body);
  const p = store.get('runnerProgress', personId);
  assert.equal(p.missionPoints, 30);
  assert.equal(p.missionCrates, 1);
  app.runnerScore('admin', body);
  assert.deepEqual(store.get('runnerProgress', personId), p);
});
