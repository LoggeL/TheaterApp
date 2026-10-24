import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { bundledCatalog, crateMilestone, drawWithDupes, dupeDefaults, loadCatalog, openRarities } from '../src/runner-wardrobe.mjs';

// Weights add up to 100: a die below .6 picks hell, below .9 blau, else gold.
const rarities = [
  { id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 60, gage: 10 },
  { id: 'blau', name: 'Blau', color: '#4B69FF', weight: 30, gage: 20 },
  { id: 'gold', name: 'Gold', color: '#E4AE39', weight: 10, gage: 200, exclusive: true, buyable: false },
];
const defaults = [
  { id: 'c0', kind: 'character', name: 'Engel Logge', rarity: 'hell', default: true },
  { id: 'b0', kind: 'backdrop', name: 'Wand', rarity: 'hell', default: true },
  { id: 'o0', kind: 'obstacles', name: 'Lager', rarity: 'hell', default: true },
  { id: 'f0', kind: 'fx', name: 'Ohne', rarity: 'hell', default: true },
];
const basic = [
  { id: 'h1', kind: 'character', name: 'Hell 1', rarity: 'hell' },
  { id: 'h2', kind: 'fx', name: 'Hell 2', rarity: 'hell' },
  { id: 'b1', kind: 'character', name: 'Blau 1', rarity: 'blau' },
  { id: 'g1', kind: 'character', name: 'Gold 1', rarity: 'gold' },
];
const fixtures = new URL('./fixtures/wardrobe/', import.meta.url);
const catalogOf = (items = basic, extra = {}) => loadCatalog({ rarities, items: [...defaults, ...items], ...extra }, fixtures);

/** A member "sam" with crates; the dice come from [dice] first, then [fallback] (no shine, no near miss). */
function setup(t, { catalog = catalogOf(), fallback = 0.99 } = {}) {
  const store = new Store(); t.after(() => store.close());
  const dice = [];
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => new Date('2026-10-24T10:00:00Z'), runnerCatalog: catalog, random: () => dice.length ? dice.shift() : fallback });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  const personId = app.action('admin', { action: 'member.save', name: 'Sam Beispiel' }, 'm1').id;
  app.session({ uid: 'sam', name: 'Sam', email: 'sam@example.invalid', email_verified: true });
  app.action('admin', { action: 'account.approve', uid: 'sam', personId, version: 1, role: 'member' }, 'm2');
  const patch = change => { app.runnerWardrobe('sam'); const p = store.get('runnerProgress', personId); store.put('runnerProgress', personId, { ...p, ...change(p) }); };
  patch(() => ({ points: crateMilestone(30) }));
  let key = 0;
  const open = (...roll) => { dice.push(...roll); return app.runnerOpenCrate('sam', `k${++key}`, { dupes: true }); };
  const own = (...ids) => patch(p => ({ owned: [...p.owned, ...ids] }));
  return { store, app, dice, personId, patch, open, own, view: () => app.runnerWardrobe('sam') };
}

test('a rarity with something missing never gives a duplicate; a complete one does', t => {
  const { open, view } = setup(t);
  // hell, then the first missing one.
  assert.deepEqual([open(0.1, 0), open(0.1, 0)].map(r => [r.item.id, r.outcome.type, r.outcome.duplicate]), [['h1', 'new', false], ['h2', 'new', false]]);
  // Hell is complete: the same die now brings a duplicate of h1, worth hell's gage.
  const dupe = open(0.1, 0);
  assert.deepEqual([dupe.item.id, dupe.outcome], ['h1', { type: 'gage', gage: 10, duplicate: true, shiny: false, rarity: 'hell', crate: 'costume', target: 'random' }]);
  assert.equal(dupe.reel[dupe.winnerIndex], 'h1');
  const w = view();
  assert.deepEqual(w.gage, { balance: 10, earned: 10 });
  assert.equal(w.progress.opened, 3);
  // Blau still has something missing: no duplicate there.
  assert.equal(open(0.7, 0.5).outcome.type, 'new');
});

test('complete rarities keep their chance: duplicates do not pass it on', () => {
  const c = catalogOf();
  const owned = new Set(['c0', 'b0', 'o0', 'f0', 'h1', 'h2']);
  let seed = 3;
  const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
  const counts = { dupe: 0, blau: 0, gold: 0 };
  const runs = 100000;
  for (let i = 0; i < runs; i++) {
    const d = drawWithDupes(c, owned, random, openRarities(c, owned));
    if (d.duplicate) counts.dupe++; else counts[d.tier.id]++;
  }
  // Without the old passing on, gold stays at 10 % instead of 25 %.
  assert.ok(Math.abs(counts.dupe / runs - 0.6) < 0.01, JSON.stringify(counts));
  assert.ok(Math.abs(counts.gold / runs - 0.1) < 0.01, JSON.stringify(counts));
  // All complete: every draw is a duplicate, still by weight.
  const all = new Set([...owned, 'b1', 'g1']);
  const tiers = { hell: 0, blau: 0, gold: 0 };
  for (let i = 0; i < runs; i++) { const d = drawWithDupes(c, all, random, openRarities(c, all)); assert.ok(d.duplicate); tiers[d.tier.id]++; }
  assert.ok(Math.abs(tiers.gold / runs - 0.1) < 0.01 && Math.abs(tiers.hell / runs - 0.6) < 0.01, JSON.stringify(tiers));
});

test('with everything owned crates still open and pay gage by rarity', t => {
  const { open, own, view } = setup(t);
  own('h1', 'h2', 'b1', 'g1');
  assert.equal(view().progress.complete, true);
  assert.deepEqual([open(0.1, 0), open(0.7, 0), open(0.95, 0)].map(r => [r.item.id, r.outcome.type, r.outcome.gage]), [['h1', 'gage', 10], ['b1', 'gage', 20], ['g1', 'gage', 200]]);
  assert.equal(view().gage.balance, 230);
});

test('older apps keep the draw without duplicates and without shine', t => {
  const { app, dice, own } = setup(t);
  dice.push(0.1, 0, 0.01);
  const first = app.runnerOpenCrate('sam', 'old-1');
  assert.equal(first.outcome, undefined);
  assert.deepEqual(app.runnerWardrobe('sam').shiny, []);
  own('h2', 'b1', 'g1');
  assert.throws(() => app.runnerOpenCrate('sam', 'old-2'), { status: 409, code: 'wardrobe_complete' });
});

test('a shine comes with the new item, or upgrades a plain one instead of paying', t => {
  const { open, view } = setup(t);
  // tier, item, shine: 0.01 < 3 %.
  const shiny = open(0.1, 0, 0.01);
  assert.deepEqual([shiny.item.id, shiny.outcome.type, shiny.outcome.shiny], ['h1', 'new', true]);
  assert.equal(open(0.1, 0, 0.5).item.id, 'h2');
  assert.deepEqual(view().shiny, ['h1']);
  // A shiny duplicate of h2, owned plainly: it shines now, no gage.
  const upgrade = open(0.1, 0.9, 0.02);
  assert.deepEqual([upgrade.item.id, upgrade.outcome.type, upgrade.outcome.shiny], ['h2', 'shine', true]);
  assert.deepEqual(view().shiny.sort(), ['h1', 'h2']);
  assert.equal(view().gage.balance, 0);
  // Shiny already: the duplicate pays as usual.
  assert.deepEqual(open(0.1, 0, 0.01).outcome.type, 'gage');
  assert.equal(view().gage.balance, 10);
  assert.deepEqual(dupeDefaults.shinyChance, { costume: 0.03, ensemble: 0.03 });
});

test('a duplicate brings shine or gage, never a role: roles are figures drawn like any other item', t => {
  // h1 and its role h1.romeo are two figures of the same person, each with its own rarity.
  const items = [basic[0], { id: 'h1.romeo', kind: 'character', name: 'Hell 1', role: 'Romeo', play: 'Romeo und Julia', year: 2026, rarity: 'blau', variantOf: 'h1', image: 'figure.webp' }, ...basic.slice(1)];
  const { app, dice, open, own, view } = setup(t, { catalog: catalogOf(items) });
  own('h1', 'h2');
  // Hellblau is complete: a duplicate of h1 pays, even though the person has a role still missing.
  const dupe = open(0.1, 0, 0.5, 0);
  assert.deepEqual([dupe.item.id, dupe.outcome.type, dupe.outcome.gage], ['h1', 'gage', 10]);
  // The role comes as a new item of its own rarity (blau: 0.7), drawn like b1.
  dice.push(0.7, 0);
  const role = app.runnerOpenCrate('sam', 'role', { dupes: true, roles: true });
  assert.deepEqual([role.item.id, role.item.rarity, role.outcome.type], ['h1.romeo', 'blau', 'new']);
  assert.equal(view().gage.balance, 10);
  // A shiny duplicate still upgrades the plain item instead of paying.
  assert.deepEqual(open(0.1, 0, 0.01).outcome.type, 'shine');
  // Catalogs with role variants are refused: a role is an item with `variantOf` now.
  assert.throws(() => catalogOf([{ ...basic[0], variants: [{ id: 'h2', name: 'X', image: 'figure.webp' }] }, basic[1]]), /variants of h1/);
});

test('a trade turns five duplicates into a random missing item of the next rarity up', t => {
  const { app, patch, view } = setup(t);
  patch(() => ({ gage: 120, owned: ['h1'] }));
  assert.deepEqual(view().trades, [{ from: 'hell', to: 'blau', cost: 50 }, { from: 'blau', to: 'gold', cost: 100 }]);
  const blue = app.runnerTrade('sam', 't1', { rarity: 'hell' });
  assert.deepEqual([blue.item.id, blue.outcome], ['b1', { type: 'trade', rarity: 'blau', cost: 50 }]);
  assert.deepEqual(app.runnerTrade('sam', 't1', { rarity: 'hell' }), blue, 'same key, same trade');
  // Blau is complete: from hell it goes on to gold, but at the price of five blue duplicates.
  assert.deepEqual(view().trades, [{ from: 'blau', to: 'gold', cost: 100 }]);
  assert.throws(() => app.runnerTrade('sam', 't2', { rarity: 'hell' }), { status: 409, code: 'not_enough_gage' });
  patch(p => ({ gage: p.gage + 30 }));
  assert.equal(app.runnerTrade('sam', 't3', { rarity: 'hell' }).item.id, 'g1');
  assert.equal(view().gage.balance, 0);
  assert.throws(() => app.runnerTrade('sam', 't4', { rarity: 'blau' }), { status: 409, code: 'nothing_to_trade' });
  assert.throws(() => app.runnerTrade('sam', 't5', { rarity: 'zirkus' }), { status: 400 });
  assert.throws(() => app.runnerTrade('sam', '', { rarity: 'hell' }), { status: 400 });
  // Still missing h2 below does not matter: trades only go up.
  assert.ok(!view().owned.includes('h2'));
});

test('trades skip a locked rarity', t => {
  const catalog = loadCatalog({
    rarities: [rarities[0], { id: 'legacy', name: 'Legacy', color: '#A47A4B', weight: 8, gage: 50, requires: { rarity: 'hell', kind: 'character' } }, { id: 'rot', name: 'Rot', color: '#EB4B4B', weight: 4, gage: 80 }],
    items: [...defaults, basic[0], { id: 'l1', kind: 'character', name: 'Anton', rarity: 'legacy' }, { id: 'r1', kind: 'fx', name: 'Rot', rarity: 'rot' }],
  });
  const { app, patch, view } = setup(t, { catalog });
  patch(() => ({ gage: 250 }));
  assert.deepEqual(view().lockedRarities, ['legacy']);
  assert.deepEqual(view().trades, [{ from: 'legacy', to: 'rot', cost: 250 }]);
  assert.equal(app.runnerTrade('sam', 'x', { rarity: 'hell' }).item.id, 'r1');
});

test('one chosen missing item costs ten duplicates of its rarity; gold is not for sale', t => {
  const { app, patch, view } = setup(t);
  patch(() => ({ gage: 250 }));
  assert.throws(() => app.runnerBuy('sam', 'b0', { itemId: 'g1' }), { status: 409, code: 'not_buyable' });
  assert.throws(() => app.runnerBuy('sam', 'b1', { itemId: 'c0' }), { status: 404 });
  const bought = app.runnerBuy('sam', 'b2', { itemId: 'b1' });
  assert.deepEqual([bought.item.id, bought.outcome], ['b1', { type: 'buy', rarity: 'blau', cost: 200 }]);
  assert.deepEqual(app.runnerBuy('sam', 'b2', { itemId: 'b1' }), bought);
  assert.throws(() => app.runnerBuy('sam', 'b3', { itemId: 'b1' }), { status: 409, code: 'already_owned' });
  assert.throws(() => app.runnerBuy('sam', 'b4', { itemId: 'h1' }), { status: 409, code: 'not_enough_gage' });
  assert.equal(view().gage.balance, 50);
  assert.equal(view().catalog.dupes.buyDupes, 10);
  assert.deepEqual(view().catalog.rarities.map(r => [r.id, r.gage, r.buyable]), [['hell', 10, true], ['blau', 20, true], ['gold', 200, false]]);
});

test('locked items cannot be bought before their rarity opens', t => {
  const catalog = loadCatalog({
    rarities: [rarities[0], { id: 'legacy', name: 'Legacy', color: '#A47A4B', weight: 8, gage: 50, requires: { rarity: 'hell', kind: 'character' }, hint: 'Sammle alle hellblauen Figuren' }],
    items: [...defaults, basic[0], { id: 'l1', kind: 'character', name: 'Anton', rarity: 'legacy' }],
  });
  const { app, patch } = setup(t, { catalog });
  patch(() => ({ gage: 1000 }));
  assert.throws(() => app.runnerBuy('sam', 'l', { itemId: 'l1' }), { status: 409, code: 'locked', message: 'Sammle alle hellblauen Figuren' });
  app.runnerBuy('sam', 'h', { itemId: 'h1' });
  assert.equal(app.runnerBuy('sam', 'l2', { itemId: 'l1' }).item.id, 'l1');
});

test('broken duplicate settings are refused', () => {
  assert.throws(() => catalogOf(basic, { dupes: { shinyChance: 2 } }), /dupes.shinyChance/);
  assert.throws(() => catalogOf(basic, { dupes: { tradeDupes: 0 } }), /dupes.tradeDupes/);
  assert.throws(() => catalogOf(basic, { dupes: { jackpot: 1 } }), /dupes.jackpot/);
  assert.throws(() => loadCatalog({ rarities: [{ ...rarities[0], gage: -1 }], items: defaults }), /gage/);
  assert.throws(() => catalogOf(basic, { dupes: { shinyChance: { mission: 1.5 } } }), /dupes.shinyChance.mission/);
  assert.throws(() => catalogOf(basic, { dupes: { shinyChance: [0.1] } }), /dupes.shinyChance/);
  // One number for all kinds, or one per kind; new kinds such as missions just get an entry.
  assert.deepEqual(catalogOf(basic, { dupes: { shinyChance: 0.05 } }).dupes.shinyChance, { costume: 0.05, ensemble: 0.05 });
  assert.deepEqual(catalogOf(basic, { dupes: { shinyChance: { mission: 0.05 } } }).dupes.shinyChance, { costume: 0.03, ensemble: 0.03, mission: 0.05 });
});

test('the bundled catalog pays gage in every rarity and keeps gold out of the shop', () => {
  const c = bundledCatalog();
  assert.deepEqual(c.rarities.map(r => r.gage), [10, 20, 30, 40, 50, 80, 200]);
  assert.deepEqual(c.rarities.filter(r => !r.buyable).map(r => r.id), ['gold']);
  // Missionskisten (Tagesmissionen) and the Zufallskiste shine a bit more often than an aimed crate.
  assert.deepEqual(c.dupes, { shinyChance: { costume: 0.05, targeted: 0.03, ensemble: 0.03, event: 0.03, mission: 0.05 }, tradeDupes: 5, buyDupes: 10 });
});

test('the HTTP API opens with duplicates, trades and buys once per key', async t => {
  const { app, own, patch } = setup(t);
  own('h1', 'h2', 'b1', 'g1');
  patch(() => ({ gage: 300 }));
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  const call = async (method, path, body, key) => {
    const response = await fetch(`${base}${path}`, { method, headers: { Authorization: 'Bearer sam', 'Content-Type': 'application/json', ...(key ? { 'Idempotency-Key': key } : {}) }, body: JSON.stringify(body) });
    return { status: response.status, body: await response.json() };
  };
  const opened = await call('POST', '/games/runner/crates', { dupes: true }, 'c1');
  assert.equal(opened.status, 200);
  assert.equal(opened.body.outcome.duplicate, true);
  // Older apps: complete stays complete.
  assert.equal((await call('POST', '/games/runner/crates', {}, 'c2')).body.code, 'wardrobe_complete');
  assert.equal((await call('POST', '/games/runner/trade', { rarity: 'hell' }, 't1')).body.code, 'nothing_to_trade');
  assert.equal((await call('POST', '/games/runner/buy', { itemId: 'g1' }, 'b1')).body.code, 'already_owned');
  assert.equal((await call('POST', '/games/runner/buy', { itemId: 'g1' })).status, 400);
});
