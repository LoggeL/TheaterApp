import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { bundledCatalog, crateMilestone, drawWithDupes, loadCatalog, openRarities } from '../src/runner-wardrobe.mjs';
import { legacyOpenedBy, roleFiguresModel } from '../src/runner-role-figures.mjs';
import { bundledContentReleases, releasedCatalog } from '../src/runner-content-releases.mjs';

// Role figures (`runnerRoleFigures`): the move of progress records from role variants, the view of
// apps from before, Legacy from 10 light blue figures on (and open for good) and the new weights.

const clock = () => new Date('2026-10-24T10:00:00Z');

/** A member "sam" (person 2, who also plays Yunus in the bundled catalog) with [catalog]. */
function setup(t, { catalog = null, dice = [], fallback = 0.99 } = {}) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock, ...(catalog ? { runnerCatalog: catalog } : {}), random: () => dice.length ? dice.shift() : fallback });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  const personId = app.action('admin', { action: 'member.save', name: 'Sam Beispiel' }, 'm1').id;
  app.session({ uid: 'sam', name: 'Sam', email: 'sam@example.invalid', email_verified: true });
  app.action('admin', { action: 'account.approve', uid: 'sam', personId, version: 1, role: 'member' }, 'm2');
  // A record as the server before role figures left it.
  const old = record => store.put('runnerProgress', personId, { personId, meters: crateMilestone(20), creditedMeters: 0, creditedRounds: 0, opened: 3, owned: [], selected: {}, deaths: { lamp: 4 }, createdAt: '2026-09-01T10:00:00.000Z', ...record });
  return { store, app, personId, dice, old, saved: () => store.get('runnerProgress', personId) };
}

test('a record from before moves over once: variants become figures, the worn one stays worn, nothing is lost', t => {
  const { app, old, saved } = setup(t);
  old({
    owned: ['character.elena', 'character.theresa', 'fx.funken'], shiny: ['character.elena'],
    variants: ['character.elena--anno', 'character.theresa--anno'], selected: { character: 'character.theresa', fx: 'fx.funken' },
    selectedVariant: { 'character.theresa': 'character.theresa--anno' }, gage: 120, gageEarned: 300, ensembleOpened: 1, ensembleSeen: 25,
  });
  const w = app.runnerWardrobe('sam', { roles: true });
  for (const id of ['character.elena', 'character.theresa', 'character.elena--anno', 'character.theresa--anno', 'fx.funken']) assert.ok(w.owned.includes(id), id);
  // Shine stays with the figure that had it; variants never shone.
  assert.deepEqual(w.shiny, ['character.elena']);
  assert.deepEqual([w.selected.character, w.selected.fx], ['character.theresa--anno', 'fx.funken']);
  assert.deepEqual(w.gage, { balance: 120, earned: 300 });
  assert.deepEqual([w.progress.opened, w.stats.deaths], [3, [{ kind: 'lamp', count: 4 }]]);
  assert.deepEqual([w.variants, w.selectedVariants, w.roleFigures], [[], {}, true]);
  const moved = saved();
  assert.equal(moved.model, roleFiguresModel);
  assert.equal(moved.roleFiguresAt, '2026-10-24T10:00:00.000Z');
  assert.deepEqual([moved.ensembleOpened, moved.ensembleSeen, moved.gage], [1, 25, 120]);
  // Once only: a second request changes nothing.
  app.runnerWardrobe('sam', { roles: true });
  app.runnerWardrobe('sam');
  assert.deepEqual(saved(), moved);
  // Every item a player owned before is still in the catalog.
  const c = bundledCatalog();
  assert.deepEqual(moved.owned.filter(id => !c.byId.has(id)), []);
});

test('a record owning or wearing figures no longer in the catalog loads, moves over and plays on', t => {
  // Lucia and the technicians Daniel, Elea, Emilia and Julian left the catalog (no picture yet).
  // Nobody can own them (they were disabled), but a record that does must not break anything.
  const gone = ['character.lucia', 'character.daniel', 'character.elea', 'character.emilia', 'character.julian-technik', 'character.unbekannt'];
  const c = bundledCatalog();
  assert.deepEqual(gone.filter(id => c.byId.has(id)), []);
  const { app, old, saved } = setup(t);
  old({ owned: ['character.elena', ...gone], shiny: ['character.lucia'], variants: ['character.daniel'], selected: { character: 'character.lucia', fx: 'fx.funken' }, selectedVariant: { 'character.elena': 'character.emilia' } });
  const w = app.runnerWardrobe('sam', { roles: true });
  assert.ok(w.owned.includes('character.elena'));
  assert.deepEqual(gone.filter(id => w.owned.includes(id) || w.shiny.includes(id)), []);
  // Worn but gone: Sam's gift figure (Yunus' most common role) instead of Engel Logge; an fx not owned: the default.
  assert.deepEqual([w.selected.character, w.selected.fx], ['character.yunus--nexus', c.defaults.fx]);
  assert.equal(w.gift, 'character.yunus--nexus');
  assert.equal(saved().model, roleFiguresModel);
  // Older apps see the same, and crates still open.
  const older = app.runnerWardrobe('sam');
  assert.deepEqual(gone.filter(id => older.owned.includes(id) || older.variants.includes(id)), []);
  const opened = app.runnerOpenCrate('sam', 'k-gone', { dupes: true, roles: true });
  assert.ok(c.byId.has(opened.item.id));
  assert.ok(!gone.includes(opened.item.id));
});

test('Legacy open under the old rule stays open; otherwise it opens from 10 light blue figures', t => {
  const opened = setup(t);
  // All light blue characters of 0.11.2: today only 7 of them are light blue (Maren is Technik).
  opened.old({ owned: [...legacyOpenedBy] });
  const w = opened.app.runnerWardrobe('sam', { roles: true });
  const c = bundledCatalog();
  assert.ok(c.collectible.filter(x => x.kind === 'character' && x.rarity === 'hellblau' && w.owned.includes(x.id)).length < 10);
  assert.ok(!w.lockedRarities.includes('legacy'));
  assert.deepEqual(opened.saved().unlockedRarities, ['legacy']);
  // A Legacy item won before means it was open as well.
  const won = setup(t);
  won.old({ owned: ['character.anton'] });
  assert.ok(!won.app.runnerWardrobe('sam', { roles: true }).lockedRarities.includes('legacy'));
  // Neither: locked, with the new hint.
  const fresh = setup(t);
  fresh.old({ owned: legacyOpenedBy.slice(1) });
  assert.ok(fresh.app.runnerWardrobe('sam', { roles: true }).lockedRarities.includes('legacy'));
  assert.equal(c.rarity.get('legacy').hint, 'Sammle 10 hellblaue Figuren');
});

test('Legacy opens with the 10th light blue figure, and once open it stays open', t => {
  const c = bundledCatalog();
  const light = c.collectible.filter(x => x.kind === 'character' && x.rarity === 'hellblau').map(x => x.id);
  assert.equal(light.length, 33);
  const base = Object.values(c.defaults);
  assert.ok(!openRarities(c, new Set([...base, ...light.slice(0, 9)])).has('legacy'));
  assert.ok(openRarities(c, new Set([...base, ...light.slice(0, 10)])).has('legacy'));
  assert.ok(openRarities(c, new Set(base), ['legacy']).has('legacy'), 'remembered as open');
  // In the game: the 10th light blue figure from a crate opens Legacy; a catalog without most of
  // them later (pictures withdrawn, rarities moved) does not close it again.
  const rarities = [
    { id: 'hellblau', name: 'Hellblau', color: '#5E98D9', weight: 45, gage: 10 },
    { id: 'legacy', name: 'Legacy', color: '#A47A4B', weight: 6, gage: 50, requires: { rarity: 'hellblau', kind: 'character', count: 10 } },
  ];
  const defaults = ['character', 'backdrop', 'obstacles', 'fx'].map(kind => ({ id: `${kind}.0`, kind, name: kind, rarity: 'hellblau', default: true }));
  const people = Array.from({ length: 12 }, (_, i) => ({ id: `h${i}`, kind: 'character', name: `H${i}`, rarity: 'hellblau' }));
  const legacy = { id: 'l1', kind: 'character', name: 'Anton', rarity: 'legacy' };
  const catalog = loadCatalog({ rarities, items: [...defaults, ...people, legacy] });
  // Dice: rarity (hellblau as long as Legacy is locked), item, shine, reel …
  const { app, old, saved } = setup(t, { catalog, fallback: 0 });
  old({ owned: people.slice(0, 9).map(x => x.id), model: roleFiguresModel });
  assert.ok(app.runnerWardrobe('sam', { roles: true }).lockedRarities.includes('legacy'));
  const tenth = app.runnerOpenCrate('sam', 'k1', { dupes: true, roles: true });
  assert.equal(tenth.item.id, 'h9');
  assert.deepEqual(tenth.wardrobe.lockedRarities, []);
  assert.deepEqual(saved().unlockedRarities, ['legacy']);
  app.runnerCatalog = loadCatalog({ rarities, items: [...defaults, ...people.slice(0, 2), ...people.slice(2).map(x => ({ ...x, disabled: true })), legacy] });
  assert.deepEqual(app.runnerWardrobe('sam', { roles: true }).lockedRarities, []);
});

test('a crate draws the rarity by the new weights (seeded, 30 000 draws)', () => {
  const c = bundledCatalog();
  // Mulberry32: the same numbers every run.
  let seed = 20261024;
  const random = () => { seed = (seed + 0x6D2B79F5) | 0; let x = Math.imul(seed ^ (seed >>> 15), 1 | seed); x = (x + Math.imul(x ^ (x >>> 7), 61 | x)) ^ x; return ((x ^ (x >>> 14)) >>> 0) / 4294967296; };
  assert.deepEqual(c.rarities.map(r => [r.id, r.weight]), [['hellblau', 45], ['blau', 22], ['technik', 10], ['pink', 12], ['legacy', 6], ['rot', 3.5], ['gold', 1.5]]);
  const owned = new Set(Object.values(c.defaults));
  const count = (open, n = 30000) => {
    const seen = {};
    for (let i = 0; i < n; i++) { const d = drawWithDupes(c, owned, random, open); seen[d.tier.id] = (seen[d.tier.id] ?? 0) + 1; }
    return Object.fromEntries(Object.entries(seen).map(([id, k]) => [id, k / n]));
  };
  const near = (share, expected, what) => assert.ok(Math.abs(share - expected) < 0.008, `${what}: ${share} vs ${expected}`);
  // Legacy open: the shares are the weights (they add up to 100).
  const all = count(new Set(c.rarities.map(r => r.id)));
  for (const r of c.rarities) near(all[r.id] ?? 0, r.weight / 100, r.id);
  // Legacy locked: its chance goes to the others.
  const locked = count(openRarities(c, owned));
  assert.equal(locked.legacy, undefined);
  for (const r of c.rarities.filter(r => r.id !== 'legacy')) near(locked[r.id], r.weight / 94, r.id);
  // New packs change pool sizes. Per-item chances must stay in rarity order both before and
  // after every scheduled release, as well as in the complete bundled catalog. Tuning only for
  // the final catalog could make a blue figure rarer than a technician before a later launch.
  const releases = bundledContentReleases();
  const stages = [['bundled', c], ...releases.flatMap(release => [-1, 0].map(offset => {
    const at = new Date(Date.parse(release.startsAt) + offset);
    return [at.toISOString(), releasedCatalog(c, releases, at)];
  }))];
  for (const [stage, catalog] of stages) {
    const perItem = catalog.rarities.map(r => r.weight / catalog.collectible.filter(x => x.drawnBy.includes(r.id)).length);
    assert.ok(perItem.every((v, i) => i === 0 || v <= perItem[i - 1] + 1e-9), `${stage}: ${JSON.stringify(perItem)}`);
  }
});

// A small catalog: the person's figure p1 and its role p1r (an own rarity), like Elena and Johanna.
const small = () => loadCatalog({
  roleFigures: true,
  rarities: [{ id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 60, gage: 10 }, { id: 'blau', name: 'Blau', color: '#4B69FF', weight: 40, gage: 20 }],
  items: [
    ...['character', 'backdrop', 'obstacles', 'fx'].map(kind => ({ id: `${kind}.0`, kind, name: kind, rarity: 'hell', default: true })),
    { id: 'p1', kind: 'character', name: 'Pia', role: 'Lucy', play: 'Creepshow', year: 2026, rarity: 'hell', personId: 90, image: 'figure.webp', portrait: 'figure.webp', harness: { fly: [1, 2] } },
    { id: 'p1r', kind: 'character', name: 'Pia', role: 'Johanna', play: 'Anno 1146', year: 2025, rarity: 'blau', personId: 90, variantOf: 'p1', image: 'figure.webp', harness: { fly: [3, 4] } },
    { id: 'q1', kind: 'character', name: 'Quinn', role: 'Hades', play: 'Schicksalsfäden', year: 2025, rarity: 'blau', personId: 91, image: 'figure.webp' },
  ],
}, new URL('./fixtures/wardrobe/', import.meta.url));

test('older apps see the person\'s figure with its roles as variants, from the same ownership', t => {
  const { app, old } = setup(t, { catalog: small() });
  // Only the role is owned (it came from a crate): the older app sees the figure, wearing the role.
  old({ owned: ['p1r'], selected: { character: 'p1r' }, model: roleFiguresModel });
  const w = app.runnerWardrobe('sam');
  assert.deepEqual(w.catalog.items.filter(x => x.kind === 'character' && !x.default).map(x => x.id), ['p1', 'q1']);
  const p1 = w.catalog.items.find(x => x.id === 'p1');
  assert.deepEqual(p1.variants.map(v => [v.id, v.name, v.role, v.harness]), [['p1r', 'Johanna (Anno 1146, 2025)', 'Johanna', { fly: [3, 4] }]]);
  assert.match(p1.variants[0].image, /figure\.webp\?v=/);
  assert.ok(w.owned.includes('p1') && !w.owned.includes('p1r'));
  assert.deepEqual([w.variants, w.selected.character, w.selectedVariants], [['p1r'], 'p1', { p1: 'p1r' }]);
  // The same wardrobe for an app that knows role figures.
  const n = app.runnerWardrobe('sam', { roles: true });
  assert.deepEqual(n.catalog.items.filter(x => x.kind === 'character' && !x.default).map(x => x.id), ['p1', 'p1r', 'q1']);
  assert.ok(n.catalog.items.every(x => !x.variants));
  assert.deepEqual([n.owned.includes('p1'), n.owned.includes('p1r'), n.selected.character], [false, true, 'p1r']);
  // Dressing from an older app: a role, the figure itself (not owned here), or "keep the role".
  assert.throws(() => app.runnerOutfit('sam', { kind: 'character', itemId: 'p1', variant: null }), { status: 409, code: 'not_owned' });
  assert.throws(() => app.runnerOutfit('sam', { kind: 'character', itemId: 'p1', variant: 'q1' }), { status: 404 });
  assert.equal(app.runnerOutfit('sam', { kind: 'character', itemId: 'character.0' }).selected.character, 'character.0');
  const back = app.runnerOutfit('sam', { kind: 'character', itemId: 'p1' });
  assert.deepEqual([back.selected.character, back.selectedVariants], ['p1', { p1: 'p1r' }]);
  assert.equal(app.runnerWardrobe('sam', { roles: true }).selected.character, 'p1r');
  // New apps wear a figure by its id; a figure not owned is refused.
  assert.equal(app.runnerOutfit('sam', { kind: 'character', itemId: 'p1r', roles: true }).selected.character, 'p1r');
  assert.throws(() => app.runnerOutfit('sam', { kind: 'character', itemId: 'p1', roles: true }), { status: 409, code: 'not_owned' });
});

test('a role figure won by an older app shows as a new role of the person\'s figure', t => {
  // Dice: blau (0.7), the first missing one (p1r), no shine, reel …
  const { app, old, dice } = setup(t, { catalog: small(), fallback: 0.5 });
  old({ owned: ['p1'], model: roleFiguresModel });
  dice.push(0.7, 0, 0.99);
  const r = app.runnerOpenCrate('sam', 'k1', { dupes: true });
  assert.equal(r.item.id, 'p1');
  assert.deepEqual(r.item.variants.map(v => v.id), ['p1r']);
  assert.deepEqual([r.outcome.type, r.outcome.variant], ['variant', { id: 'p1r', name: 'Johanna (Anno 1146, 2025)', role: 'Johanna', play: 'Anno 1146', year: 2025 }]);
  assert.ok(!r.reel.includes('p1r'), 'the reel names only cards the older app knows');
  assert.deepEqual(r.wardrobe.variants, ['p1r']);
  // The same key again: the same answer.
  assert.deepEqual(app.runnerOpenCrate('sam', 'k1', { dupes: true }), r);
  // An app with role figures gets the figure itself.
  dice.push(0.7, 0, 0.99);
  const n = app.runnerOpenCrate('sam', 'k2', { dupes: true, roles: true });
  assert.deepEqual([n.item.id, n.outcome.type], ['q1', 'new']);
  assert.ok(n.wardrobe.owned.includes('p1r'));
});

test('servers announce role figures; the HTTP API gives them with ?roles=1 and variants without', async t => {
  assert.ok(apiFeatures.includes('runnerRoleFigures'));
  const { app, old } = setup(t);
  old({ owned: ['character.elena'], variants: ['character.elena--anno'] });
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  const get = async path => (await fetch(`${base}${path}`, { headers: { Authorization: 'Bearer sam' } })).json();
  const roles = await get('/games/runner/wardrobe?roles=1'), older = await get('/games/runner/wardrobe');
  assert.ok(roles.catalog.items.some(x => x.id === 'character.elena--anno'));
  assert.ok(roles.owned.includes('character.elena--anno'));
  assert.ok(!older.catalog.items.some(x => x.id === 'character.elena--anno'));
  assert.deepEqual(older.catalog.items.find(x => x.id === 'character.elena').variants.map(v => v.id), ['character.elena--anno', 'character.elena--schicksal', 'character.elena--nexus']);
  assert.ok(older.variants.includes('character.elena--anno'));
  // Raphael has no figure from before: older apps see Hades as a figure of its own.
  assert.equal(older.catalog.items.find(x => x.id === 'character.raphael--schicksal')?.role, 'Hades');
});
