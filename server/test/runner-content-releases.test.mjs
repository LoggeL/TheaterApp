import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { bundledCatalog, loadCatalog } from '../src/runner-wardrobe.mjs';
import { bundledContentReleases, parseContentReleases } from '../src/runner-content-releases.mjs';

const startsAt = '2026-11-08T17:00:00.000Z';
const fixtures = new URL('./fixtures/wardrobe/', import.meta.url);
const data = {
  roleFigures: true,
  rarities: [{ id: 'blue', name: 'Blau', color: '#0088FF', weight: 1, gage: 10 }],
  ensemble: { every: 2, milestones: [{ km: 1, item: 'future.map', note: 'Secret play' }] },
  items: [
    ...['character', 'backdrop', 'obstacles', 'fx'].map(kind => ({ id: `${kind}.default`, kind, name: 'Default', rarity: 'blue', default: true })),
    { id: 'present', kind: 'character', name: 'Present', role: 'Present', play: 'Present', year: 2025, rarity: 'blue', personId: 901 },
    { id: 'future.a', kind: 'character', name: 'Future A', role: 'A', play: 'Future', year: 2026, rarity: 'blue', personId: 902, variantOf: 'present', image: 'figure.webp' },
    { id: 'future.b', kind: 'character', name: 'Future B', role: 'B', play: 'Future', year: 2026, rarity: 'blue', personId: 903, image: 'figure.webp' },
    { id: 'future.map', kind: 'backdrop', name: 'Secret play', reward: true, image: 'figure.webp' },
    { id: 'free.map', kind: 'backdrop', name: 'Free stage', rarity: 'blue' },
  ],
};
const releases = [{ id: 'new-pack', name: 'Future', startsAt, itemIds: ['future.a', 'future.b'], gatedItemIds: ['future.map'], freeItemIds: ['free.map'], goalMeters: 1000, crateCount: 3 }];
function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const clock = { at: new Date(Date.parse(startsAt) - 1) };
  const options = { bootstrapEmail: 'admin@example.invalid', runnerCatalog: loadCatalog(data, fixtures), runnerReleases: releases, clock: () => clock.at, random: () => 0.9, missionRules: null };
  const app = new Theater(store, options);
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let actionId = 0;
  const member = uid => {
    const personId = app.action('admin', { action: 'member.save', name: uid }, `member-${++actionId}`).id;
    app.session({ uid, name: uid, email: `${uid}@example.invalid`, email_verified: true });
    app.action('admin', { action: 'account.approve', uid, personId, version: 1, role: 'member' }, `approve-${++actionId}`);
    return personId;
  };
  const sam = member('sam'), kim = member('kim'), lee = member('lee');
  const play = (uid, meters) => { const { roundId } = app.runnerStart(uid); clock.at = new Date(+clock.at + 600000); const body = { roundId, score: meters, meters }; return { body, result: app.runnerScore(uid, body) }; };
  return { app, store, clock, options, sam, kim, lee, play };
}

test('catalog changes at the server-time boundary without restart across all access paths', t => {
  const { app, store, clock, sam } = setup(t);
  app.runnerWardrobe('sam');
  store.put('runnerProgress', sam, { ...store.get('runnerProgress', sam), owned: ['future.a'], selected: { character: 'future.a' }, gage: 1000 });
  store.put('runnerEnsemble', 'total', { meters: 1000, reached: { 1: startsAt } });
  const before = app.runnerWardrobe('sam', { roles: true });
  assert.deepEqual(before.packGoals, []);
  assert.equal(before.selected.character, 'character.default');
  assert.ok(!before.owned.includes('future.a'));
  assert.ok(!before.owned.includes('free.map'));
  assert.ok(!JSON.stringify(before).includes('Secret play'));
  assert.ok(!JSON.stringify(before).includes('future.a'));
  assert.ok(!app.runnerCatalog.crateTargets.some(x => x.play === 'Future'));
  assert.equal(app.runnerCatalog.rolesOf.size, 0);
  assert.throws(() => app.runnerSkin('sam', 'figure.webp'), { status: 404 });
  assert.throws(() => app.runnerBuy('sam', 'buy-before', { itemId: 'future.b' }), { status: 404 });
  assert.throws(() => app.runnerOutfit('sam', { kind: 'character', itemId: 'future.a', roles: true }), { status: 404 });
  assert.throws(() => app.runnerOpenCrate('sam', 'target-before', { target: 'play:future', dupes: true, roles: true }), { code: 'unknown_target' });
  const hidden = before.ensemble.milestones[0];
  assert.deepEqual(hidden, { km: 1, name: '???', hidden: true, reward: null, reached: true });
  clock.at = new Date(startsAt);
  const after = app.runnerWardrobe('sam', { roles: true });
  assert.equal(after.packGoals.length, 1);
  assert.equal(after.packGoals[0].meters, 0);
  assert.ok(after.owned.includes('future.a'));
  assert.ok(after.owned.includes('free.map'));
  assert.equal(after.selected.character, 'future.a');
  assert.ok(after.catalog.rewards.some(x => x.id === 'future.map'));
  assert.ok(app.runnerSkin('sam', 'figure.webp').bytes.length > 0);
  assert.ok(app.runnerCatalog.crateTargets.some(x => x.play === 'Future'));
  assert.ok(app.runnerCatalog.rolesOf.has('present'));
});

test('approved runs award three scoped crates once to contributors, across retry and restart', t => {
  const { app, store, clock, options, sam, kim, play } = setup(t);
  clock.at = new Date(startsAt);
  play('sam', 400);
  const { body, result } = play('kim', 600);
  assert.equal(result.progress.packCrates, 3);
  assert.equal(app.runnerScore('kim', body).progress.packGoals[0].meters, 1000);
  assert.equal(app.runnerWardrobe('sam').packGoals[0].crates, 3);
  assert.equal(app.runnerWardrobe('lee').packGoals[0].crates, 0);
  assert.equal(store.get('runnerPackGoals', 'new-pack').meters, 1000);
  assert.throws(() => app.runnerOpenCrate('sam', 'old', { crate: 'pack', packId: 'new-pack', dupes: true }), { status: 400 });
  assert.throws(() => app.runnerOpenCrate('sam', 'redirect', { crate: 'pack', packId: 'new-pack', target: 'random', dupes: true, roles: true }), { code: 'unknown_target' });
  const open = (owner, id) => app.runnerOpenCrate(owner, id, { crate: 'pack', packId: 'new-pack', dupes: true, roles: true });
  const first = open('sam', 'pack-one');
  assert.ok(['future.a', 'future.b'].includes(first.item.id));
  assert.ok(first.reel.every(id => ['future.a', 'future.b'].includes(id)));
  assert.equal(first.outcome.crate, 'pack');
  assert.equal(first.wardrobe.packGoals[0].crates, 2);
  assert.deepEqual(open('sam', 'pack-one'), first);
  const restarted = new Theater(store, options);
  assert.deepEqual(restarted.runnerOpenCrate('sam', 'pack-one', { crate: 'pack', packId: 'new-pack', dupes: true, roles: true }), first);
  open('sam', 'pack-two'); open('sam', 'pack-three');
  assert.throws(() => open('sam', 'pack-four'), { code: 'no_crate' });
  assert.equal(app.runnerWardrobe('kim').packGoals[0].crates, 3);
  assert.equal(store.get('runnerPackContributions', `new-pack:${sam}`).opened, 3);
  assert.equal(store.get('runnerPackContributions', `new-pack:${kim}`).meters, 600);
});

test('a run begun before launch does not count towards the new goal', t => {
  const { app, play } = setup(t);
  const { result } = play('sam', 1000);
  assert.equal(result.progress.packGoals[0].meters, 0);
  assert.equal(result.progress.packCrates, 0);
  assert.equal(app.runnerWardrobe('sam').packGoals[0].contributionMeters, 0);
});

test('a delayed reward celebrates once after release even if a later distance was acknowledged', t => {
  const { app, store, clock, options, sam } = setup(t);
  store.put('runnerEnsemble', 'total', { meters: 3000, reached: { 1: startsAt, 3: startsAt } });
  const before = app.runnerWardrobe('sam');
  assert.deepEqual(before.ensemble.unseen, [3], 'the pending reward is never celebrated as ???');
  const acknowledged = app.runnerEnsembleSeen('sam', { km: 3 });
  assert.deepEqual(acknowledged.ensemble.unseen, []);
  assert.equal(store.get('runnerProgress', sam).ensembleSeen, 3);
  assert.deepEqual(store.get('runnerProgress', sam).ensembleReleaseSeen ?? [], []);
  const crates = acknowledged.ensemble.crates;
  clock.at = new Date(startsAt);
  const revealed = app.runnerWardrobe('sam');
  assert.deepEqual(revealed.ensemble.unseen, [1]);
  assert.equal(revealed.ensemble.milestones[0].name, 'Secret play');
  assert.equal(revealed.ensemble.crates, crates, 'the release does not grant another base crate');
  assert.ok(revealed.owned.includes('future.map'));
  const seen = app.runnerEnsembleSeen('sam', { km: 1 });
  assert.deepEqual(seen.ensemble.unseen, []);
  assert.equal(store.get('runnerProgress', sam).ensembleSeen, 3);
  assert.deepEqual(store.get('runnerProgress', sam).ensembleReleaseSeen, ['future.map']);
  const restarted = new Theater(store, options);
  assert.deepEqual(restarted.runnerWardrobe('sam').ensemble.unseen, []);
});

test('a round started before artwork readiness cannot be credited when artwork arrives mid-run', t => {
  const { app, clock } = setup(t);
  clock.at = new Date(startsAt);
  app.runnerCatalog = loadCatalog({ ...data, items: data.items.map(x => x.id === 'future.b' ? { ...x, disabled: true } : x) }, fixtures);
  const { roundId } = app.runnerStart('sam');
  clock.at = new Date(+clock.at + 600000);
  app.runnerCatalog = loadCatalog(data, fixtures);
  const reply = app.runnerScore('sam', { roundId, score: 1000, meters: 1000 });
  assert.equal(reply.progress.packGoals[0].meters, 0);
  const next = app.runnerStart('sam');
  clock.at = new Date(+clock.at + 600000);
  const counted = app.runnerScore('sam', { roundId: next.roundId, score: 1000, meters: 1000 });
  assert.equal(counted.progress.packGoals[0].meters, 1000);
  assert.equal(counted.progress.packCrates, 3);
});

test('older wardrobe clients remain compatible with the scheduled projection', t => {
  const { app, clock } = setup(t);
  const before = app.runnerWardrobe('sam');
  assert.ok(!JSON.stringify(before).includes('future.a'));
  clock.at = new Date(startsAt);
  const after = app.runnerWardrobe('sam');
  assert.equal(after.catalog.items.find(x => x.id === 'present').variants[0].id, 'future.a');
  assert.equal(after.packGoals[0].releaseId, 'new-pack');
});

test('a partially prepared set stays hidden after its date until every sprite is present', t => {
  const { app, clock } = setup(t);
  clock.at = new Date(startsAt);
  app.runnerCatalog = loadCatalog({ ...data, items: data.items.map(x => x.id === 'future.b' ? { ...x, image: 'missing.webp' } : x) }, fixtures);
  const waiting = app.runnerWardrobe('sam', { roles: true });
  assert.deepEqual(waiting.packGoals, []);
  assert.ok(!waiting.catalog.items.some(x => x.id.startsWith('future.')));
  assert.ok(!waiting.crateTargets.some(x => x.play === 'Future'));
  // A later deployment supplies the full set, without changing the promised launch date.
  app.runnerCatalog = loadCatalog(data, fixtures);
  const ready = app.runnerWardrobe('sam', { roles: true });
  assert.equal(ready.packGoals.length, 1);
  assert.equal(ready.packGoals[0].meters, 0);
  assert.ok(ready.catalog.items.some(x => x.id === 'future.b'));
});

test('a new unique waits for its full scheduled pack instead of unlocking from historical roles alone', t => {
  const { app, clock, store, sam } = setup(t);
  clock.at = new Date(startsAt);
  const unique = { id: 'future.unique', kind: 'character', name: 'Secret puppet', role: 'Puppet', play: 'Future', year: 2026, rarity: 'unique', unlock: { play: 'Future' }, image: 'figure.webp' };
  const oldRole = { id: 'old.future', kind: 'character', name: 'Historical', role: 'Historical', play: 'Future', year: 2026, rarity: 'blue', personId: 904, image: 'figure.webp' };
  const withUnique = { ...data, items: [...data.items, oldRole, unique] };
  app.runnerReleases = parseContentReleases([{ ...releases[0], gatedItemIds: [...releases[0].gatedItemIds, unique.id] }]);
  app.runnerCatalog = loadCatalog({ ...withUnique, items: withUnique.items.map(x => x.id === 'future.b' ? { ...x, disabled: true } : x) }, fixtures);
  app.runnerWardrobe('sam');
  store.put('runnerProgress', sam, { ...store.get('runnerProgress', sam), owned: ['old.future'] });
  const incomplete = app.runnerWardrobe('sam', { roles: true, unique: true });
  assert.ok(!incomplete.owned.includes(unique.id));
  assert.ok(!app.runnerCatalog.byId.has(unique.id));
  assert.ok(!(store.get('runnerProgress', sam).uniques ?? []).includes(unique.id));
  app.runnerCatalog = loadCatalog(withUnique, fixtures);
  assert.ok(!app.runnerWardrobe('sam', { roles: true, unique: true }).owned.includes(unique.id));
  store.put('runnerProgress', sam, { ...store.get('runnerProgress', sam), owned: ['old.future', 'future.a', 'future.b'] });
  assert.ok(app.runnerWardrobe('sam', { roles: true, unique: true }).owned.includes(unique.id));
});

test('bundled manifest pins the approved Berlin dates and known role pools', () => {
  const releases = bundledContentReleases(), c = bundledCatalog();
  assert.deepEqual(releases.slice(0, 4).map(x => [x.id, x.startsAt]), [
    ['halloween-2026', '2026-10-30T17:00:00.000Z'], ['hell-2026', '2026-11-08T17:00:00.000Z'],
    ['advent-2026', '2026-11-29T17:00:00.000Z'], ['romeo-julia-2026', '2026-12-30T17:00:00.000Z'],
  ]);
  assert.equal(releases.find(x => x.id === 'hell-2026').itemIds.length, 11);
  assert.equal(releases.find(x => x.id === 'romeo-julia-2026').itemIds.length, 9);
  assert.ok(c.byId.has('backdrop.creepshow'));
  assert.throws(() => parseContentReleases([{ id: 'bad', name: 'Bad', startsAt: '2026-11-08' }]), /Invalid/);
  assert.throws(() => parseContentReleases([releases[1], { ...releases[1], id: 'duplicate-pool' }]), /scheduled twice/);
});
