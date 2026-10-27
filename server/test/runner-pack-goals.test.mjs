import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { recordPackRun, packGoalsView, nextPackCrate, markPackCrateOpened } from '../src/runner-pack-goals.mjs';

const startsAt = '2026-11-08T17:00:00.000Z';
const release = { id: 'hell-2026', name: 'Eine höllische Herausforderung', startsAt, goalMeters: 100000, crateCount: 3, itemIds: ['hell.a', 'hell.b'] };
function setup(test, options = {}) {
  const store = new Store(options.path); test.after(() => store.close());
  const clock = { now: new Date(startsAt) };
  const t = { store, clock: () => clock.now, runnerReleases: [structuredClone(release)], runnerCatalog: { byId: new Map(['hell.a', 'hell.b'].map(id => [id, { id, kind: 'character', image: `/games/runner/skins/${id}.webp` }])) } };
  for (const personId of [1, 2, 3]) store.put('members', personId, { id: personId, active: true });
  const run = (personId, meters, at = clock.now) => store.transaction(() => recordPackRun(t, personId, meters, at));
  const open = (personId, releaseId = release.id) => store.transaction(() => markPackCrateOpened(t, personId, releaseId));
  return { t, store, clock, run, open };
}

test('release boundary uses server time and ignores historical/lifetime metres', test => {
  const { t, store, clock, run } = setup(test);
  store.put('runnerProgress', 1, { meters: 3000000 });
  clock.now = new Date(Date.parse(startsAt) - 1);
  assert.deepEqual(packGoalsView(t, 1), []);
  run(1, 100000);
  run(1, 100000, new Date(startsAt));
  assert.equal(store.get('runnerPackGoals', release.id), null, 'a future start cannot bypass server time');
  clock.now = new Date(startsAt);
  assert.equal(packGoalsView(t, 1)[0].meters, 0);
  run(1, 300, new Date(Date.parse(startsAt) - 1));
  assert.equal(packGoalsView(t, 1)[0].meters, 0);
  run(1, 400);
  assert.equal(packGoalsView(t, 1)[0].meters, 400);
  run(1, 500, new Date(+clock.now + 1));
  assert.equal(packGoalsView(t, 1)[0].meters, 400, 'future time is not counted');
  const started = clock.now;
  clock.now = new Date(+started + 600000);
  run(1, 99600, started);
  assert.equal(packGoalsView(t, 1)[0].reachedAt, clock.now.toISOString(), 'completion records finish, not run start');
});

test('completion awards exactly three set crates to contributors, including the crossing run', test => {
  const { t, run, open } = setup(test);
  run(1, 30000); run(2, 69999);
  assert.equal(nextPackCrate(t, 1, release.id), null);
  assert.equal(packGoalsView(t, 2)[0].crates, 0);
  run(2, 2);
  for (const id of [1, 2]) {
    assert.equal(packGoalsView(t, id)[0].crates, 3);
    assert.deepEqual(nextPackCrate(t, id, release.id).itemIds, release.itemIds);
  }
  run(3, 1500);
  assert.equal(nextPackCrate(t, 3, release.id), null, 'late joiner receives no retrospective reward');
  assert.equal(packGoalsView(t, 3)[0].contributionMeters, 0);
  assert.equal(packGoalsView(t, 1)[0].meters, 100001);
  assert.equal(packGoalsView(t, 1)[0].contributors, 2);
  assert.equal(packGoalsView(t, 1)[0].contributionMeters, 30000);
  assert.equal(open(1), true); assert.equal(open(1), true); assert.equal(open(1), true);
  assert.equal(open(1), false);
  assert.equal(nextPackCrate(t, 1, release.id), null);
  assert.equal(packGoalsView(t, 2)[0].crates, 3, 'other contributor balance remains independent');
  assert.equal(nextPackCrate(t, 2, 'other-pack'), null);
});

test('goal and pool stay frozen after catalog/manifest changes and after process reconstruction', test => {
  const dir = mkdtempSync(join(tmpdir(), 'runner-pack-'));
  test.after(() => rmSync(dir, { recursive: true, force: true }));
  const path = join(dir, 'test.sqlite');
  const { t, store, run, open } = setup(test, { path });
  run(1, 100000); open(1);
  t.runnerReleases[0].itemIds.push('hell.new');
  t.runnerReleases[0].crateCount = 9;
  t.runnerReleases[0].goalMeters = 1;
  t.runnerCatalog.byId.set('hell.new', { id: 'hell.new', kind: 'character', image: '/games/runner/skins/hell.new.webp' });
  assert.deepEqual(nextPackCrate(t, 1).itemIds, release.itemIds);
  assert.equal(packGoalsView(t, 1)[0].crateCount, 3);
  assert.equal(packGoalsView(t, 1)[0].goalMeters, 100000);
  const reopened = new Store(path); test.after(() => reopened.close());
  const restarted = { ...t, store: reopened };
  assert.equal(nextPackCrate(restarted, 1).remaining, 2);
  assert.deepEqual(nextPackCrate(restarted, 1).itemIds, release.itemIds);
  assert.equal(store.get('runnerPackGoals', release.id).meters, 100000);
});

test('incomplete sets wait for the whole pool and do not silently substitute another set', test => {
  const { t, run } = setup(test);
  t.runnerCatalog.byId.delete('hell.b');
  assert.deepEqual(packGoalsView(t, 1), []);
  run(1, 100000);
  t.runnerCatalog.byId.set('hell.b', { id: 'hell.b', kind: 'character' });
  assert.deepEqual(packGoalsView(t, 1), [], 'present item without its actual image does not launch the goal');
  run(1, 100000);
  t.runnerCatalog.byId.get('hell.b').image = '';
  assert.deepEqual(packGoalsView(t, 1), [], 'empty image is not ready');
  t.runnerCatalog.byId.get('hell.b').image = '/games/runner/skins/hell.b.webp';
  assert.equal(packGoalsView(t, 1)[0].meters, 0);
  run(1, 100000);
  assert.deepEqual(nextPackCrate(t, 1).itemIds, release.itemIds);
  t.runnerCatalog.byId.delete('hell.b');
  assert.deepEqual(nextPackCrate(t, 1).itemIds, release.itemIds, 'already earned pool cannot change');
});

test('active-member awards are frozen at completion; deletion does not subtract shared metres', test => {
  const { t, store, run } = setup(test);
  run(1, 1000);
  store.put('members', 1, { id: 1, active: false });
  run(1, 1000);
  assert.equal(packGoalsView(t, 2)[0].meters, 1000);
  run(2, 99000);
  store.put('members', 1, { id: 1, active: true });
  assert.equal(nextPackCrate(t, 1), null, 'inactive at completion has no retrospective grant');
  store.delete('members', 2);
  assert.equal(nextPackCrate(t, 2), null);
  assert.equal(packGoalsView(t, 1)[0].meters, 100000);
  store.put('members', 2, { id: 2, active: true });
  assert.equal(nextPackCrate(t, 2).remaining, 3, 'earned award survives temporary inactivity');
});

test('separate releases track independent goals and expose only personal contribution', test => {
  const { t, clock, run } = setup(test);
  t.runnerCatalog.byId.set('romeo.a', { id: 'romeo.a', kind: 'character', image: '/games/runner/skins/romeo.a.webp' });
  t.runnerReleases.push({ ...release, id: 'romeo-2026', name: 'Romeo und Julia', startsAt: '2026-12-30T17:00:00.000Z', itemIds: ['romeo.a'] });
  run(1, 100000);
  clock.now = new Date('2026-12-30T17:00:00.000Z');
  run(2, 50000);
  const own = packGoalsView(t, 2);
  assert.equal(own.length, 2);
  assert.equal(own[0].meters, 100000);
  assert.equal(own[0].contributionMeters, 0);
  assert.equal(own[1].meters, 50000);
  assert.equal(own[1].contributionMeters, 50000);
  assert.equal(JSON.stringify(own).includes('personId'), false);
});


test('late artwork activation excludes in-progress rounds but counts the first ready start', test => {
  const { t, store, clock, run } = setup(test);
  t.runnerCatalog.byId.delete('hell.b');
  const beforeReady = new Date(+clock.now + 300000);
  clock.now = beforeReady;
  assert.deepEqual(packGoalsView(t, 1), [], 'runner start while art is missing does not activate');
  clock.now = new Date(+clock.now + 300000);
  t.runnerCatalog.byId.set('hell.b', { id: 'hell.b', kind: 'character', image: '/games/runner/skins/hell.b.webp' });
  packGoalsView(t, 2); // runnerStart initializes before storing the trusted start.
  const firstReadyStart = clock.now;
  assert.equal(store.get('runnerPackGoals', release.id).activationAt, firstReadyStart.toISOString());
  clock.now = new Date(+clock.now + 600000);
  run(1, 1000, beforeReady);
  assert.equal(packGoalsView(t, 1)[0].meters, 0, 'a run begun before actual activation is excluded');
  run(2, 1500, firstReadyStart);
  assert.equal(packGoalsView(t, 2)[0].meters, 1500, 'the first start exactly at activation counts');
  assert.equal(packGoalsView(t, 1)[0].contributionMeters, 0);
});

test('preloaded scheduled packs count the first round and existing goals retain their old boundary', test => {
  const { t, store, clock, run } = setup(test);
  clock.now = new Date(Date.parse(startsAt) - 1);
  assert.deepEqual(packGoalsView(t, 1), []);
  clock.now = new Date(startsAt);
  packGoalsView(t, 1); // runnerStart's initialization at the scheduled boundary.
  const firstStart = clock.now;
  clock.now = new Date(+clock.now + 600000);
  run(1, 2000, firstStart);
  assert.equal(packGoalsView(t, 1)[0].meters, 2000);
  const existing = store.get('runnerPackGoals', release.id);
  delete existing.activationAt;
  store.put('runnerPackGoals', release.id, existing);
  run(2, 3000, firstStart);
  assert.equal(packGoalsView(t, 2)[0].meters, 5000, 'records from before activationAt preserve their release boundary');
});
