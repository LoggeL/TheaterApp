import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, stageRunner } from '../src/theater.mjs';
import { cratesEarned, loadCatalog } from '../src/runner-wardrobe.mjs';

// "Grind ist gut": nothing limits how often someone plays. Every run counts in full, however many
// came before it on the same day, for the crates, the statistics and the Ensemble-Strecke.

const rarities = [
  { id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 60, gage: 10 },
  { id: 'gold', name: 'Gold', color: '#E4AE39', weight: 10, gage: 200, buyable: false },
];
const items = [
  { id: 'c0', kind: 'character', name: 'Engel Logge', rarity: 'hell', default: true },
  { id: 'b0', kind: 'backdrop', name: 'Wand', rarity: 'hell', default: true },
  { id: 'o0', kind: 'obstacles', name: 'Lager', rarity: 'hell', default: true },
  { id: 'f0', kind: 'fx', name: 'Ohne', rarity: 'hell', default: true },
  ...Array.from({ length: 8 }, (_, i) => ({ id: `h${i}`, kind: 'character', name: `Hell ${i}`, rarity: 'hell' })),
  { id: 'g1', kind: 'character', name: 'Gold 1', rarity: 'gold' },
];
const ensemble = { every: 10, milestones: [{ km: 1 }, { km: 2 }, { km: 5 }] };

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const clock = { now: new Date('2026-10-24T08:00:00Z') };
  const tick = ms => { clock.now = new Date(+clock.now + ms); };
  // Tagesmissionen stay on (the default rules): they come on top and must not take anything away.
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.now, runnerCatalog: loadCatalog({ rarities, items, ensemble }), random: () => 0.5 });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let n = 0;
  const action = body => app.action('admin', body, `g-${++n}`);
  const personId = action({ action: 'member.save', name: 'Sam Beispiel' }).id;
  app.session({ uid: 'sam', name: 'Sam', email: 'sam@example.invalid', email_verified: true });
  action({ action: 'account.approve', uid: 'sam', personId, version: 1, role: 'member' });
  return { store, app, personId, tick };
}

test('100 runs in a row all count in full: crate metres, statistics and the Ensemble-Strecke', t => {
  const { store, app, personId, tick } = setup(t);
  const runs = 100, meters = 400, runMs = 50000;
  const replies = [];
  // A real session: a 400 m run takes about 47 s, then 1 s curtain and "Nochmal". Every other
  // time the next run starts before the last result has arrived.
  let round = app.runnerStart('sam').roundId;
  for (let i = 0; i < runs; i++) {
    tick(runMs);
    const body = { roundId: round, score: meters, meters, hitBy: 'crate' };
    if (i % 2 === 0 && i < runs - 1) {
      round = app.runnerStart('sam').roundId;
      replies.push(app.runnerScore('sam', body));
    } else {
      replies.push(app.runnerScore('sam', body));
      if (i < runs - 1) { tick(1000); round = app.runnerStart('sam').roundId; }
    }
  }
  // No diminishing returns: the 100th run brings as much as the first, for the own metres and the ensemble.
  assert.deepEqual(replies.map(r => r.progress.gained), Array(runs).fill(meters));
  assert.deepEqual(replies.map(r => r.progress.ensemble.gained), Array(runs).fill(meters));
  // The Tagesbonus only adds, on the first run of the day.
  assert.deepEqual(replies.map(r => r.progress.bonus), [meters, ...Array(runs - 1).fill(0)]);

  const w = app.runnerWardrobe('sam'), real = runs * meters;
  assert.equal(store.get('runnerScores', personId).rounds, runs);
  assert.equal(w.stats.rounds, runs);
  assert.equal(w.stats.meters, real);
  assert.deepEqual(w.stats.deaths, [{ kind: 'crate', count: runs }]);
  assert.equal(w.stats.untracked, 0);
  assert.equal(w.progress.runMeters, real);
  // Kistenstrecke: every real metre plus the bonuses, nothing capped.
  assert.equal(w.progress.meters, real + meters + w.progress.missionMeters);
  assert.equal(w.progress.earned, cratesEarned(real + meters + w.progress.missionMeters));
  assert.ok(w.progress.earned >= cratesEarned(real));
  // The ensemble got every metre: 40 km reach 1, 2, 5, 15, 25 and 35 km, each with its crate.
  assert.equal(w.ensemble.meters, real);
  assert.equal(w.ensemble.crates, 6);
  assert.equal(w.ensemble.previousKm, 35);
  // The own share of the current section: all runs after the one that crossed 35 km.
  assert.equal(w.ensemble.section.own, (runs - Math.ceil(35000 / meters)) * meters);

  // All crates open one after the other on the same day, without any waiting.
  let key = 0;
  const openAll = crate => {
    let opened = 0;
    for (;;) {
      const p = app.runnerWardrobe('sam').progress;
      const waiting = crate === 'ensemble' ? p.ensembleCrates : crate === 'mission' ? p.missionCrates : p.crates;
      if (!waiting) return opened;
      app.runnerOpenCrate('sam', `grind-${++key}`, { dupes: true, ...(crate ? { crate } : {}) });
      opened++;
    }
  };
  assert.equal(openAll(), w.progress.earned);
  assert.equal(openAll('ensemble'), 6);
  openAll('mission');
  const after = app.runnerWardrobe('sam').progress;
  assert.deepEqual([after.crates, after.ensembleCrates, after.missionCrates], [0, 0, 0]);
  assert.equal(after.opened, w.progress.earned);
});

test('the spam guard leaves room for far more starts than a person can make', t => {
  const { app, tick } = setup(t);
  // The quickest crash comes after 2.6 s (see the app's test), plus 1 s curtain and a tap: even
  // runs of 3.5 s for ten minutes on end are never refused.
  for (let i = 0; i < 170; i++) {
    const { roundId } = app.runnerStart('sam'); tick(3500);
    app.runnerScore('sam', { roundId, score: 0, meters: 0 });
  }
  // Even three devices at once, each restarting every 3.5 s, stay below the guard.
  for (let i = 0; i < 3 * Math.ceil(stageRunner.startWindowMs / 3500); i++) app.runnerStart('sam');
  assert.ok(app.runnerStart('sam').roundId);
});
