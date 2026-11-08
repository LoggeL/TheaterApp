import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { loadCatalog } from '../src/runner-wardrobe.mjs';
import { nextDrop, nextDropWindowMs } from '../src/runner-next-drop.mjs';

const startsAt = '2026-11-08T17:00:00.000Z', start = Date.parse(startsAt);
const minute = 60000;
const fixtures = new URL('./fixtures/wardrobe/', import.meta.url);
const data = {
  roleFigures: true,
  rarities: [{ id: 'blue', name: 'Blau', color: '#0088FF', weight: 1, gage: 10 }],
  items: [
    ...['character', 'backdrop', 'obstacles', 'fx'].map(kind => ({ id: `${kind}.default`, kind, name: 'Default', rarity: 'blue', default: true })),
    { id: 'present', kind: 'character', name: 'Present', role: 'Present', play: 'Present', year: 2025, rarity: 'blue', personId: 901, image: 'figure.webp' },
    { id: 'future.a', kind: 'character', name: 'Future A', role: 'A', play: 'Future', year: 2026, rarity: 'blue', personId: 902, image: 'figure.webp' },
    // No picture yet: its pack waits (`releasePackReady`).
    { id: 'held.a', kind: 'character', name: 'Held A', role: 'A', play: 'Held', year: 2026, rarity: 'blue', personId: 903 },
    { id: 'later.map', kind: 'backdrop', name: 'Later stage', rarity: 'blue', image: 'figure.webp' },
  ],
};
const pack = { id: 'new-pack', name: 'Neue Rollen', startsAt, itemIds: ['future.a'] };

function setup(t, releases = [pack]) {
  const store = new Store(); t.after(() => store.close());
  const clock = { at: new Date(start - 23 * 60 * minute - 59 * minute) };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', runnerCatalog: loadCatalog(data, fixtures), runnerReleases: releases, clock: () => clock.at, random: () => 0.9, missionRules: null });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  const personId = app.action('admin', { action: 'member.save', name: 'Sam' }, 'member-sam').id;
  app.session({ uid: 'sam', name: 'Sam', email: 'sam@example.invalid', email_verified: true });
  app.action('admin', { action: 'account.approve', uid: 'sam', personId, version: 1, role: 'member' }, 'approve-sam');
  return { app, store, clock, personId };
}

test('the next drop shows within a day of its start and not before or once it is live', t => {
  const { app, clock } = setup(t);
  // 23:59 h ahead.
  const soon = app.runnerWardrobe('sam', { roles: true });
  assert.deepEqual(soon.nextDrop, { id: 'new-pack', name: 'Neue Rollen', startsAt, ready: true });
  assert.equal(soon.now, clock.at.toISOString());
  // The older apps' view carries it the same way.
  assert.equal(app.runnerWardrobe('sam').nextDrop.id, 'new-pack');
  clock.at = new Date(start - 24 * 60 * minute - minute);
  const early = app.runnerWardrobe('sam', { roles: true });
  assert.equal(early.nextDrop, undefined);
  assert.equal(early.now, undefined);
  clock.at = new Date(start - nextDropWindowMs);
  assert.equal(app.runnerWardrobe('sam', { roles: true }).nextDrop, undefined, 'exactly a day ahead is not yet within it');
  clock.at = new Date(start - 1000);
  assert.equal(app.runnerWardrobe('sam', { roles: true }).nextDrop.ready, true);
  clock.at = new Date(start);
  const live = app.runnerWardrobe('sam', { roles: true });
  assert.equal(live.nextDrop, undefined);
  assert.ok(live.catalog.items.some(x => x.id === 'future.a'), 'released');
});

test('a pack held back for its pictures is not ready and keeps its card for a day after its start', t => {
  const held = { id: 'held-pack', name: 'Wartende Rollen', startsAt, itemIds: ['held.a'] };
  const { app, clock } = setup(t, [held]);
  assert.deepEqual(app.runnerWardrobe('sam', { roles: true }).nextDrop, { id: 'held-pack', name: 'Wartende Rollen', startsAt, ready: false });
  clock.at = new Date(start + 60 * minute);
  const waiting = app.runnerWardrobe('sam', { roles: true });
  assert.deepEqual(waiting.nextDrop, { id: 'held-pack', name: 'Wartende Rollen', startsAt, ready: false });
  assert.ok(!waiting.catalog.items.some(x => x.id === 'held.a'), 'still hidden from the players');
  clock.at = new Date(start + nextDropWindowMs);
  assert.equal(app.runnerWardrobe('sam', { roles: true }).nextDrop, undefined);
});

test('the earliest drop within the window wins; a stage drop is ready once its picture is deployed', t => {
  const stage = { id: 'stage', name: 'Neue Bühne', startsAt: new Date(start + 60 * minute).toISOString(), gatedItemIds: ['later.map'] };
  const { app, clock } = setup(t, [stage, pack]);
  assert.equal(nextDrop(app, +clock.at).id, 'new-pack');
  clock.at = new Date(start);
  assert.deepEqual(nextDrop(app, +clock.at), { id: 'stage', name: 'Neue Bühne', startsAt: stage.startsAt, ready: true });
  clock.at = new Date(start + 60 * minute);
  assert.equal(nextDrop(app, +clock.at), null);
});

test('a held pack that started does not hide a drop still to come; it shows again without one', t => {
  const held = { id: 'held-pack', name: 'Wartende Rollen', startsAt, itemIds: ['held.a'] };
  const upcoming = { id: 'new-pack', name: 'Neue Rollen', startsAt: new Date(start + 5 * 60 * minute).toISOString(), itemIds: ['future.a'] };
  const { app, clock } = setup(t, [held, upcoming]);
  // Before either starts: the earlier one, the held pack.
  assert.equal(nextDrop(app, +clock.at).id, 'held-pack');
  // The held pack started 2 h ago and still waits; the other starts in 3 h.
  clock.at = new Date(start + 2 * 60 * minute);
  assert.deepEqual(app.runnerWardrobe('sam', { roles: true }).nextDrop, { id: 'new-pack', name: 'Neue Rollen', startsAt: upcoming.startsAt, ready: true });
  // Once that one is live, the held pack is the only one left.
  clock.at = new Date(start + 5 * 60 * minute);
  assert.deepEqual(nextDrop(app, +clock.at), { id: 'held-pack', name: 'Wartende Rollen', startsAt, ready: false });
});

test('a stage drop whose items are missing is not ready, and nothing is held after its start', t => {
  const stage = { id: 'stage', name: 'Neue Bühne', startsAt, gatedItemIds: ['missing.map'] };
  const { app, clock } = setup(t, [stage]);
  assert.equal(nextDrop(app, +clock.at).ready, false);
  clock.at = new Date(start + minute);
  assert.equal(nextDrop(app, +clock.at), null);
});

test('a repeated request answers with the countdown of the moment, which is not stored', t => {
  const { app, store, clock, personId } = setup(t);
  app.runnerWardrobe('sam', { roles: true });
  store.put('runnerProgress', personId, { ...store.get('runnerProgress', personId), gage: 1000 });
  const bought = app.runnerBuy('sam', 'buy-present', { itemId: 'present', roles: true });
  assert.equal(bought.wardrobe.nextDrop.id, 'new-pack');
  const row = store.db.prepare('SELECT result FROM requests WHERE uid=? AND request_id LIKE ?').get('sam', '%buy-present');
  assert.ok(!('nextDrop' in JSON.parse(row.result).wardrobe));
  assert.ok(!('now' in JSON.parse(row.result).wardrobe));
  clock.at = new Date(start);
  const again = app.runnerBuy('sam', 'buy-present', { itemId: 'present', roles: true });
  assert.equal(again.wardrobe.nextDrop, undefined);
  assert.deepEqual(again.item, bought.item);
});
