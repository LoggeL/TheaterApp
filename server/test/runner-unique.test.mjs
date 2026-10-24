import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { bundledCatalog, crateMilestone, drawWithDupes, loadCatalog, openRarities } from '../src/runner-wardrobe.mjs';

// Unique figures (`runnerUniqueFigures`): one non-human character per play, unlocked for good by
// owning all of the play's active role figures; a secret until then, never in crates or the shop,
// invisible for apps from before.

const rarities = [
  { id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 60, gage: 10 },
  { id: 'gold', name: 'Gold', color: '#E4AE39', weight: 10, gage: 200, buyable: false },
];
const defaults = [
  { id: 'c0', kind: 'character', name: 'Engel Logge', rarity: 'hell', default: true },
  { id: 'b0', kind: 'backdrop', name: 'Wand', rarity: 'hell', default: true },
  { id: 'o0', kind: 'obstacles', name: 'Lager', rarity: 'hell', default: true },
  { id: 'f0', kind: 'fx', name: 'Ohne', rarity: 'hell', default: true },
];
const role = (id, personId, play, year, extra = {}) => ({ id, kind: 'character', name: `Person ${personId}`, role: `Rolle ${id}`, play, year, rarity: 'hell', personId, ...extra });
// Spuk: three active role figures and one waiting for its picture; Alt: one gold figure, its unique
// figure waits for its picture.
const figures = [
  role('r1', 901, 'Spuk', 2026), role('r2', 902, 'Spuk', 2026), role('r3', 903, 'Spuk', 2026),
  role('r4', 904, 'Spuk', 2026, { disabled: true }),
  role('a1', 905, 'Alt', 2020, { rarity: 'gold' }),
];
const kuschel = { id: 'u.spuk', kind: 'character', name: 'Plüschi Wuschel', role: 'Plüschi Wuschel', play: 'Spuk', year: 2026, rarity: 'unique', unlock: { play: 'Spuk' }, description: 'Seit 2022 dabei.', image: 'figure.webp', harness: { fly: [100, 40] } };
const waiting = { id: 'u.alt', kind: 'character', name: 'Altgeist', role: 'Altgeist', play: 'Alt', year: 2020, rarity: 'unique', unlock: { play: 'Alt' }, disabled: true };
const uniqueFigures = { rarity: { id: 'unique', name: 'Unique', color: '#B388FF', style: 'holo' } };
const fixtures = new URL('./fixtures/wardrobe/', import.meta.url);
const catalogOf = (items = [...defaults, ...figures, kuschel, waiting], extra = {}) => loadCatalog({ roleFigures: true, rarities, uniqueFigures, items, ...extra }, fixtures);

const clock = () => new Date('2026-10-24T10:00:00Z');
function setup(t, { catalog = catalogOf(), dice = [], fallback = 0 } = {}) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock, runnerCatalog: catalog, random: () => dice.length ? dice.shift() : fallback });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let n = 0;
  const member = (uid, name) => {
    const personId = app.action('admin', { action: 'member.save', name }, `m-${++n}`).id;
    app.session({ uid, name, email: `${uid}@example.invalid`, email_verified: true });
    app.action('admin', { action: 'account.approve', uid, personId, version: 1, role: 'member' }, `m-${++n}`);
    return personId;
  };
  const sam = member('sam', 'Sam Beispiel'), kim = member('kim', 'Kim Beispiel');
  // Sam's progress record with [owned], as crates left it.
  const give = (owned, record = {}) => store.put('runnerProgress', sam, { personId: sam, meters: 0, creditedMeters: 0, creditedRounds: 0, opened: 0, owned, selected: {}, deaths: {}, createdAt: '2026-10-01T10:00:00.000Z', model: 2, ...record });
  return { store, app, sam, kim, give, saved: () => store.get('runnerProgress', sam) };
}
const now = { roles: true, unique: true };
// What must not show before the unlock: the id, the name, the description and the picture.
const secrets = ['u.spuk', 'Plüschi', 'Wuschel', 'Seit 2022', 'figure.webp', 'u.alt', 'Altgeist'];
const leaks = (reply, hidden = secrets) => hidden.filter(x => JSON.stringify(reply).includes(x));

test('the catalog: a unique figure is apart from the draw, one per play, disabled ones wait', () => {
  const c = catalogOf();
  assert.deepEqual(c.uniques.map(x => x.id), ['u.spuk']);
  const u = c.byId.get('u.spuk');
  assert.deepEqual([u.rarity, u.rarities, u.unique, u.unlock, u.drawnBy], ['unique', ['unique'], true, { play: 'Spuk' }, []]);
  assert.ok(!c.collectible.includes(u), 'never in crates, trades or purchases');
  assert.ok(!c.rarities.some(r => r.id === 'unique'), 'not a rarity of the draw');
  assert.deepEqual(c.uniqueRarity, { id: 'unique', name: 'Unique', color: '#B388FF', style: 'holo' });
  assert.deepEqual([...c.uniqueFiles.keys()], ['figure.webp']);
  // Without `uniqueFigures` the look is the default.
  assert.equal(loadCatalog({ rarities, items: [...defaults, ...figures, kuschel] }).uniqueRarity.style, 'holo');
  const bad = items => assert.throws(() => catalogOf([...defaults, ...figures, ...items]), /Wardrobe catalog/);
  bad([{ ...kuschel, personId: 901 }]);
  bad([{ ...kuschel, kind: 'fx' }]);
  bad([{ ...kuschel, unlock: undefined }]);
  bad([{ ...kuschel, unlock: { play: 'Unbekannt' } }]);
  bad([{ ...kuschel, year: undefined }]);
  bad([{ ...kuschel, rarities: ['unique', 'hell'] }]);
  bad([{ ...kuschel, default: true }]);
  // One per play, also counting one that waits for its picture.
  bad([kuschel, { ...kuschel, id: 'u.zwei', disabled: true }]);
  assert.throws(() => catalogOf(undefined, { uniqueFigures: { rarity: { id: 'hell' } } }), /rarity of the draw/);
});

test('hidden before the unlock: progress only, no name, id, picture or file', t => {
  const { app, give } = setup(t);
  give(['r1', 'r2']);
  const w = app.runnerWardrobe('sam', now);
  // The play waiting for its unique figure's picture (Alt) is left out.
  assert.deepEqual(w.uniqueFigures, { plays: [{ play: 'Spuk', year: 2026, have: 2, total: 3, unlocked: false, hidden: true, name: '???' }], unseen: [] });
  assert.deepEqual(w.catalog.uniques, []);
  assert.deepEqual(w.catalog.uniqueRarity, { id: 'unique', name: 'Unique', color: '#B388FF', style: 'holo' });
  assert.ok(!w.owned.includes('u.spuk'));
  for (const options of [now, { roles: true }, {}]) assert.deepEqual(leaks(app.runnerWardrobe('sam', options)), [], JSON.stringify(options));
  // The picture, wearing and buying answer like for an unknown item.
  assert.throws(() => app.runnerSkin('sam', 'figure.webp'), { status: 404, message: 'Nicht gefunden.' });
  assert.throws(() => app.runnerOutfit('sam', { kind: 'character', itemId: 'u.spuk', ...now }), { status: 404, message: 'Dieses Teil gibt es nicht.' });
  assert.throws(() => app.runnerOutfit('sam', { kind: 'character', itemId: 'u.unbekannt', ...now }), { status: 404, message: 'Dieses Teil gibt es nicht.' });
  assert.throws(() => app.runnerBuy('sam', 'b-u', { itemId: 'u.spuk', ...now }), { status: 404, message: 'Dieses Teil gibt es nicht.' });
});

test('unlocked exactly when the last role figure of the play comes, then celebrated once', t => {
  const { app, give, saved } = setup(t);
  give(['r1'], { gage: 200 });
  assert.equal(app.runnerWardrobe('sam', now).uniqueFigures.plays[0].have, 1);
  // Two of three: not yet.
  let deal = app.runnerBuy('sam', 'b-1', { itemId: 'r2', ...now });
  assert.deepEqual(deal.wardrobe.uniqueFigures.plays[0], { play: 'Spuk', year: 2026, have: 2, total: 3, unlocked: false, hidden: true, name: '???' });
  assert.equal(saved().uniques, undefined);
  // The third one completes the play: the reply already carries the figure.
  deal = app.runnerBuy('sam', 'b-2', { itemId: 'r3', ...now });
  const w = deal.wardrobe;
  assert.ok(w.owned.includes('u.spuk'));
  assert.deepEqual(w.uniqueFigures, { plays: [{ play: 'Spuk', year: 2026, have: 3, total: 3, unlocked: true, itemId: 'u.spuk', name: 'Plüschi Wuschel', unlockedAt: '2026-10-24T10:00:00.000Z' }], unseen: ['u.spuk'] });
  const item = w.catalog.uniques[0];
  assert.deepEqual([item.id, item.unique, item.rarity, item.role, item.play, item.year, item.personId], ['u.spuk', true, 'unique', 'Plüschi Wuschel', 'Spuk', 2026, undefined]);
  assert.match(item.image, /figure\.webp\?v=/);
  assert.ok(!w.catalog.items.some(x => x.unique), 'not among the collectible items');
  assert.deepEqual(saved().uniques, ['u.spuk']);
  // No shine, no duplicate.
  assert.ok(!w.shiny.includes('u.spuk'));
  // The picture now for Sam, still not for Kim.
  assert.equal(app.runnerSkin('sam', 'figure.webp').mime, 'image/webp');
  assert.throws(() => app.runnerSkin('kim', 'figure.webp'), { status: 404 });
  assert.deepEqual(leaks(app.runnerWardrobe('kim', now)), []);
  // Wearing it.
  assert.equal(app.runnerOutfit('sam', { kind: 'character', itemId: 'u.spuk', ...now }).selected.character, 'u.spuk');
  // The celebration once; only unlocked ids count.
  const seen = app.runnerUniqueSeen('sam', { itemIds: ['u.spuk', 'u.alt', 'nope'], roles: true });
  assert.deepEqual(seen.uniqueFigures.unseen, []);
  assert.deepEqual(saved().uniquesSeen, ['u.spuk']);
  assert.throws(() => app.runnerUniqueSeen('sam', { itemIds: 'u.spuk' }), { status: 400 });
});

test('a crate that brings the last role figure unlocks it too; the own figure counts as owned', t => {
  // Sam plays r3 himself (his person id): owning r1 and r2 is then all that is missing.
  const { app, give, sam } = setup(t);
  app.runnerCatalog = catalogOf([...defaults, ...figures.map(x => x.id === 'r3' ? { ...x, personId: sam } : x), kuschel, waiting]);
  give(['r1'], { meters: crateMilestone(1) });
  assert.deepEqual(app.runnerWardrobe('sam', now).uniqueFigures.plays[0].have, 2);
  // dice 0: the light blue rarity, its first missing figure (r2), shiny.
  const opened = app.runnerOpenCrate('sam', 'k-1', { dupes: true, ...now });
  assert.equal(opened.item.id, 'r2');
  assert.ok(!opened.reel.includes('u.spuk'));
  assert.ok(opened.wardrobe.owned.includes('u.spuk'));
  assert.deepEqual(opened.wardrobe.uniqueFigures.unseen, ['u.spuk']);
});

test('it stays when the play gets a new role figure later', t => {
  const { app, give } = setup(t);
  give(['r1', 'r2', 'r3']);
  assert.ok(app.runnerWardrobe('sam', now).owned.includes('u.spuk'));
  // r4 gets its picture: Spuk has four active role figures now.
  app.runnerCatalog = catalogOf([...defaults, ...figures.map(x => ({ ...x, disabled: undefined })), kuschel, waiting]);
  const w = app.runnerWardrobe('sam', now);
  assert.ok(w.owned.includes('u.spuk'));
  assert.deepEqual(w.uniqueFigures.plays[0], { play: 'Spuk', year: 2026, have: 3, total: 4, unlocked: true, itemId: 'u.spuk', name: 'Plüschi Wuschel', unlockedAt: '2026-10-24T10:00:00.000Z' });
  assert.equal(app.runnerSkin('sam', 'figure.webp').mime, 'image/webp');
  // Kim with the same three figures now needs the fourth one too.
  const k = app.runnerWardrobe('kim', now);
  assert.equal(k.uniqueFigures.plays[0].unlocked, false);
});

test('never from crates, trades or the shop, also with everything else owned', t => {
  const c = catalogOf();
  const owned = new Set(c.collectible.map(x => x.id)), open = openRarities(c, owned);
  let n = 0;
  for (let i = 0; i < 200; i++) {
    const r = (i * 7919 % 1000) / 1000;
    const draw = drawWithDupes(c, owned, () => r, open);
    assert.notEqual(draw.item.id, 'u.spuk');
    assert.ok(draw.duplicate);
    n++;
  }
  assert.equal(n, 200);
  const { app, give } = setup(t, { fallback: 0.5 });
  give(['r1', 'r2', 'r3', 'a1'], { meters: crateMilestone(6), gage: 5000 });
  for (let i = 0; i < 6; i++) {
    const opened = app.runnerOpenCrate('sam', `k-${i}`, { dupes: true, ...now });
    assert.notEqual(opened.item.id, 'u.spuk');
    assert.ok(!opened.reel.includes('u.spuk'));
  }
  const w = app.runnerWardrobe('sam', now);
  assert.deepEqual(w.trades, [], 'nothing left to trade for');
  assert.ok(w.owned.includes('u.spuk'));
  assert.throws(() => app.runnerBuy('sam', 'b-u', { itemId: 'u.spuk', ...now }), { status: 404 });
});

test('apps from before neither see nor wear it, also once unlocked', t => {
  assert.ok(apiFeatures.includes('runnerUniqueFigures'));
  const { app, give, saved } = setup(t);
  give(['r1', 'r2', 'r3']);
  app.runnerOutfit('sam', { kind: 'character', itemId: 'u.spuk', ...now });
  assert.equal(saved().selected.character, 'u.spuk');
  for (const options of [{ roles: true }, {}]) {
    const w = app.runnerWardrobe('sam', options);
    assert.deepEqual(leaks(w, ['u.spuk', 'Plüschi', 'figure.webp', 'unique']), [], JSON.stringify(options));
    assert.equal(w.uniqueFigures, undefined);
    // It is worn in the new app; the old one shows the default figure.
    assert.equal(w.selected.character, 'c0');
    for (const id of w.owned) assert.ok(w.catalog.items.some(x => x.id === id) || w.catalog.rewards.some(x => x.id === id), id);
  }
  // Opening and wearing from an older app: no trace of it, and it cannot be worn from there.
  give(['r1', 'r2', 'r3'], { meters: crateMilestone(1), uniques: ['u.spuk'], selected: { character: 'u.spuk' } });
  const opened = app.runnerOpenCrate('sam', 'k-old', { dupes: true, roles: true });
  assert.deepEqual(leaks(opened, ['u.spuk', 'Plüschi', 'figure.webp']), []);
  assert.throws(() => app.runnerOutfit('sam', { kind: 'character', itemId: 'u.spuk', roles: true }), { status: 404 });
  // Still unlocked for the new app.
  assert.ok(app.runnerWardrobe('sam', now).owned.includes('u.spuk'));
  assert.equal(app.runnerWardrobe('sam', now).selected.character, 'u.spuk');
});

test('the bundled catalog: unique figures without pictures wait, nothing shows and nothing breaks', t => {
  const c = bundledCatalog();
  assert.equal(c.uniqueRarity.id, 'unique');
  assert.equal(c.uniqueRarity.style, 'holo');
  // Every unique figure of the catalog (all still without picture) is left out.
  assert.deepEqual(c.uniques.filter(x => !x.image).map(x => x.id), []);
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  const w = app.runnerWardrobe('admin', now);
  assert.deepEqual(w.uniqueFigures.plays.map(x => x.play), c.uniques.map(x => x.unlock.play));
  for (const p of w.uniqueFigures.plays) assert.ok(p.total > 0, p.play);
  assert.deepEqual(w.catalog.uniques, []);
});

test('over HTTP: the flag in the query and the body, the seen route, and the picture a 404 until unlocked', async t => {
  const { app, give } = setup(t);
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const call = (path, method = 'GET', body) => fetch(`http://127.0.0.1:${server.address().port}/api/mobile/v1${path}`, { method, headers: { Authorization: 'Bearer sam', 'Content-Type': 'application/json' }, ...(body ? { body: JSON.stringify(body) } : {}) });
  give(['r1', 'r2']);
  assert.equal((await call('/games/runner/skins/figure.webp')).status, 404);
  const before = await (await call('/games/runner/wardrobe?roles=1&unique=1')).json();
  assert.deepEqual(leaks(before), []);
  assert.equal(before.uniqueFigures.plays[0].have, 2);
  assert.equal((await (await call('/games/runner/wardrobe?roles=1')).json()).uniqueFigures, undefined);
  give(['r1', 'r2', 'r3']);
  const after = await (await call('/games/runner/wardrobe?roles=1&unique=1')).json();
  assert.deepEqual(after.uniqueFigures.unseen, ['u.spuk']);
  const picture = await call(after.catalog.uniques[0].image);
  assert.equal(picture.status, 200);
  const seen = await call('/games/runner/unique/seen', 'PUT', { itemIds: ['u.spuk'], roles: true });
  assert.equal(seen.status, 200);
  assert.deepEqual((await seen.json()).uniqueFigures.unseen, []);
  const worn = await call('/games/runner/outfit', 'PUT', { kind: 'character', itemId: 'u.spuk', roles: true, unique: true });
  assert.equal((await worn.json()).selected.character, 'u.spuk');
});
