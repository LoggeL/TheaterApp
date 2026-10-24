import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures } from '../src/theater.mjs';
import { crateGap, crateMilestone, cratePoints, cratePointsModel, cratesEarned, legacyCrateMeters, legacyCrateMilestone, legacyCratesEarned, loadCatalog, migrateToCratePoints } from '../src/runner-wardrobe.mjs';

// Crate points (`runnerCratePoints`): the own crates count points instead of metres. Records from
// before move over once, on their first use, and nobody loses a crate or the way to the next one.

const rarities = [{ id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 60, gage: 10 }];
const items = [
  { id: 'c0', kind: 'character', name: 'Engel Logge', rarity: 'hell', default: true },
  { id: 'b0', kind: 'backdrop', name: 'Wand', rarity: 'hell', default: true },
  { id: 'o0', kind: 'obstacles', name: 'Lager', rarity: 'hell', default: true },
  { id: 'f0', kind: 'fx', name: 'Ohne', rarity: 'hell', default: true },
  ...Array.from({ length: 6 }, (_, i) => ({ id: `h${i}`, kind: 'character', name: `Hell ${i}`, rarity: 'hell' })),
];
const at = new Date('2026-10-24T10:00:00Z');

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const clock = { now: at };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.now, runnerCatalog: loadCatalog({ rarities, items }), random: () => 0.5, missionRules: null });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  const personId = app.action('admin', { action: 'member.save', name: 'Sam Beispiel' }, 'p1').id;
  app.session({ uid: 'sam', name: 'Sam', email: 'sam@example.invalid', email_verified: true });
  app.action('admin', { action: 'account.approve', uid: 'sam', personId, version: 1, role: 'member' }, 'p2');
  /** Sam's record as it was before crate points (role figures already moved). */
  const old = record => store.put('runnerProgress', personId, { personId, meters: 0, creditedMeters: 0, creditedRounds: 0, opened: 0, owned: [], selected: {}, deaths: {}, createdAt: '2026-05-01T10:00:00.000Z', ...record });
  const play = (score, meters) => { const { roundId } = app.runnerStart('sam'); clock.now = new Date(+clock.now + 600000); return app.runnerScore('sam', { roundId, score, meters }).progress; };
  return { store, app, personId, old, play, saved: () => store.get('runnerProgress', personId) };
}

/** Crates earned and the share of the way to the next one, on the old and the new curve. */
const oldState = m => { const n = legacyCratesEarned(m); return { n, share: (m - legacyCrateMilestone(n)) / (legacyCrateMilestone(n + 1) - legacyCrateMilestone(n)) }; };
const newState = p => { const n = cratesEarned(p); return { n, share: (p - crateMilestone(n)) / crateGap(n + 1) }; };

test('servers announce crate points and crate targets', t => {
  const { app } = setup(t);
  for (const f of ['runnerCratePoints', 'runnerCrateTargets']) {
    assert.ok(apiFeatures.includes(f));
    assert.ok(app.snapshot('sam').capabilities.features.includes(f));
  }
});

test('the move keeps every crate and the share of the way to the next one, for any old distance', () => {
  for (let m = 0; m <= 400000; m += 137) {
    const p = migrateToCratePoints({ meters: m, opened: 0 }, at), before = oldState(m), after = newState(cratePoints(p));
    // Never fewer crates; one more only if the old way was a hair from the next crate.
    assert.ok(after.n === before.n || (after.n === before.n + 1 && before.share > 0.999), `${m} m`);
    if (after.n === before.n) {
      assert.ok(after.share >= before.share, `${m} m: ${after.share} < ${before.share}`);
      // Rounded up by less than a point.
      assert.ok((after.share - before.share) * crateGap(after.n + 1) < 1, `${m} m`);
    }
  }
});

test('realistic old records: metres, Tagesbonus and missions all count, opened crates stay', t => {
  const cases = [
    // A newcomer from before: 3 runs, no crate yet.
    { meters: 1350 },
    // Exactly on a milestone: 7 crates, nothing on the way.
    { meters: legacyCrateMilestone(7) - 900 - 450, bonusMeters: 900, missionMeters: 450, opened: 7 },
    // A regular: 48 km run, 3,1 km Tagesbonus, 5,4 km missions, 15 crates opened, 4 waiting.
    { meters: 48250, bonusMeters: 3100, missionMeters: 5400, opened: 15, owned: ['h1', 'h2'], gage: 120 },
    // A grinder: 412 km, credit for 80 earlier runs included.
    { meters: 412000, creditedMeters: 12000, creditedRounds: 80, bonusMeters: 21000, missionMeters: 38000, opened: 70 },
  ];
  for (const record of cases) {
    const { app, old, saved } = setup(t);
    old(record);
    const before = oldState(legacyCrateMeters(record)), waitingBefore = before.n - (record.opened ?? 0);
    const w = app.runnerWardrobe('sam');
    const p = saved(), after = newState(cratePoints(p));
    assert.equal(p.crateModel, cratePointsModel);
    assert.equal(w.progress.earned, before.n, JSON.stringify(record));
    assert.equal(w.progress.crates, waitingBefore);
    assert.equal(w.progress.opened, record.opened ?? 0);
    assert.ok(after.share >= before.share);
    // The bar stands where it stood (in the app: (meters − previousAt) / (nextAt − previousAt)).
    const fraction = (w.progress.meters - w.progress.previousAt) / (w.progress.nextAt - w.progress.previousAt);
    assert.ok(Math.abs(fraction - before.share) < 0.001, `${fraction} vs ${before.share}`);
    // Nothing else changes: metres, statistics, owned items, gage.
    assert.deepEqual([p.meters, p.bonusMeters, p.missionMeters, p.owned, p.gage], [record.meters, record.bonusMeters, record.missionMeters, record.owned ?? [], record.gage]);
    assert.equal(w.stats.meters, record.meters);
    assert.deepEqual(p.crateMetersBefore, { meters: legacyCrateMeters(record), earned: before.n, share: Math.round(before.share * 1000) / 1000 });
    assert.deepEqual(w.progress.points, { total: p.basePoints, base: p.basePoints, runs: 0, bonus: 0, missions: 0 });
  }
});

test('an example: 56.750 crate metres become 19 crates and 42 % of the way on the point curve', t => {
  const { app, old } = setup(t);
  old({ meters: 48250, bonusMeters: 3100, missionMeters: 5400, opened: 15 });
  // 56.750 m: crate 19 at 55.100 m, crate 20 at 59.000 m, so 1.650 of 3.900 m (42,3 %).
  assert.deepEqual([legacyCratesEarned(56750), legacyCrateMilestone(19), legacyCrateMilestone(20)], [19, 55100, 59000]);
  const w = app.runnerWardrobe('sam');
  // On the point curve crate 19 is at 72.830 points and crate 20 is 4.310 further: 42,3 % of them, rounded up.
  assert.deepEqual([crateMilestone(19), crateGap(20)], [72830, 4310]);
  assert.equal(w.progress.points.base, 72830 + Math.ceil(1650 * 4310 / 3900));
  assert.equal(w.progress.points.base, 74654);
  assert.deepEqual([w.progress.earned, w.progress.crates, w.progress.previousAt, w.progress.nextAt], [19, 4, 72830, 77140]);
});

test('the move runs once: reading again, opening and running never move it again', t => {
  const { app, old, saved, play } = setup(t);
  old({ meters: 20000, bonusMeters: 1000, opened: 2 });
  app.runnerWardrobe('sam');
  const first = saved();
  app.runnerWardrobe('sam');
  assert.deepEqual(saved(), first);
  assert.equal(migrateToCratePoints(first, at), null);
  app.runnerOpenCrate('sam', 'once-1', { dupes: true });
  const run = play(900, 600);
  const p = saved();
  assert.equal(p.basePoints, first.basePoints);
  assert.equal(p.cratePointsAt, first.cratePointsAt);
  // The metres keep counting for the statistics; the crates now count the run's points.
  assert.deepEqual([p.meters, p.bonusMeters, p.points, p.bonusPoints], [20600, 1000, 900, 900]);
  assert.equal(run.meters, first.basePoints + 1800);
  assert.equal(p.opened, 3);
});

test('a record from before role figures moves over to both at once', t => {
  const { app, old, saved } = setup(t);
  old({ meters: 9000, opened: 1, model: undefined, variants: [] });
  assert.equal(app.runnerWardrobe('sam').progress.earned, legacyCratesEarned(9000));
  assert.equal(saved().crateModel, cratePointsModel);
});

test('a first record credits earlier runs as metres, moved over like an old one', t => {
  const { app, store, personId } = setup(t);
  store.put('runnerScores', personId, { personId, best: 900, bestAt: null, rounds: 20, lastPlayedAt: null });
  const w = app.runnerWardrobe('sam');
  // 20 · 150 m = 3000 m: one crate (2000 m) and half of the 2100 m to the second.
  assert.equal(w.progress.earned, 1);
  assert.equal(w.progress.points.base, 3000 + Math.ceil(1000 * 3300 / 2100));
  assert.equal(w.stats.creditedMeters, 3000);
});
