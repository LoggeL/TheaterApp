import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures, runnerMaxMeters, stageRunner } from '../src/theater.mjs';
import { loadCatalog, runnerUnlocks } from '../src/runner-wardrobe.mjs';

// Tagesbonus: the first counted run of a Berlin calendar day counts twice for the crates (its points again).
const rarities = [{ id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 60, gage: 10 }];
const items = [
  { id: 'c0', kind: 'character', name: 'Engel Logge', rarity: 'hell', default: true },
  { id: 'b0', kind: 'backdrop', name: 'Wand', rarity: 'hell', default: true },
  { id: 'o0', kind: 'obstacles', name: 'Lager', rarity: 'hell', default: true },
  { id: 'f0', kind: 'fx', name: 'Ohne', rarity: 'hell', default: true },
  { id: 'h1', kind: 'character', name: 'Hell 1', rarity: 'hell' },
  { id: 'h2', kind: 'character', name: 'Hell 2', rarity: 'hell' },
];
const catalog = loadCatalog({ rarities, items, ensemble: { every: 10, milestones: [{ km: 5 }] } });

function setup(t, start = '2026-10-24T08:00:00Z') {
  const store = new Store(); t.after(() => store.close());
  const clock = { now: new Date(start) };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.now, runnerCatalog: catalog, random: () => 0.5, missionRules: null });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let n = 0;
  const action = body => app.action('admin', body, `b-${++n}`);
  const member = (uid, name) => {
    const personId = action({ action: 'member.save', name }).id;
    app.session({ uid, name, email: `${uid}@example.invalid`, email_verified: true });
    action({ action: 'account.approve', uid, personId, version: 1, role: 'member' });
    return personId;
  };
  const sam = member('sam', 'Sam Beispiel'), kim = member('kim', 'Kim Beispiel');
  /** A run of 10 minutes, or one that ends at [at] (UTC). */
  const play = (meters, { uid = 'sam', at, body = {} } = {}) => {
    const end = at ? Date.parse(at) : +clock.now + 600000;
    clock.now = new Date(end - 600000);
    const { roundId } = app.runnerStart(uid);
    clock.now = new Date(end);
    return app.runnerScore(uid, { roundId, score: meters, meters, ...body }).progress;
  };
  return { store, app, clock, sam, kim, play };
}

test('servers announce the Tagesbonus', t => {
  const { app } = setup(t);
  assert.ok(apiFeatures.includes('runnerDailyBonus'));
  assert.ok(app.snapshot('sam').capabilities.features.includes('runnerDailyBonus'));
});

test('the first run of the day counts twice for the crates, the second once; statistics keep real metres', t => {
  const { app, store, sam, play } = setup(t);
  assert.equal(app.runnerWardrobe('sam').progress.bonusOpen, true);
  const first = play(812, { body: { score: 1200 } });
  assert.deepEqual([first.gained, first.bonus, first.runMeters, first.meters, first.bonusOpen], [812, 812, 812, 2400, false]);
  assert.deepEqual([first.gainedPoints, first.points.bonus], [{ run: 1200, bonus: 1200, missions: 0 }, 1200]);
  const second = play(500, { body: { score: 700 } });
  assert.deepEqual([second.gained, second.bonus, second.runMeters, second.meters, second.bonusOpen], [500, 0, 1312, 3100, false]);
  assert.deepEqual(second.gainedPoints, { run: 700, bonus: 0, missions: 0 });
  // Grinding is fine: a third, fourth … run counts its points, no cooldown, nothing less.
  assert.equal(play(500, { body: { score: 700 } }).meters, 3800);
  const w = app.runnerWardrobe('sam');
  assert.equal(w.progress.meters, 3800);
  assert.equal(w.progress.bonusOpen, false);
  assert.deepEqual([w.stats.meters, w.stats.bonusPoints, w.stats.points, w.stats.rounds, w.stats.best], [1812, 1200, 2600, 3, 1200]);
  assert.equal(store.get('runnerProgress', sam).bonusDay, '2026-10-24');
});

test('a run counts once: sending it again brings no second bonus', t => {
  const { app, clock } = setup(t);
  const { roundId } = app.runnerStart('sam'); clock.now = new Date(+clock.now + 600000);
  assert.equal(app.runnerScore('sam', { roundId, score: 812, meters: 812 }).progress.bonus, 812);
  // The same result again (a retry) gets the first answer and counts nothing (runner-rounds.mjs).
  assert.equal(app.runnerScore('sam', { roundId, score: 812, meters: 812 }).progress.bonus, 812);
  assert.throws(() => app.runnerScore('sam', { roundId, score: 813, meters: 812 }), { status: 409, code: 'round_unknown' });
  const w = app.runnerWardrobe('sam');
  assert.deepEqual([w.progress.meters, w.progress.points.bonus, w.stats.rounds], [1624, 812, 1]);
});

test('the day changes at midnight in Berlin, in summer and in winter time', t => {
  const { play } = setup(t, '2026-10-24T12:00:00Z');
  // 23:59 CEST on 24 October, then 00:01 CEST on the 25th: two days, two bonuses.
  assert.equal(play(100, { at: '2026-10-24T21:59:00Z' }).bonus, 100);
  assert.equal(play(100, { at: '2026-10-24T22:01:00Z' }).bonus, 100);
  // The clocks go back on the 25th: 23:30 CET is still the 25th (in UTC+2 it would be the 26th) …
  assert.equal(play(100, { at: '2026-10-25T22:30:00Z' }).bonus, 0);
  // … and the 26th begins at 23:00 UTC.
  assert.equal(play(100, { at: '2026-10-25T23:01:00Z' }).bonus, 100);
  // A run that starts before midnight and ends after it counts for the day it ends on.
  assert.equal(play(100, { at: '2026-10-26T23:03:00Z' }).bonus, 100);
});

test('in spring the day also changes at midnight in Berlin', t => {
  const { play } = setup(t, '2027-03-27T12:00:00Z');
  assert.equal(play(100, { at: '2027-03-27T22:30:00Z' }).bonus, 100); // 23:30 CET, 27 March
  assert.equal(play(100, { at: '2027-03-27T23:05:00Z' }).bonus, 100); // 00:05 CET, 28 March
  // The clocks went forward on the 28th: 23:30 CEST is still the 28th, the 29th begins at 22:00 UTC.
  assert.equal(play(100, { at: '2027-03-28T21:30:00Z' }).bonus, 0);
  assert.equal(play(100, { at: '2027-03-28T22:05:00Z' }).bonus, 100);
});

test('a refused run and a run of 0 m leave the bonus open', t => {
  const { app, clock, play } = setup(t);
  // Implausible metres: refused, nothing counted.
  const { roundId } = app.runnerStart('sam'); clock.now = new Date(+clock.now + 10000);
  const limit = Math.floor(runnerMaxMeters(10 + stageRunner.slackSeconds) * stageRunner.tolerance);
  assert.throws(() => app.runnerScore('sam', { roundId, score: limit + 1, meters: limit + 1 }), { status: 400, code: 'implausible' });
  // An unknown run: refused as well.
  assert.throws(() => app.runnerScore('sam', { roundId: 'nope', score: 10, meters: 10 }), { status: 409, code: 'round_unknown' });
  assert.equal(app.runnerWardrobe('sam').progress.bonusOpen, true);
  const zero = play(0);
  assert.deepEqual([zero.gained, zero.bonus, zero.bonusOpen], [0, 0, true]);
  assert.equal(play(300).bonus, 300);
  assert.equal(app.runnerWardrobe('sam').stats.rounds, 2);
});

test('older apps without metres get the bonus on their estimate', t => {
  const { play } = setup(t);
  const run = play(0, { body: { score: 1000, meters: undefined } });
  assert.equal(run.gained, Math.floor(1000 * runnerUnlocks.legacyMetersFactor));
  assert.equal(run.bonus, run.gained);
  // The score fits the estimated metres: it counts, and again as the bonus.
  assert.deepEqual(run.gainedPoints, { run: 1000, bonus: 1000, missions: 0 });
  assert.equal(run.meters, 2000);
});

test('the Ensemble-Strecke counts only real metres', t => {
  const { app, play } = setup(t);
  const sam = play(1000), kim = play(700, { uid: 'kim' });
  assert.equal(sam.bonus, 1000);
  assert.equal(sam.ensemble.gained, 1000);
  assert.equal(kim.ensemble.gained, 700);
  assert.equal(kim.ensemble.meters, 1700);
  const w = app.runnerWardrobe('sam');
  assert.equal(w.ensemble.meters, 1700);
  assert.equal(w.ensemble.section.own, 1000);
  // Each person has a bonus of their own.
  assert.equal(app.runnerWardrobe('kim').progress.points.bonus, 700);
});

test('the bonus can reach a crate that the points alone do not', t => {
  const { app, play } = setup(t);
  const run = play(1100, { body: { score: 1600 } });
  assert.deepEqual([run.meters, run.earned, run.crates, run.newCrates, run.previousAt, run.nextAt], [3200, 1, 1, 1, 3000, 6300]);
  const opening = app.runnerOpenCrate('sam', 'bonus-crate', { dupes: true });
  assert.ok(['h1', 'h2'].includes(opening.item.id));
  assert.equal(opening.wardrobe.progress.crates, 0);
  assert.equal(opening.wardrobe.stats.meters, 1100);
  // The same metres on a day whose bonus is used bring no crate.
  const later = play(1100, { body: { score: 1600 } });
  assert.deepEqual([later.meters, later.newCrates], [4800, 0]);
});
