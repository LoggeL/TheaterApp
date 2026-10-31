import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { deliverPush } from '../src/push.mjs';
import { loadCatalog } from '../src/runner-wardrobe.mjs';
import { announceContentDrops, dropCatchUpMs, dropRecipients } from '../src/runner-drop-push.mjs';

const hourMs = 3600000;
const startsAt = '2026-11-08T17:00:00.000Z';
const start = Date.parse(startsAt);
const fixtures = new URL('./fixtures/wardrobe/', import.meta.url);
const item = (id, extra = {}) => ({ id, kind: 'character', name: id, role: id, play: 'Future', year: 2026, rarity: 'blue', image: 'figure.webp', ...extra });
const catalogData = (overrides = {}) => ({
  roleFigures: true,
  rarities: [{ id: 'blue', name: 'Blau', color: '#0088FF', weight: 1, gage: 10 }],
  items: [
    ...['character', 'backdrop', 'obstacles', 'fx'].map(kind => ({ id: `${kind}.default`, kind, name: 'Default', rarity: 'blue', default: true })),
    item('future.a', overrides.a), item('future.b', overrides.b),
    item('stage.old', { kind: 'backdrop' }), item('stage.new', { kind: 'backdrop', ...overrides.stage }),
  ],
});
const pack = { id: 'new-pack', name: 'Ein neues Stück', startsAt, itemIds: ['future.a', 'future.b'], goalMeters: 1000, crateCount: 3 };
const stage = { id: 'new-stage', name: 'Winterbühne', startsAt, freeItemIds: ['stage.new'] };
const earlier = { id: 'old-stage', name: 'Alte Bühne', startsAt: '2026-10-30T17:00:00.000Z', freeItemIds: ['stage.old'] };

/** A theater with the given plan. `deployedAt` is the first worker run, which notes the cutover. */
function setup(t, { releases = [earlier, pack], overrides, deployedAt = start - 2 * 24 * hourMs, store = new Store(), emailEnabled = false } = {}) {
  t.after(() => { try { store.close(); } catch { /* closed by the test */ } });
  const clock = { at: new Date(deployedAt) };
  const options = { bootstrapEmail: 'admin@example.invalid', pushEnabled: true, emailEnabled, runnerCatalog: loadCatalog(catalogData(overrides), fixtures), runnerReleases: releases, clock: () => clock.at, missionRules: null };
  const app = new Theater(store, options);
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let n = 0;
  const member = uid => {
    const personId = app.action('admin', { action: 'member.save', name: uid }, `member-${++n}`).id;
    app.session({ uid, name: uid, email: `${uid}@example.invalid`, email_verified: true });
    app.action('admin', { action: 'account.approve', uid, personId, version: 1, role: 'member' }, `approve-${++n}`);
    return personId;
  };
  const play = uid => {
    const { roundId } = app.runnerStart(uid);
    clock.at = new Date(+clock.at + 60000);
    app.runnerScore(uid, { roundId, score: 100, meters: 100 });
  };
  const player = member('player');
  play('player');
  announceContentDrops(app);
  const at = ms => { clock.at = new Date(ms); announceContentDrops(app); };
  return { app, store, clock, options, member, play, player, at, jobs: () => store.all('pushJobs').filter(x => x.title.startsWith('Neu: ')) };
}

test('nothing before the start, one push at the start with the name from the release', t => {
  const { jobs, at, player } = setup(t);
  at(start - 1);
  assert.equal(jobs().length, 0);
  at(start);
  assert.equal(jobs().length, 1);
  const [job] = jobs();
  assert.equal(job.title, 'Neu: Ein neues Stück');
  assert.equal(job.body, 'Jetzt freigeschaltet.');
  assert.deepEqual(job.recipientPersonIds, [player]);
  assert.deepEqual(job.data, {});
});

test('repeated runs stay at one push, also with a restart in between', t => {
  const { store, options, jobs, at } = setup(t);
  at(start); at(start + 15000); at(start + 30000);
  assert.equal(jobs().length, 1);
  const restarted = new Theater(store, options);
  announceContentDrops(restarted);
  assert.equal(jobs().length, 1);
  assert.equal(store.get('runnerDropPush', 'release:new-pack').recipients, 1);
});

test('a marker keeps a release from a second push when the plan moves it later', t => {
  const { store, options, jobs, at, clock } = setup(t);
  at(start);
  const moved = new Theater(store, { ...options, runnerReleases: [{ ...pack, startsAt: new Date(start + hourMs).toISOString() }] });
  clock.at = new Date(start + 2 * hourMs);
  announceContentDrops(moved);
  assert.equal(jobs().length, 1);
});

test('a second process on the same database cannot send the release again', t => {
  const dir = mkdtempSync(join(tmpdir(), 'theater-drop-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const file = join(dir, 'theater.sqlite');
  const { store, options, jobs, clock } = setup(t, { store: new Store(file) });
  const other = new Store(file); t.after(() => other.close());
  const first = new Theater(store, options), second = new Theater(other, options);
  clock.at = new Date(start);
  // The other process wins between the first one's look at the marker and its write transaction.
  const transaction = store.transaction.bind(store);
  store.transaction = fn => { store.transaction = transaction; announceContentDrops(second); return transaction(fn); };
  announceContentDrops(first);
  assert.equal(jobs().length, 1);
});

test('a short server pause is caught up within the window, one day and a tick later it is not', t => {
  const late = setup(t);
  late.at(start + dropCatchUpMs);
  assert.equal(late.jobs().length, 1);

  const tooLate = setup(t);
  tooLate.at(start + dropCatchUpMs + 1);
  assert.equal(tooLate.jobs().length, 0);
  assert.ok(tooLate.store.get('runnerDropPush', 'release:new-pack').skippedAt);
  tooLate.at(start + 2 * dropCatchUpMs);
  assert.equal(tooLate.jobs().length, 0);
});

test('what ran before the first deployment never pushes, even inside the catch-up window', t => {
  const fresh = Date.parse(earlier.startsAt) + 6 * hourMs;
  const { jobs, at, store } = setup(t, { deployedAt: fresh });
  const { at: cutover } = store.get('runnerDropPush', 'cutover');
  assert.ok(Date.parse(cutover) - Date.parse(earlier.startsAt) < dropCatchUpMs);
  at(fresh + 15 * 60000); at(fresh + hourMs);
  assert.equal(jobs().length, 0);
  assert.equal(store.get('runnerDropPush', 'release:old-stage'), null);
  assert.equal(store.get('runnerDropPush', 'cutover').at, cutover);

  at(start);
  assert.deepEqual(jobs().map(x => x.title), ['Neu: Ein neues Stück']);
});

test('a pack on hold for missing pictures stays silent and pushes once when it really starts', t => {
  const { store, options, jobs, at } = setup(t, { overrides: { b: { image: undefined } } });
  at(start); at(start + hourMs);
  assert.equal(jobs().length, 0);
  assert.ok(store.get('runnerDropPush', 'release:new-pack').heldAt);
  at(start + 3 * dropCatchUpMs);
  assert.equal(jobs().length, 0);

  // The pictures arrive with a deployment, days after the planned date.
  const deployed = new Theater(store, { ...options, runnerCatalog: loadCatalog(catalogData(), fixtures) });
  announceContentDrops(deployed);
  announceContentDrops(deployed);
  assert.equal(jobs().length, 1);
  assert.equal(store.get('runnerDropPush', 'release:new-pack').recipients, 1);
});

test('a disabled figure or a disabled stage holds its release, though the time has come', t => {
  const figure = setup(t, { overrides: { a: { disabled: true } } });
  figure.at(start);
  assert.equal(figure.jobs().length, 0);

  // `releasePackReady` is true for a release without roles; the stage itself decides.
  const backdrop = setup(t, { releases: [stage], overrides: { stage: { disabled: true } } });
  backdrop.at(start);
  assert.equal(backdrop.jobs().length, 0);

  const live = setup(t, { releases: [stage] });
  live.at(start);
  assert.deepEqual(live.jobs().map(x => x.title), ['Neu: Winterbühne']);
});

test('only active accounts with a counted run hear of the game', t => {
  const { app, store, member, play, jobs, at, player, clock } = setup(t, { emailEnabled: true });
  const never = member('never');
  const looked = member('looked'); app.runnerWardrobe('looked');
  const started = member('started'); app.runnerStart('started');
  const inactive = member('inactive'); play('inactive');
  store.put('members', inactive, { ...store.get('members', inactive), active: false });
  const suspended = member('suspended'); play('suspended');
  store.saveAccount({ ...store.account('suspended'), status: 'suspended' });
  const second = member('second'); play('second');
  assert.ok(store.get('runnerProgress', looked));
  assert.equal(store.get('runnerScores', looked), null);

  assert.deepEqual(dropRecipients(app).sort((a, b) => a - b), [player, second]);
  at(Math.max(start, +clock.at));
  const [job] = jobs();
  assert.deepEqual(job.recipientPersonIds.sort((a, b) => a - b), [player, second]);
  for (const id of [never, looked, started, inactive, suspended]) assert.ok(!job.recipientPersonIds.includes(id));
  assert.equal(store.all('emailJobs').length, 0);
});

test('without any player the release is settled without a job, which would need a recipient list', t => {
  const { app, store, jobs, at, player } = setup(t);
  store.put('members', player, { ...store.get('members', player), active: false });
  at(start);
  assert.equal(jobs().length, 0);
  assert.equal(store.get('runnerDropPush', 'release:new-pack').recipients, 0);
  store.put('members', player, { ...store.get('members', player), active: true });
  announceContentDrops(app);
  assert.equal(jobs().length, 0);
});

test('delivery reaches only the players, names no game and honours the switch "Pushes der Leitung"', async t => {
  const { store, app, member, play, jobs, at, player, clock } = setup(t);
  member('never');
  const quiet = member('quiet'); play('quiet');
  store.put('reminders', quiet, { direct: false });
  for (const uid of ['player', 'quiet', 'never', 'admin']) store.put('devices', uid, { id: uid, uid, token: `token-${uid}`, platform: 'android', notificationActions: uid === 'quiet' });
  at(Math.max(start, +clock.at));
  assert.deepEqual(jobs()[0].recipientPersonIds.sort((a, b) => a - b), [player, quiet].sort((a, b) => a - b));
  for (const x of store.all('pushJobs')) if (x.id !== jobs()[0].id) store.delete('pushJobs', x.id);
  const calls = [];
  await deliverPush(app, { sendEachForMulticast: async payload => { calls.push(payload); return { responses: payload.tokens.map(() => ({ success: true })) }; } });
  assert.deepEqual(calls.map(x => x.tokens), [['token-player']]);
  assert.deepEqual(calls[0].notification, { title: 'Neu: Ein neues Stück', body: 'Jetzt freigeschaltet.' });
  assert.doesNotMatch(JSON.stringify(jobs()[0]), /bühnenlauf|spiel|garderobe|runner/i);
  assert.equal(jobs()[0].status, 'accepted_by_provider');
});

test('a server without push writes nothing, so no cutover hides a later drop', t => {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { pushEnabled: false, runnerCatalog: loadCatalog(catalogData(), fixtures), runnerReleases: [pack], clock: () => new Date(start), missionRules: null });
  announceContentDrops(app);
  assert.equal(store.get('runnerDropPush', 'cutover'), null);
});

test('the bundled plan: a deployment today skips Creepshow and catches the next drop', t => {
  const store = new Store(); t.after(() => store.close());
  let at = new Date('2026-10-31T12:00:00.000Z');
  const app = new Theater(store, { pushEnabled: true, bootstrapEmail: 'admin@example.invalid', clock: () => at });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  store.put('runnerScores', store.account('admin').personId, { personId: store.account('admin').personId, best: 10, bestAt: at.toISOString(), rounds: 1, lastPlayedAt: at.toISOString() });
  announceContentDrops(app);
  assert.equal(store.all('pushJobs').length, 0);
  at = new Date('2026-11-08T16:59:59.000Z'); announceContentDrops(app);
  assert.equal(store.all('pushJobs').length, 0);
  at = new Date('2026-11-08T17:00:05.000Z'); announceContentDrops(app); announceContentDrops(app);
  assert.deepEqual(store.all('pushJobs').map(x => x.title), ['Neu: Eine höllische Herausforderung']);
});

test('the push worker runs the check before it delivers, and only for the main theater', () => {
  const index = readFileSync(new URL('../src/index.mjs', import.meta.url), 'utf8');
  assert.equal(index.match(/announceContentDrops\(/g).length, 1);
  assert.ok(index.indexOf('announceContentDrops(theater)') < index.indexOf('await deliverPush(theater,'));
  assert.ok(index.indexOf('announceContentDrops(theater)') > index.indexOf('const tick = async'));
});
