import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures, stageRunner, runnerMaxMeters } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { bundledCatalog, crateMilestone, cratesEarned, drawItem, loadCatalog, runnerObstacleKinds, runnerUnlocks, weightedPick } from '../src/runner-wardrobe.mjs';

const rarities = [
  { id: 'blau', name: 'Blau', color: '#4B69FF', weight: 100 },
  { id: 'gold', name: 'Gold', color: '#E4AE39', weight: 1 },
];
const defaults = [
  { id: 'c0', kind: 'character', name: 'Engel Logge', rarity: 'blau', default: true },
  { id: 'b0', kind: 'backdrop', name: 'Wand', rarity: 'blau', default: true },
  { id: 'o0', kind: 'obstacles', name: 'Lager', rarity: 'blau', default: true },
  { id: 'f0', kind: 'fx', name: 'Ohne', rarity: 'blau', default: true },
];
const catalogOf = (items, extra = {}) => loadCatalog({ rarities, departments: [{ id: 'licht', name: 'Licht' }], items: [...defaults, ...items], ...extra });


function setup(t, { items = [{ id: 'c1', kind: 'character', name: 'Blau 1', rarity: 'blau' }, { id: 'c2', kind: 'character', name: 'Gold 1', rarity: 'gold' }, { id: 'f1', kind: 'fx', name: 'Funken', rarity: 'blau', department: 'licht' }], random = Math.random } = {}) {
  const store = new Store(); t.after(() => store.close());
  const clock = { now: new Date('2026-10-18T10:00:00Z') };
  const tick = (ms = 60000) => { clock.now = new Date(+clock.now + ms); };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.now, runnerCatalog: catalogOf(items), random: () => random(), missionRules: null });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let n = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `wardrobe-${++n}`);
  const personId = action({ action: 'member.save', name: 'Sam Beispiel' }).id;
  app.session({ uid: 'sam', name: 'Sam', email: 'sam@example.invalid', email_verified: true });
  action({ action: 'account.approve', uid: 'sam', personId, version: 1, role: 'member' });
  /** A run of [ms] with the given body fields. */
  const play = (body, ms = 600000, uid = 'sam') => { const { roundId } = app.runnerStart(uid); tick(ms); return app.runnerScore(uid, { roundId, ...body }); };
  /** Gives the caller [meters] more without playing. */
  const grant = meters => { const p = app.runnerWardrobe('sam') && store.get('runnerProgress', personId); store.put('runnerProgress', personId, { ...p, meters: p.meters + meters }); };
  let key = 0;
  const open = (uid = 'sam', id = `k${++key}`) => app.runnerOpenCrate(uid, id);
  return { store, app, action, personId, tick, play, grant, open };
}

test('servers announce the wardrobe', t => {
  const { app } = setup(t);
  assert.ok(apiFeatures.includes('runnerUnlocks'));
  assert.ok(app.snapshot('sam').capabilities.features.includes('runnerUnlocks'));
});

test('crates come at linearly growing distances', () => {
  assert.deepEqual([1, 2, 3, 4].map(crateMilestone), [2000, 4100, 6300, 8600]);
  for (let n = 1; n < 40; n++) {
    assert.equal(crateMilestone(n) - crateMilestone(n - 1), runnerUnlocks.firstMeters + runnerUnlocks.stepMeters * (n - 1));
    assert.equal(cratesEarned(crateMilestone(n)), n);
    assert.equal(cratesEarned(crateMilestone(n) - 1), n - 1);
  }
  assert.equal(cratesEarned(0), 0);
  assert.equal(cratesEarned(-5), 0);
  // Not too steep: 100 km bring 29 crates; the 30th is 4900 m further.
  assert.equal(cratesEarned(100000), 29);
  assert.equal(crateMilestone(30) - crateMilestone(29), 4900);
});

test('runs add their metres; the reply tells how far the next crate is', t => {
  const { app, play } = setup(t);
  // The first run of the day counts twice for the crates (Tagesbonus).
  const first = play({ score: 1500, meters: 700 });
  assert.deepEqual(first.progress, { meters: 1400, earned: 0, opened: 0, crates: 0, previousAt: 0, nextAt: 2000, poolSize: 3, complete: false, ensembleCrates: 0, dupes: true, runMeters: 700, bonusMeters: 700, bonusOpen: false, missionMeters: 0, missionCrates: 0, eventCrates: 0, gained: 700, bonus: 700, missionBonus: 0, newCrates: 0 });
  const second = play({ score: 1200, meters: 900 });
  assert.equal(second.progress.meters, 2300);
  assert.equal(second.progress.bonus, 0);
  assert.equal(second.progress.newCrates, 1);
  assert.equal(second.progress.crates, 1);
  assert.equal(second.progress.nextAt, 4100);
  assert.equal(app.runnerWardrobe('sam').progress.crates, 1);
});

test('metres must fit the score and the measured time', t => {
  const { app, tick, play } = setup(t);
  for (const meters of [-1, 1.5, '20', 101]) {
    const { roundId } = app.runnerStart('sam'); tick(60000);
    assert.throws(() => app.runnerScore('sam', { roundId, score: 100, meters }), { status: 400, code: 'implausible' }, String(meters));
  }
  // Metres above what the speed curve allows, even if the score would fit.
  const { roundId } = app.runnerStart('sam'); tick(10000);
  const limit = Math.floor(runnerMaxMeters(10 + stageRunner.slackSeconds) * stageRunner.tolerance);
  assert.throws(() => app.runnerScore('sam', { roundId, score: limit + 1, meters: limit + 1 }), { status: 400, code: 'implausible' });
  assert.equal(app.runnerScore('sam', { roundId, score: limit, meters: limit }).progress.gained, limit);
  assert.equal(play({ score: 0, meters: 0 }).progress.gained, 0);
});

test('older clients without metres get a conservative estimate', t => {
  const { play } = setup(t);
  // Plenty of time: the score bounds it.
  assert.equal(play({ score: 1000 }, 600000).progress.gained, Math.floor(1000 * runnerUnlocks.legacyMetersFactor));
  // Little time: what the speed curve allows bounds it.
  assert.equal(play({ score: 300 }, 10000).progress.gained, Math.floor(runnerMaxMeters(10) * runnerUnlocks.legacyMetersFactor));
});

test('earlier runs are credited once, on first use', t => {
  const { app, store, personId, play } = setup(t);
  store.put('runnerScores', personId, { personId, best: 500, bestAt: null, rounds: 14, lastPlayedAt: null });
  const result = play({ score: 400, meters: 300 });
  // The credit is no run: it brings no Tagesbonus, the run after it does.
  assert.equal(result.progress.runMeters, 14 * runnerUnlocks.creditPerRound + 300);
  assert.equal(result.progress.meters, 14 * runnerUnlocks.creditPerRound + 300 + 300);
  assert.equal(store.get('runnerScores', personId).rounds, 15);
  // Neither another run nor reading credits again.
  assert.equal(app.runnerWardrobe('sam').progress.runMeters, 14 * 150 + 300);
  assert.equal(play({ score: 10, meters: 10 }).progress.runMeters, 14 * 150 + 310);
  // Someone without earlier runs starts at zero.
  const fresh = setup(t);
  assert.equal(fresh.app.runnerWardrobe('sam').progress.meters, 0);
});

test('crates hold items one does not own, never twice; then the wardrobe is complete', t => {
  const { app, grant, open } = setup(t);
  assert.throws(() => open(), { status: 409, code: 'no_crate' });
  grant(crateMilestone(5));
  const won = new Set();
  for (let i = 0; i < 3; i++) {
    const result = open();
    assert.ok(!won.has(result.item.id), 'no duplicates');
    assert.ok(!['c0', 'b0', 'o0', 'f0'].includes(result.item.id), 'defaults are not in crates');
    won.add(result.item.id);
    assert.equal(result.reel[result.winnerIndex], result.item.id);
    assert.equal(result.reel.length, runnerUnlocks.reelLength);
    assert.ok(result.reel.every(id => ['c1', 'c2', 'f1'].includes(id)));
  }
  const view = app.runnerWardrobe('sam');
  assert.deepEqual(new Set(view.owned), new Set(['c0', 'b0', 'o0', 'f0', 'c1', 'c2', 'f1']));
  assert.deepEqual([view.progress.crates, view.progress.complete, view.progress.poolSize], [2, true, 0]);
  // Crates pile up until new items arrive.
  assert.throws(() => open(), { status: 409, code: 'wardrobe_complete' });
  assert.equal(app.runnerWardrobe('sam').progress.crates, 2);
  app.runnerCatalog = catalogOf([{ id: 'c1', kind: 'character', name: 'Blau 1', rarity: 'blau' }, { id: 'c2', kind: 'character', name: 'Gold 1', rarity: 'gold' }, { id: 'f1', kind: 'fx', name: 'Funken', rarity: 'blau' }, { id: 'b9', kind: 'backdrop', name: 'Neu', rarity: 'gold' }]);
  assert.equal(open().item.id, 'b9');
  assert.equal(app.runnerWardrobe('sam').progress.crates, 1);
});

test('the draw follows the rarity weights', () => {
  const items = [{ id: 'a', weight: 100 }, { id: 'b', weight: 10 }, { id: 'c', weight: 1 }];
  // Exact edges: [0, 100) a, [100, 110) b, [110, 111) c.
  assert.equal(weightedPick(items, () => 99.9 / 111).id, 'a');
  assert.equal(weightedPick(items, () => 100.5 / 111).id, 'b');
  assert.equal(weightedPick(items, () => 110.5 / 111).id, 'c');
  let seed = 7;
  const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  const counts = { a: 0, b: 0, c: 0 };
  for (let i = 0; i < 111000; i++) counts[weightedPick(items, random).id]++;
  assert.ok(Math.abs(counts.a / 100000 - 1) < 0.03, JSON.stringify(counts));
  assert.ok(Math.abs(counts.b / 10000 - 1) < 0.08, JSON.stringify(counts));
  assert.ok(Math.abs(counts.c / 1000 - 1) < 0.25, JSON.stringify(counts));
});

test('a crate draws a rarity first, then one of its items; used-up rarities pass on their chance', () => {
  const c = catalogOf([
    { id: 'b1', kind: 'character', name: 'B1', rarity: 'blau' }, { id: 'b2', kind: 'fx', name: 'B2', rarity: 'blau' },
    { id: 'b3', kind: 'fx', name: 'B3', rarity: 'blau' }, { id: 'g1', kind: 'character', name: 'G1', rarity: 'gold' },
  ]);
  const items = c.items.filter(x => !x.default);
  let seed = 11;
  const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  const counts = {};
  for (let i = 0; i < 101000; i++) { const id = drawItem(c, items, random).id; counts[id] = (counts[id] ?? 0) + 1; }
  // Gold 1 of 101 however many blue items there are; the blue ones share the rest evenly.
  assert.ok(Math.abs(counts.g1 / 1000 - 1) < 0.2, JSON.stringify(counts));
  for (const id of ['b1', 'b2', 'b3']) assert.ok(Math.abs(counts[id] / 33333 - 1) < 0.05, JSON.stringify(counts));
  // Without blue items left, gold is certain.
  assert.equal(drawItem(c, items.filter(x => x.rarity === 'gold'), () => 0).id, 'g1');
});

test('the drawn crate only uses the items not yet owned', t => {
  // Rarities blau 100, gold 1; items c1 (blau), c2 (gold), f1 (blau). The reel uses the same numbers.
  const dice = { value: 0 };
  const { grant, open } = setup(t, { random: () => dice.value });
  grant(crateMilestone(3));
  dice.value = 100.5 / 101;
  assert.equal(open().item.id, 'c2');
  // Gold is used up: the same number now picks blue, and its last item of two.
  assert.equal(open().item.id, 'f1');
  assert.equal(open().item.id, 'c1');
});

test('limits turn scores into rarities; hybrids belong to each of theirs', () => {
  const c = loadCatalog({
    rarities: [{ id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 45, minScore: 0 }, { id: 'tech', name: 'Technik', color: '#2FBF71', weight: 14 }, { id: 'gold', name: 'Gold', color: '#E4AE39', weight: 1.5, minScore: 74 }],
    items: [...defaults.map(x => ({ ...x, rarity: 'hell' })),
      { id: 'a', kind: 'character', name: 'A', score: 82.7 }, { id: 'b', kind: 'character', name: 'B', score: 73.9 },
      { id: 'm', kind: 'character', name: 'Maren', rarity: 'tech', score: 15.4, label: 'Bühnentechnik · Ensemble' },
      { id: 'h', kind: 'character', name: 'H', rarities: ['hell', 'gold'] }],
  });
  assert.deepEqual(['a', 'b', 'm', 'h'].map(id => c.byId.get(id).rarities), [['gold'], ['hell'], ['tech', 'hell'], ['gold', 'hell']]);
  assert.equal(c.byId.get('m').rarity, 'tech', 'the rarest one is the main colour');
  assert.equal(c.byId.get('m').label, 'Bühnentechnik · Ensemble');
  // A hybrid is drawn through either rarity.
  const items = [c.byId.get('m')];
  assert.equal(drawItem(c, items, () => 0).id, 'm');
  assert.equal(drawItem(c, items, () => 0.99).id, 'm');
});

test('a hybrid comes through both rarities but only once', t => {
  const dice = { value: 0 };
  const { app, grant, open } = setup(t, { items: [{ id: 'm', kind: 'character', name: 'Maren', rarities: ['blau', 'gold'] }, { id: 'c1', kind: 'character', name: 'Blau 1', rarity: 'blau' }, { id: 'g1', kind: 'fx', name: 'Gold 1', rarity: 'gold' }], random: () => dice.value });
  grant(crateMilestone(4));
  // Gold (the last 1 of 101), then the first gold item: the hybrid.
  dice.value = 0.999;
  const won = [open().item.id];
  // Gold again: only g1 is left in it; blue: only c1.
  won.push(open().item.id);
  dice.value = 0;
  won.push(open().item.id);
  assert.deepEqual(won.sort(), ['c1', 'g1', 'm']);
  assert.throws(() => open(), { status: 409, code: 'wardrobe_complete' });
  assert.equal(app.runnerWardrobe('sam').owned.filter(id => id === 'm').length, 1);
});

test('a hybrid with an exclusive rarity is drawn only through it', () => {
  const c = loadCatalog({
    rarities: [{ id: 'blau', name: 'Blau', color: '#4B69FF', weight: 100 }, { id: 'tech', name: 'Technik', color: '#2FBF71', weight: 14 }, { id: 'gold', name: 'Gold', color: '#E4AE39', weight: 1.5, minScore: 68, exclusive: true }],
    items: [...defaults, { id: 'jonas', kind: 'character', name: 'Jonas', rarity: 'tech', score: 69.9, label: 'Lichttechnik · Darsteller' }, { id: 't', kind: 'character', name: 'T', rarity: 'tech' }, { id: 'b', kind: 'fx', name: 'B', rarity: 'blau' }],
  });
  const jonas = c.byId.get('jonas');
  assert.deepEqual(jonas.rarities, ['gold', 'tech'], 'both colours for the card');
  assert.equal(JSON.parse(JSON.stringify(jonas)).drawnBy, undefined);
  const items = c.items.filter(x => !x.default);
  let seed = 5;
  const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  let hits = 0;
  const runs = 115500;
  for (let i = 0; i < runs; i++) if (drawItem(c, items, random).id === 'jonas') hits++;
  // Only gold's 1.5 of 115.5, not technik's share on top.
  assert.ok(Math.abs(hits / (runs * 1.5 / 115.5) - 1) < 0.15, String(hits));
  // Technik alone never brings him.
  assert.ok(Array.from({ length: 50 }, (_, i) => drawItem(c, [jonas, c.byId.get('t')], () => i / 50 * (14 / 15.5))).every(x => x.id === 't'));
});

test('legacy joins the draw once all light blue characters are owned', t => {
  const items = [
    { id: 'h1', kind: 'character', name: 'Hell 1', rarity: 'blau' },
    { id: 'hy', kind: 'character', name: 'Hybrid', rarities: ['gold', 'blau'] },
    { id: 'bd', kind: 'backdrop', name: 'Blaue Wand', rarity: 'blau' },
    { id: 'l1', kind: 'character', name: 'Anton', rarity: 'legacy' },
  ];
  const store = new Store(); t.after(() => store.close());
  const c = loadCatalog({ rarities: [...rarities, { id: 'legacy', name: 'Legacy', color: '#A47A4B', weight: 8, style: 'antique', requires: { rarity: 'blau', kind: 'character' }, hint: 'Sammle alle hellblauen Figuren' }], items: [...defaults, ...items] });
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', runnerCatalog: c, random: () => 0.999 });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  const p = app.runnerWardrobe('admin').progress && store.get('runnerProgress', app.account('admin').personId);
  store.put('runnerProgress', p.personId, { ...p, meters: crateMilestone(4) });
  let view = app.runnerWardrobe('admin');
  assert.deepEqual(view.lockedRarities, ['legacy']);
  assert.equal(view.catalog.rarities.find(r => r.id === 'legacy').hint, 'Sammle alle hellblauen Figuren');
  assert.equal(view.progress.poolSize, 3);
  // Always the rarest open rarity and the last of its items: gold (the hybrid), then blue.
  const draw = key => { const result = app.runnerOpenCrate('admin', key); assert.ok(!result.reel.includes('l1'), 'locked items are not teased'); return result.item.id; };
  assert.equal(draw('a'), 'hy');
  assert.equal(draw('b'), 'bd');
  // The blue backdrop is no character and does not count; h1 is still missing.
  assert.deepEqual(app.runnerWardrobe('admin').lockedRarities, ['legacy']);
  assert.equal(draw('c'), 'h1');
  // All blue characters, the hybrid among them: legacy is open.
  assert.deepEqual(app.runnerWardrobe('admin').lockedRarities, []);
  assert.equal(app.runnerOpenCrate('admin', 'd').item.id, 'l1');
});

test('opening again with the same key returns the same crate', t => {
  const { app, grant, open } = setup(t);
  grant(crateMilestone(2));
  const first = open('sam', 'same');
  assert.deepEqual(open('sam', 'same'), first);
  assert.equal(app.runnerWardrobe('sam').progress.opened, 1);
  assert.throws(() => app.runnerOpenCrate('sam', ''), { status: 400 });
});

test('only owned items can be worn; the own character is owned', t => {
  const { app, personId, grant, open } = setup(t);
  assert.deepEqual(app.runnerWardrobe('sam').selected, { character: 'c0', backdrop: 'b0', obstacles: 'o0', fx: 'f0' });
  assert.throws(() => app.runnerOutfit('sam', { kind: 'character', itemId: 'c1' }), { status: 409, code: 'not_owned' });
  assert.throws(() => app.runnerOutfit('sam', { kind: 'fx', itemId: 'c1' }), { status: 404 });
  assert.throws(() => app.runnerOutfit('sam', { kind: 'hat', itemId: 'c1' }), { status: 400 });
  assert.throws(() => app.runnerOutfit('sam', { kind: 'character', itemId: 'nope' }), { status: 404 });
  grant(crateMilestone(1));
  const won = open().item;
  assert.equal(app.runnerOutfit('sam', { kind: won.kind, itemId: won.id }).selected[won.kind], won.id);
  // Back to the default is always possible.
  assert.equal(app.runnerOutfit('sam', { kind: 'character', itemId: 'c0' }).selected.character, 'c0');
  // A person's own character needs no crate and is not drawn for them.
  app.runnerCatalog = catalogOf([{ id: 'c1', kind: 'character', name: 'Blau 1', rarity: 'blau' }, { id: 'sam', kind: 'character', name: 'Sam', rarity: 'gold', personId }]);
  const view = app.runnerWardrobe('sam');
  assert.ok(view.owned.includes('sam'));
  assert.equal(app.runnerOutfit('sam', { kind: 'character', itemId: 'sam' }).selected.character, 'sam');
  // An item that left the catalog falls back to the default.
  app.runnerCatalog = catalogOf([]);
  assert.equal(app.runnerWardrobe('sam').selected.character, 'c0');
});

test('runs count how they ended; earlier runs stay apart', t => {
  const { app, store, personId, play } = setup(t);
  store.put('runnerScores', personId, { personId, best: 50, bestAt: null, rounds: 4, lastPlayedAt: null });
  play({ score: 10, meters: 10, hitBy: 'crate' });
  play({ score: 10, meters: 10, hitBy: 'lamp' });
  play({ score: 10, meters: 10, hitBy: 'crate' });
  play({ score: 10, meters: 10, hitBy: 'dragon' });
  play({ score: 10, meters: 10 });
  const { stats } = app.runnerWardrobe('sam');
  assert.deepEqual(stats.deaths, [{ kind: 'crate', count: 2 }, { kind: 'lamp', count: 1 }]);
  assert.equal(stats.unknown, 2);
  assert.equal(stats.untracked, 4);
  assert.equal(stats.rounds, 9);
  assert.equal(stats.best, 50);
  assert.equal(stats.meters, 4 * 150 + 50);
  assert.ok(runnerObstacleKinds.includes('drop') && runnerObstacleKinds.length === 9);
});

/** Width and height of a PNG or WebP (lossy, lossless or extended) from its header. */
function pictureSize(bytes) {
  const text = (at, n) => bytes.subarray(at, at + n).toString('latin1');
  if (text(1, 3) === 'PNG') return [bytes.readUInt32BE(16), bytes.readUInt32BE(20)];
  assert.equal(text(0, 4) + text(8, 4), 'RIFFWEBP');
  const chunk = text(12, 4);
  if (chunk === 'VP8 ') return [bytes.readUInt16LE(26) & 0x3fff, bytes.readUInt16LE(28) & 0x3fff];
  if (chunk === 'VP8L') { const b = bytes.readUInt32LE(21); return [(b & 0x3fff) + 1, ((b >> 14) & 0x3fff) + 1]; }
  if (chunk === 'VP8X') return [bytes.readUIntLE(24, 3) + 1, bytes.readUIntLE(27, 3) + 1];
  throw new Error(`unknown WebP chunk ${chunk}`);
}

test('the bundled catalog is valid and ships only finished costumes', () => {
  const c = bundledCatalog();
  for (const kind of ['character', 'backdrop', 'fx']) assert.ok(c.items.some(x => x.kind === kind && !x.default), kind);
  // Tinted stand-ins would look cheap: what can be drawn has its own picture, effects are drawn in code.
  const drawable = c.items.filter(x => !x.default);
  assert.deepEqual(drawable.filter(x => x.placeholder).map(x => x.id), []);
  assert.ok(drawable.filter(x => x.kind !== 'fx').every(x => x.image), 'every costume has its picture');
  assert.ok(drawable.filter(x => x.kind === 'character').every(x => x.portrait && x.harness), 'characters have a portrait and their wire points');
  // Role figures: every role is an item of its own, none carries variants any more.
  assert.equal(c.roleFigures, true);
  assert.deepEqual(c.items.filter(x => x.variants).map(x => x.id), []);
  assert.ok(drawable.filter(x => x.kind === 'fx').every(x => x.effect?.colors.length));
  assert.equal(c.byId.get('backdrop.creepshow').kind, 'backdrop');
  // Every stage set brings obstacles to match and the colour of its border; obstacle sets are no
  // costume of their own, so that kind keeps only its default.
  assert.ok(drawable.filter(x => x.kind === 'backdrop').every(x => x.obstacles && /^#[0-9A-F]{6}$/i.test(x.borderColor)), 'backdrops have obstacles and a border colour');
  assert.ok(drawable.filter(x => x.kind === 'backdrop').every(x => x.collectibles && ['rose', 'mask', 'star'].every(k => x.collectibleNames?.[k])), 'backdrops have collectibles with names');
  assert.deepEqual(c.items.filter(x => x.kind === 'obstacles').map(x => x.id), ['obstacles.standard']);
  assert.equal(c.rarities.at(-1).id, 'gold');
  assert.ok(c.rarities.some(r => r.id === 'technik'));
  assert.ok(c.items.every(x => (x.departments ?? []).every(id => c.departments.some(d => d.id === id))));
  // People's characters belong to them; unique figures (never drawn) to nobody.
  assert.ok(drawable.filter(x => x.kind === 'character' && !x.unique).every(x => Number.isInteger(x.personId)));
  assert.ok(c.uniques.every(x => x.personId === undefined && !c.collectible.includes(x)));
});

test('the bundled pictures have the sizes the app accepts', () => {
  const c = bundledCatalog(), sizes = { character: [1124, 577], obstacles: [1124, 577], backdrop: [1024, 603] };
  const named = new Set();
  // Role figures are characters like any other: same atlas, same square portrait.
  const pictured = c.items;
  for (const x of pictured) {
    const file = path => path && decodeURIComponent(path.slice(path.lastIndexOf('/') + 1).split('?')[0]);
    if (x.image) {
      named.add(file(x.image));
      assert.deepEqual(pictureSize(c.files.get(file(x.image)).bytes), sizes[x.kind], x.image);
    }
    if (x.portrait) {
      named.add(file(x.portrait));
      const [w, h] = pictureSize(c.files.get(file(x.portrait)).bytes);
      assert.ok(w === h && w >= 256, `${x.portrait} is square`);
    }
    // A backdrop's own obstacle set is an atlas like the obstacles' one.
    if (x.obstacles) {
      named.add(file(x.obstacles));
      assert.deepEqual(pictureSize(c.files.get(file(x.obstacles)).bytes), sizes.obstacles, x.obstacles);
    }
    // So are its collectibles.
    if (x.collectibles) {
      named.add(file(x.collectibles));
      assert.deepEqual(pictureSize(c.files.get(file(x.collectibles)).bytes), sizes.obstacles, x.collectibles);
    }
  }
  // Every picture in the folder is used, and together they stay light. Disabled entries keep their
  // pictures so they can simply be switched on again.
  const folder = new URL('../src/wardrobe/images/', import.meta.url);
  const parked = JSON.parse(readFileSync(new URL('../src/wardrobe/catalog.json', import.meta.url))).items
    .filter(x => x.disabled === true).flatMap(x => [x.image, x.portrait]).filter(Boolean);
  assert.deepEqual(readdirSync(folder).filter(f => !named.has(f) && !parked.includes(f)), []);
  const bytes = [...c.files.values()].filter(f => f.mime.startsWith('image/')).reduce((sum, f) => sum + f.bytes.length, 0);
  // 0.11.2: 159 pictures in use (42 characters, 34 role variants, 7 backdrops) were about 16 MB;
  // with role figures the same pictures plus Raphael's Hades; with Nexus (24 figures) about 19.4 MB.
  // 40 MB leaves room for further plays: the app loads only the pictures a player needs, one by one
  // when it shows or wears them, never the whole folder; the limits per file above stay.
  assert.ok(bytes < 40e6, `${bytes} bytes of pictures`);
});

test('every backdrop brings its own music, as light AAC in M4A', () => {
  const c = bundledCatalog();
  const file = path => decodeURIComponent(path.slice(path.lastIndexOf('/') + 1).split('?')[0]);
  const backdrops = c.items.filter(x => x.kind === 'backdrop');
  assert.deepEqual(backdrops.filter(x => !x.music).map(x => x.id), [], 'every backdrop, the default one too, has music');
  const named = new Set(backdrops.map(x => file(x.music)));
  for (const name of named) {
    const { bytes, mime } = c.files.get(name);
    assert.equal(mime, 'audio/mp4', name);
    // An MP4 file starts with its `ftyp` box; M4A is AAC in it.
    assert.equal(bytes.subarray(4, 8).toString('latin1'), 'ftyp', name);
    // About 60–100 s at 96 kbit/s: the app loads the worn backdrop's music before a run.
    assert.ok(bytes.length < 1.5e6, `${name} has ${bytes.length} bytes`);
  }
  // Every file in the folder is used.
  assert.deepEqual(readdirSync(new URL('../src/wardrobe/music/', import.meta.url)).filter(f => !named.has(f)), []);
});

test('a backdrop names its music, served like the pictures with its own type', async t => {
  const dir = new URL('./fixtures/wardrobe/', import.meta.url);
  const catalog = loadCatalog({ rarities, items: [...defaults,
    { id: 'b1', kind: 'backdrop', name: 'Gruft', rarity: 'blau', music: 'tune.m4a' },
    { id: 'b2', kind: 'backdrop', name: 'Still', rarity: 'blau', music: 'missing.m4a' }] }, dir);
  const music = catalog.byId.get('b1').music;
  assert.match(music, /^\/games\/runner\/skins\/tune\.m4a\?v=[0-9a-f]{16}$/);
  assert.equal(catalog.byId.get('b2').music, undefined, 'a missing file is left out');
  // Pictures and music each keep to their own folder and file types.
  assert.equal(loadCatalog({ rarities, items: [...defaults, { id: 'b1', kind: 'backdrop', name: 'Gruft', rarity: 'blau', music: 'tune.m4a' }] }, dir, null).byId.get('b1').music, undefined);
  assert.throws(() => catalogOf([{ id: 'x', kind: 'fx', name: 'X', rarity: 'blau', music: 'tune.m4a' }]), /music of x/);
  assert.throws(() => catalogOf([{ id: 'x', kind: 'backdrop', name: 'X', rarity: 'blau', music: 'tune.wav' }]), /invalid file name/);
  assert.throws(() => catalogOf([{ id: 'x', kind: 'backdrop', name: 'X', rarity: 'blau', music: '../catalog.m4a' }]), /invalid file name/);
  assert.throws(() => catalogOf([{ id: 'x', kind: 'backdrop', name: 'X', rarity: 'blau', image: 'tune.m4a' }]), /invalid file name/);
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', runnerCatalog: catalog });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  const view = app.runnerWardrobe('admin');
  assert.equal(view.catalog.items.find(x => x.id === 'b1').music, music);
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const response = await fetch(`http://127.0.0.1:${server.address().port}/api/mobile/v1${music}`, { headers: { Authorization: 'Bearer admin' } });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type'), 'audio/mp4');
  assert.match(response.headers.get('cache-control'), /immutable/);
  assert.equal((await response.arrayBuffer()).byteLength, catalog.files.get('tune.m4a').bytes.length);
});

test('disabled entries are left out until their picture is done', () => {
  const c = catalogOf([
    { id: 'c1', kind: 'character', name: 'Fertig', rarity: 'blau' },
    { id: 'c2', kind: 'character', name: 'Wartet', rarity: 'gold', disabled: true },
  ]);
  assert.deepEqual(c.items.filter(x => !x.default).map(x => x.id), ['c1']);
  assert.equal(c.byId.has('c2'), false);
  assert.throws(() => loadCatalog({ rarities, items: [{ ...defaults[0], disabled: true }, ...defaults.slice(1)] }), /default character/);
});

test('a disabled costume is neither drawn nor worn, even if owned before', t => {
  const { app, store, personId, grant, open } = setup(t, { items: [
    { id: 'c1', kind: 'character', name: 'Fertig', rarity: 'blau' },
    { id: 'c2', kind: 'character', name: 'Wartet', rarity: 'gold', disabled: true },
  ] });
  grant(crateMilestone(1));
  assert.equal(open().item.id, 'c1');
  grant(crateMilestone(2));
  assert.throws(() => open(), /komplett/);
  // Owned and worn while it was still in the catalog: falls back to the default.
  const p = store.get('runnerProgress', personId);
  store.put('runnerProgress', personId, { ...p, owned: [...p.owned, 'c2'], selected: { character: 'c2' } });
  const w = app.runnerWardrobe('sam');
  assert.equal(w.selected.character, 'c0');
  assert.ok(!w.owned.includes('c2'));
  assert.ok(!w.catalog.items.some(x => x.id === 'c2'));
});

test('broken catalogs are refused at start', () => {
  assert.throws(() => catalogOf([{ id: 'x', kind: 'hat', name: 'X', rarity: 'blau' }]), /unknown kind/);
  assert.throws(() => catalogOf([{ id: 'x', kind: 'fx', name: 'X', rarity: 'rot' }]), /unknown rarity/);
  assert.throws(() => catalogOf([{ id: 'x', kind: 'fx', name: 'X', rarity: 'blau', department: 'zirkus' }]), /unknown department/);
  assert.throws(() => catalogOf([{ id: 'c0', kind: 'fx', name: 'X', rarity: 'blau' }]), /duplicate/);
  assert.throws(() => catalogOf([{ id: 'x', kind: 'fx', name: 'X', rarity: 'blau', image: '../secret.webp' }]), /file name/);
  assert.throws(() => loadCatalog({ rarities, items: defaults.slice(1) }), /default character/);
});

test('pictures come from the catalog folder, only to members, with their hash', async t => {
  const dir = new URL('./fixtures/wardrobe/', import.meta.url);
  const catalog = loadCatalog({ rarities, items: [...defaults, { id: 'c1', kind: 'character', name: 'Bild', rarity: 'blau', image: 'figure.webp', portrait: 'missing.png', harness: { fly: [100, 40], cheer: [44, 70] } }] }, dir);
  const item = catalog.byId.get('c1');
  assert.match(item.image, /^\/games\/runner\/skins\/figure\.webp\?v=[0-9a-f]{16}$/);
  assert.equal(item.portrait, undefined, 'a missing picture is left out');
  assert.deepEqual(item.harness, { fly: [100, 40], cheer: [44, 70] });
  assert.throws(() => loadCatalog({ rarities, items: [...defaults, { id: 'x', kind: 'character', name: 'X', rarity: 'blau', harness: { wing: [1, 2] } }] }), /harness/);
  // A backdrop's obstacle set and border colour; a missing set is left out like any picture.
  const stage = loadCatalog({ rarities, items: [...defaults,
    { id: 'b1', kind: 'backdrop', name: 'Gruft', rarity: 'blau', obstacles: 'figure.webp', borderColor: '#3E2A5C', collectibles: 'figure.webp', collectibleNames: { rose: 'Bonbon', star: 'Mond' } },
    { id: 'b2', kind: 'backdrop', name: 'Leer', rarity: 'blau', obstacles: 'missing.webp' }] }, dir);
  assert.match(stage.byId.get('b1').obstacles, /^\/games\/runner\/skins\/figure\.webp\?v=[0-9a-f]{16}$/);
  assert.equal(stage.byId.get('b1').borderColor, '#3E2A5C');
  assert.match(stage.byId.get('b1').collectibles, /^\/games\/runner\/skins\/figure\.webp\?v=/);
  assert.deepEqual(stage.byId.get('b1').collectibleNames, { rose: 'Bonbon', star: 'Mond' });
  assert.throws(() => catalogOf([{ id: 'x', kind: 'backdrop', name: 'X', rarity: 'blau', collectibleNames: { coin: 'Münze' } }]), /collectibleNames of x/);
  assert.throws(() => catalogOf([{ id: 'x', kind: 'fx', name: 'X', rarity: 'blau', collectibles: 'figure.webp' }]), /collectibles of x/);
  assert.equal(stage.byId.get('b2').obstacles, undefined);
  assert.equal(stage.collectible.some(x => x.kind === 'obstacles'), false, 'an obstacle set is never drawn');
  assert.throws(() => catalogOf([{ id: 'x', kind: 'fx', name: 'X', rarity: 'blau', obstacles: 'figure.webp' }]), /obstacles of x/);
  assert.throws(() => catalogOf([{ id: 'x', kind: 'backdrop', name: 'X', rarity: 'blau', borderColor: 'red' }]), /borderColor of x/);
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', runnerCatalog: catalog });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  app.session({ uid: 'pending', name: 'Neu', email: 'pending@example.invalid', email_verified: true });
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  const get = (uid, path) => fetch(`${base}${path}`, { headers: { Authorization: `Bearer ${uid}` } });
  const response = await get('admin', `${item.image}`);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get('content-type'), 'image/webp');
  assert.match(response.headers.get('cache-control'), /immutable/);
  assert.equal((await response.arrayBuffer()).byteLength, catalog.files.get('figure.webp').bytes.length);
  assert.equal((await get('admin', '/games/runner/skins/figure.webp')).headers.get('cache-control'), 'private, no-cache');
  assert.equal((await get('admin', '/games/runner/skins/other.webp')).status, 404);
  assert.equal((await get('admin', '/games/runner/skins/..%2Fcatalog.json')).status, 404);
  assert.equal((await get('pending', item.image)).status, 403);
});

test('the HTTP API reads the wardrobe, opens crates once per key and dresses', async t => {
  const { app, grant } = setup(t);
  grant(crateMilestone(1));
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  const call = async (method, path, body, key) => {
    const response = await fetch(`${base}${path}`, { method, headers: { Authorization: 'Bearer sam', 'Content-Type': 'application/json', ...(key ? { 'Idempotency-Key': key } : {}) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    return { status: response.status, body: await response.json() };
  };
  const view = await call('GET', '/games/runner/wardrobe');
  assert.equal(view.status, 200);
  assert.equal(view.body.progress.crates, 1);
  assert.deepEqual(view.body.catalog.kinds, ['character', 'backdrop', 'obstacles', 'fx']);
  assert.ok(view.body.catalog.items.every(x => x.weight === undefined));
  assert.equal((await call('POST', '/games/runner/crates', {})).status, 400);
  const opened = await call('POST', '/games/runner/crates', {}, 'crate-1');
  assert.equal(opened.status, 200);
  assert.deepEqual((await call('POST', '/games/runner/crates', {}, 'crate-1')).body, opened.body);
  assert.equal((await call('POST', '/games/runner/crates', {}, 'crate-2')).body.code, 'no_crate');
  const dressed = await call('PUT', '/games/runner/outfit', { kind: opened.body.item.kind, itemId: opened.body.item.id });
  assert.equal(dressed.body.selected[opened.body.item.kind], opened.body.item.id);
});

test('deleting a person removes their progress', async t => {
  const { app, action, store, personId, play } = setup(t);
  play({ score: 10, meters: 10 });
  assert.ok(store.get('runnerProgress', personId));
  await app.deleteAccount('admin', 'sam', store.account('sam').version);
  action({ action: 'member.delete', id: personId, version: store.get('members', personId).version });
  assert.equal(store.get('runnerProgress', personId), null);
});
