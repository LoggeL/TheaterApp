import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { loadCatalog } from '../src/runner-wardrobe.mjs';
import { announceContentDrops, dropCatchUpMs } from '../src/runner-drop-push.mjs';
import { berlinIso, requestedStart } from '../src/runner-release-schedule.mjs';

// The admins' Release-Zeitplan (`runnerReleaseSchedule`): the plan of releases.json with dates the
// admins change at runtime, stored as overrides, guarded for live releases, with the drop push as
// documented and never twice.

const hourMs = 3600000, dayMs = 24 * hourMs;
const now = Date.parse('2026-11-17T12:00:00.000Z');
const fixtures = new URL('./fixtures/wardrobe/', import.meta.url);
const item = (id, extra = {}) => ({ id, kind: 'character', name: id, role: id, play: 'Stück', year: 2026, rarity: 'blue', image: 'figure.webp', ...extra });
const catalogData = {
  roleFigures: true,
  rarities: [{ id: 'blue', name: 'Blau', color: '#0088FF', weight: 1, gage: 10 }],
  items: [
    ...['character', 'backdrop', 'obstacles', 'fx'].map(kind => ({ id: `${kind}.default`, kind, name: 'Default', rarity: 'blue', default: true })),
    item('live.a'), item('live.b'), item('future.a'), item('future.b'), item('held.a'), item('held.b', { image: undefined }),
    item('stage.old', { kind: 'backdrop' }),
  ],
};
const iso = ms => new Date(ms).toISOString();
const plan = [
  { id: 'old-stage', name: 'Alte Bühne', startsAt: iso(now - 30 * dayMs), freeItemIds: ['stage.old'] },
  { id: 'live-pack', name: 'Schon da', startsAt: iso(now - 12 * hourMs), itemIds: ['live.a', 'live.b'], goalMeters: 1000, crateCount: 3 },
  { id: 'held-pack', name: 'Ohne Bilder', startsAt: iso(now - dayMs), itemIds: ['held.a', 'held.b'] },
  { id: 'future-pack', name: 'Traumstück', startsAt: '2026-11-22T18:00:00+01:00', itemIds: ['future.a', 'future.b'], goalMeters: 1000, crateCount: 3 },
];

/** The push worker first ran ten days ago; `player` has a counted run, so drops reach them. */
function setup(t, { store = new Store(), cutoverAt = now - 10 * dayMs } = {}) {
  t.after(() => { try { store.close(); } catch { /* closed by the test */ } });
  const clock = { at: new Date(cutoverAt) };
  const options = { bootstrapEmail: 'admin@example.invalid', pushEnabled: true, runnerCatalog: loadCatalog(catalogData, fixtures), runnerReleases: plan, clock: () => clock.at, missionRules: null };
  const app = new Theater(store, options);
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let n = 0;
  const member = uid => {
    const personId = app.action('admin', { action: 'member.save', name: uid }, `member-${++n}`).id;
    app.session({ uid, name: uid, email: `${uid}@example.invalid`, email_verified: true });
    app.action('admin', { action: 'account.approve', uid, personId, version: 1, role: 'member' }, `approve-${++n}`);
    return personId;
  };
  const player = member('player');
  const { roundId } = app.runnerStart('player');
  clock.at = new Date(+clock.at + 60000);
  app.runnerScore('player', { roundId, score: 100, meters: 100 });
  announceContentDrops(app);
  clock.at = new Date(now);
  announceContentDrops(app);
  const at = ms => { clock.at = new Date(ms); announceContentDrops(app); };
  const jobs = () => store.all('pushJobs').filter(x => x.title.startsWith('Neu: '));
  const entry = id => app.runnerReleaseSchedule('admin').releases.find(r => r.id === id);
  return { app, store, clock, options, player, at, jobs, entry };
}

test('the server announces the Release-Zeitplan', () => {
  assert.ok(apiFeatures.includes('runnerReleaseSchedule'));
});

test('admins see the timeline earliest first with status, item count and push', t => {
  const { app, jobs } = setup(t);
  const view = app.runnerReleaseSchedule('admin');
  assert.equal(view.timeZone, 'Europe/Berlin');
  assert.equal(view.defaultTime, '18:00');
  assert.equal(view.serverTime, iso(now));
  assert.deepEqual(view.releases.map(r => r.id), ['old-stage', 'held-pack', 'live-pack', 'future-pack']);
  const byId = new Map(view.releases.map(r => [r.id, r]));
  assert.deepEqual(byId.get('live-pack'), {
    id: 'live-pack', name: 'Schon da', startsAt: iso(now - 12 * hourMs), plannedStartsAt: iso(now - 12 * hourMs), overridden: false,
    itemCount: 2, active: true, ready: true, status: 'live', missing: 0, push: byId.get('live-pack').push,
  });
  // Started before the push existed: silent. Started later, ready: sent once.
  assert.deepEqual(byId.get('old-stage').push, { state: 'silent', at: null });
  assert.equal(byId.get('live-pack').push.state, 'sent');
  assert.equal(jobs().length, 1);
  assert.deepEqual({ ...byId.get('held-pack'), push: byId.get('held-pack').push.state }, {
    id: 'held-pack', name: 'Ohne Bilder', startsAt: iso(now - dayMs), plannedStartsAt: iso(now - dayMs), overridden: false,
    itemCount: 2, active: true, ready: false, status: 'blocked', missing: 1, push: 'held',
  });
  assert.equal(byId.get('future-pack').status, 'scheduled');
  assert.equal(byId.get('future-pack').ready, true);
  assert.deepEqual(byId.get('future-pack').push, { state: 'pending', at: null });
});

test('only admins: 403 for members on both routes, and nothing changes', t => {
  const { app, store, entry } = setup(t);
  assert.throws(() => app.runnerReleaseSchedule('player'), { status: 403 });
  assert.throws(() => app.runnerReleaseReschedule('player', 'future-pack', { date: '2026-11-20' }), { status: 403 });
  assert.equal(store.all('runnerReleaseOverrides').length, 0);
  assert.equal(entry('future-pack').startsAt, '2026-11-22T17:00:00.000Z');
});

test('a new date is stored as an override: releases.json stays the default, a restart keeps it', t => {
  const { app, store, options, entry } = setup(t);
  const moved = app.runnerReleaseReschedule('admin', 'future-pack', { date: '2026-12-13' });
  // 18:00 in Berlin by default.
  assert.equal(moved.startsAt, '2026-12-13T17:00:00.000Z');
  assert.equal(moved.plannedStartsAt, '2026-11-22T17:00:00.000Z');
  assert.equal(moved.overridden, true);
  assert.deepEqual(store.get('runnerReleaseOverrides', 'future-pack'), { releaseId: 'future-pack', startsAt: '2026-12-13T18:00:00+01:00', updatedAt: iso(now), updatedBy: store.account('admin').personId });
  // The plan of releases.json is untouched; the release itself takes the new date everywhere.
  assert.equal(app.plannedRunnerReleases.find(r => r.id === 'future-pack').startsAt, '2026-11-22T17:00:00.000Z');
  assert.equal(app.runnerReleases.find(r => r.id === 'future-pack').startsAt, '2026-12-13T17:00:00.000Z');
  const restarted = new Theater(store, options);
  assert.equal(restarted.runnerReleases.find(r => r.id === 'future-pack').startsAt, '2026-12-13T17:00:00.000Z');
  // The audit log names it.
  const audit = store.db.prepare("SELECT actor, action, subject FROM audit WHERE action = 'runnerRelease.reschedule'").all();
  assert.deepEqual(audit.map(a => ({ ...a })), [{ actor: 'admin', action: 'runnerRelease.reschedule', subject: 'future-pack 2026-11-22T17:00:00.000Z -> 2026-12-13T17:00:00.000Z' }]);
  // Back to the plan: the override goes, so a later deploy of releases.json counts again.
  const reset = app.runnerReleaseReschedule('admin', 'future-pack', { startsAt: null });
  assert.equal(reset.startsAt, '2026-11-22T17:00:00.000Z');
  assert.equal(reset.overridden, false);
  assert.equal(store.get('runnerReleaseOverrides', 'future-pack'), null);
  assert.equal(entry('future-pack').startsAt, '2026-11-22T17:00:00.000Z');
  // The planned date itself is no override either.
  app.runnerReleaseReschedule('admin', 'future-pack', { startsAt: '2026-11-22T18:00:00+01:00' });
  assert.equal(store.get('runnerReleaseOverrides', 'future-pack'), null);
});

test('an override of a release that releases.json no longer has is ignored', t => {
  const { app, store, options } = setup(t);
  store.put('runnerReleaseOverrides', 'gone', { releaseId: 'gone', startsAt: '2026-11-18T18:00:00+01:00' });
  const restarted = new Theater(store, options);
  assert.deepEqual(restarted.runnerReleases.map(r => r.id), plan.map(r => r.id));
  assert.equal(app.runnerReleaseSchedule('admin').releases.length, plan.length);
});

test('dates: ISO with offset or a Berlin day and time; anything else is refused', t => {
  const { app } = setup(t);
  // Berlin wall clock in winter and in summer time, also on the day of the switch.
  assert.equal(requestedStart({ date: '2026-11-22' }), Date.parse('2026-11-22T17:00:00Z'));
  assert.equal(requestedStart({ date: '2027-03-28', time: '18:00' }), Date.parse('2027-03-28T16:00:00Z'));
  assert.equal(requestedStart({ date: '2027-06-01', time: '09:30' }), Date.parse('2027-06-01T07:30:00Z'));
  assert.equal(requestedStart({ startsAt: '2026-11-22T18:00:00+01:00' }), Date.parse('2026-11-22T17:00:00Z'));
  assert.equal(requestedStart({ startsAt: '2026-11-22T17:00Z' }), Date.parse('2026-11-22T17:00:00Z'));
  assert.equal(requestedStart({ startsAt: null }), null);
  assert.equal(berlinIso(Date.parse('2027-03-28T16:00:00Z')), '2027-03-28T18:00:00+02:00');
  assert.equal(berlinIso(Date.parse('2026-11-22T17:00:00Z')), '2026-11-22T18:00:00+01:00');
  for (const body of [
    {}, { startsAt: '' }, { startsAt: 42 }, { startsAt: '2026-11-22T18:00:00' }, { startsAt: '2026-11-22' }, { startsAt: 'morgen' },
    { startsAt: '2026-02-30T18:00:00+01:00' }, { startsAt: '2026-11-22T24:00:00+01:00' }, { startsAt: '2026-11-22T18:00:00+25:00' },
    { date: '2026-02-30' }, { date: '22.11.2026' }, { date: '2026-11-22', time: '25:00' }, { date: '2026-11-22', time: '18' }, { date: '1999-11-22' },
  ]) {
    assert.throws(() => app.runnerReleaseReschedule('admin', 'future-pack', body), { status: 400, code: 'invalid_date' }, JSON.stringify(body));
  }
  assert.throws(() => app.runnerReleaseReschedule('admin', 'nope', { date: '2026-11-22' }), { status: 404 });
  assert.equal(app.store.all('runnerReleaseOverrides').length, 0);
});

test('a live release moves into the future only with confirm; its push never comes twice', t => {
  const { app, store, at, jobs, entry, clock } = setup(t);
  assert.equal(jobs().length, 1);
  assert.ok(app.runnerCatalog.byId.has('live.a'));
  assert.throws(() => app.runnerReleaseReschedule('admin', 'live-pack', { date: '2026-11-30' }), { status: 409, code: 'release_live' });
  assert.equal(store.get('runnerReleaseOverrides', 'live-pack'), null);
  assert.equal(entry('live-pack').status, 'live');
  // Another date in the past keeps it live: no confirmation needed.
  assert.equal(app.runnerReleaseReschedule('admin', 'live-pack', { startsAt: iso(now - 3 * dayMs) }).status, 'live');
  // With confirm it goes back to "geplant", and its figures are hidden again.
  const moved = app.runnerReleaseReschedule('admin', 'live-pack', { date: '2026-11-30', confirm: true });
  assert.equal(moved.status, 'scheduled');
  assert.equal(moved.push.state, 'sent');
  assert.ok(!app.runnerCatalog.byId.has('live.a'));
  at(Date.parse('2026-11-30T17:00:00Z'));
  assert.ok(app.runnerCatalog.byId.has('live.a'));
  assert.equal(jobs().length, 1, 'the push of the first start stays the only one');
  // A pack held back for its pictures has nothing players own: it moves without a confirmation.
  clock.at = new Date(now);
  assert.equal(app.runnerReleaseReschedule('admin', 'held-pack', { date: '2026-12-01' }).status, 'scheduled');
});

test('moved to now, a release goes live at once with one push; repeated moves send nothing more', t => {
  const { app, at, jobs, player, entry } = setup(t);
  assert.ok(!app.runnerCatalog.byId.has('future.a'));
  const moved = app.runnerReleaseReschedule('admin', 'future-pack', { startsAt: iso(now) });
  assert.equal(moved.status, 'live');
  assert.equal(moved.push.state, 'sent');
  assert.ok(app.runnerCatalog.byId.has('future.a'));
  const pushes = jobs().filter(j => j.title === 'Neu: Traumstück');
  assert.equal(pushes.length, 1);
  assert.deepEqual(pushes[0].recipientPersonIds, [player]);
  // Moved again, earlier or later in the past, or the worker running again: still one.
  app.runnerReleaseReschedule('admin', 'future-pack', { startsAt: iso(now - hourMs) });
  at(now + 15000);
  assert.equal(jobs().filter(j => j.title === 'Neu: Traumstück').length, 1);
  assert.equal(entry('future-pack').push.state, 'sent');
});

test('moved into the past: within a day it is announced, further back it is not', t => {
  const recent = setup(t);
  recent.app.runnerReleaseReschedule('admin', 'future-pack', { startsAt: iso(now - dropCatchUpMs + 60000) });
  assert.equal(recent.jobs().filter(j => j.title === 'Neu: Traumstück').length, 1);

  const old = setup(t);
  const moved = old.app.runnerReleaseReschedule('admin', 'future-pack', { startsAt: iso(now - 3 * dayMs) });
  assert.equal(moved.status, 'live');
  assert.equal(moved.push.state, 'skipped');
  assert.equal(old.jobs().filter(j => j.title === 'Neu: Traumstück').length, 0);

  // Before the push existed (its cutover): silent, as documented.
  const beforeCutover = setup(t);
  const silent = beforeCutover.app.runnerReleaseReschedule('admin', 'future-pack', { startsAt: iso(now - 20 * dayMs) });
  assert.deepEqual(silent.push, { state: 'silent', at: null });
  assert.equal(beforeCutover.jobs().filter(j => j.title === 'Neu: Traumstück').length, 0);
});

test('a pack without its pictures stays held when moved to now, and the countdown follows the new date', t => {
  const { app, jobs, entry } = setup(t);
  const moved = app.runnerReleaseReschedule('admin', 'future-pack', { date: '2026-11-18', time: '09:00' });
  assert.equal(moved.startsAt, '2026-11-18T08:00:00.000Z');
  // Within a day of its start: the countdown of the wardrobe shows the new date.
  const view = app.runnerWardrobe('player');
  assert.equal(view.nextDrop.id, 'future-pack');
  assert.equal(view.nextDrop.startsAt, '2026-11-18T08:00:00.000Z');
  const held = app.runnerReleaseReschedule('admin', 'held-pack', { startsAt: iso(now) });
  assert.equal(held.status, 'blocked');
  assert.equal(held.push.state, 'held');
  assert.equal(jobs().filter(j => j.title === 'Neu: Ohne Bilder').length, 0);
  assert.equal(entry('held-pack').status, 'blocked');
});

test('over HTTP: 401 and 403 outside, the timeline and its changes for admins', async t => {
  const { app } = setup(t);
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  const call = (uid, path, method = 'GET', body) => fetch(`${base}${path}`, { method, headers: { ...(uid ? { Authorization: `Bearer ${uid}` } : {}), ...(body ? { 'Content-Type': 'application/json' } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}) });
  assert.equal((await call(null, '/admin/runner/releases')).status, 401);
  assert.equal((await call('player', '/admin/runner/releases')).status, 403);
  assert.equal((await call('player', '/admin/runner/releases/future-pack', 'PUT', { date: '2026-11-25' })).status, 403);
  const list = await call('admin', '/admin/runner/releases');
  assert.equal(list.status, 200);
  assert.equal(list.headers.get('cache-control'), 'no-store');
  assert.equal((await list.json()).releases.length, plan.length);
  const changed = await call('admin', '/admin/runner/releases/future-pack', 'PUT', { date: '2026-11-25', time: '19:30' });
  assert.equal(changed.status, 200);
  assert.equal((await changed.json()).startsAt, '2026-11-25T18:30:00.000Z');
  const refused = await call('admin', '/admin/runner/releases/live-pack', 'PUT', { date: '2026-11-25' });
  assert.equal(refused.status, 409);
  const problem = await refused.json();
  assert.equal(problem.code, 'release_live');
  assert.match(problem.error, /„Schon da“ ist bereits freigeschaltet/);
  const invalid = await call('admin', '/admin/runner/releases/future-pack', 'PUT', { startsAt: '2026-11-25T18:00:00' });
  assert.equal(invalid.status, 400);
  assert.equal((await invalid.json()).code, 'invalid_date');
  assert.equal((await call('admin', '/admin/runner/releases/unknown-pack', 'PUT', { date: '2026-11-25' })).status, 404);
});

test('the bundled plan: every release of releases.json shows, none overridden', t => {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', missionRules: null });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  const raw = JSON.parse(readFileSync(new URL('../src/wardrobe/releases.json', import.meta.url), 'utf8'));
  const view = app.runnerReleaseSchedule('admin');
  assert.deepEqual(view.releases.map(r => r.id).sort(), raw.map(r => r.id).sort());
  for (const r of view.releases) {
    assert.equal(r.overridden, false, r.id);
    assert.equal(r.startsAt, new Date(raw.find(x => x.id === r.id).startsAt).toISOString(), r.id);
  }
  const starts = view.releases.map(r => Date.parse(r.startsAt));
  assert.deepEqual(starts, [...starts].sort((a, b) => a - b));
});
