import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures } from '../src/theater.mjs';
import { bundledCatalog, drawWithDupes, loadCatalog } from '../src/runner-wardrobe.mjs';

// Crates for gage (`runnerGageCrates`): a crate bought for `dupes.crateGage` opens at once like a
// crate of the own runs. Only the balance limits it, and a crate never brings back what it costs.

const rarities = [
  { id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 45, gage: 10 },
  { id: 'blau', name: 'Blau', color: '#4B69FF', weight: 21, gage: 20 },
  { id: 'technik', name: 'Technik', color: '#2FBF71', weight: 11, gage: 30, crew: true },
  { id: 'legacy', name: 'Legacy', color: '#A47A4B', weight: 6, gage: 50, requires: { rarity: 'hell', kind: 'character', count: 2 }, hint: 'Sammle 2 hellblaue Figuren' },
];
const defaults = [
  { id: 'c0', kind: 'character', name: 'Engel Logge', rarity: 'hell', default: true },
  { id: 'b0', kind: 'backdrop', name: 'Wand', rarity: 'hell', default: true },
  { id: 'o0', kind: 'obstacles', name: 'Lager', rarity: 'hell', default: true },
  { id: 'f0', kind: 'fx', name: 'Ohne', rarity: 'hell', default: true },
];
const role = (id, personId, play, year, rarity) => ({ id, kind: 'character', name: `Person ${personId}`, role: `Rolle ${id}`, play, year, rarity, personId });
const figures = [
  role('s1', 901, 'Spuk', 2026, 'hell'), role('s2', 902, 'Spuk', 2026, 'hell'), role('s3', 903, 'Spuk', 2026, 'blau'),
  // Only Legacy: locked until two light blue figures are owned.
  role('a1', 906, 'Altlasten', 2020, 'legacy'),
  { id: 't1', kind: 'character', name: 'Person 908', role: 'Licht', rarity: 'technik', personId: 908 },
];
const fixtures = new URL('./fixtures/wardrobe/', import.meta.url);
const catalogOf = (dupes = {}) => loadCatalog({ roleFigures: true, rarities, dupes: { shinyChance: { costume: 0.05, targeted: 0.03 }, ...dupes }, items: [...defaults, ...figures] }, fixtures);
const flags = { dupes: true, roles: true, crate: 'gage' };

function setup(t, { catalog = catalogOf(), fallback = 0.99 } = {}) {
  const store = new Store(); t.after(() => store.close());
  const dice = [];
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => new Date('2026-10-24T10:00:00Z'), runnerCatalog: catalog, random: () => dice.length ? dice.shift() : fallback, missionRules: null });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  const personId = app.action('admin', { action: 'member.save', name: 'Sam Beispiel' }, 'm1').id;
  app.session({ uid: 'sam', name: 'Sam', email: 'sam@example.invalid', email_verified: true });
  app.action('admin', { action: 'account.approve', uid: 'sam', personId, version: 1, role: 'member' }, 'm2');
  app.runnerWardrobe('sam');
  const progress = () => store.get('runnerProgress', personId);
  const patch = change => store.put('runnerProgress', personId, { ...progress(), ...change });
  return { store, app, dice, progress, patch };
}

test('the feature is announced and the price stands in the wardrobe', t => {
  const { app } = setup(t);
  assert.ok(apiFeatures.includes('runnerGageCrates'));
  assert.ok(app.snapshot('sam').capabilities.features.includes('runnerGageCrates'));
  assert.equal(app.runnerWardrobe('sam', { roles: true }).catalog.dupes.crateGage, 100);
  assert.equal(catalogOf({ crateGage: 250 }).dupes.crateGage, 250);
  assert.equal(bundledCatalog().dupes.crateGage, 100);
  for (const crateGage of [0, -5, 1.5, '100']) assert.throws(() => catalogOf({ crateGage }), /dupes\.crateGage/);
});

test('a crate bought opens at once; the balance sinks, the rest stays', t => {
  const { app, progress, patch, store } = setup(t);
  patch({ gage: 130, gageEarned: 400, points: 0 });
  const before = progress(), r = app.runnerOpenCrate('sam', 'buy-1', flags);
  const p = progress();
  assert.equal(p.gage, 30);
  assert.equal(p.gageEarned, 400);
  assert.equal(p.opened, before.opened);
  assert.equal(p.points, before.points);
  assert.equal(p.owned.length, before.owned.length + 1);
  assert.equal(r.outcome.type, 'new');
  assert.equal(r.outcome.crate, 'gage');
  assert.equal(r.outcome.target, 'random');
  assert.equal(r.outcome.cost, 100);
  assert.equal(r.wardrobe.gage.balance, 30);
  // No stock of any kind, no crate waiting after it.
  assert.equal(r.wardrobe.progress.crates, 0);
  assert.equal(store.all('runnerGalaPrizes').length, 0);
  assert.match(store.db.prepare("SELECT subject FROM audit WHERE action='runner.crate'").get().subject, /-100$/);
});

test('too little gage: 409 with its code and how much is missing; nothing is paid or drawn', t => {
  const { app, progress, patch } = setup(t);
  patch({ gage: 99 });
  const before = progress();
  assert.throws(() => app.runnerOpenCrate('sam', 'poor', flags), e => {
    assert.equal(e.status, 409);
    assert.equal(e.code, 'not_enough_gage');
    assert.equal(e.message, 'Für diese Kiste fehlen dir noch 1 Gage.');
    return true;
  });
  assert.deepEqual(progress(), before);
  // A failed key is not remembered: with the money it goes through.
  patch({ gage: 100 });
  assert.equal(app.runnerOpenCrate('sam', 'poor', flags).outcome.crate, 'gage');
  assert.equal(progress().gage, 0);
  // A record that never had gage.
  patch({ gage: undefined });
  assert.throws(() => app.runnerOpenCrate('sam', 'never', flags), { status: 409, code: 'not_enough_gage' });
});

test('a repeated key pays once and returns the same opening, also with the money spent', t => {
  const { app, progress, patch } = setup(t);
  patch({ gage: 100 });
  const first = app.runnerOpenCrate('sam', 'same', flags), owned = progress().owned;
  assert.deepEqual(app.runnerOpenCrate('sam', 'same', flags), first);
  assert.equal(progress().gage, 0);
  assert.deepEqual(progress().owned, owned);
});

test('it can be aimed like a crate of the own runs, with the same shine chances', t => {
  const { app, dice, progress, patch } = setup(t);
  patch({ gage: 1000 });
  // Tier, item, shine: 0.04 shines at the costume chance (5 %), not at the targeted one (3 %).
  dice.push(0, 0, 0.04);
  const aimed = app.runnerOpenCrate('sam', 'aim-1', { ...flags, target: 'play:spuk' });
  assert.equal(aimed.outcome.target, 'play:spuk');
  assert.equal(aimed.outcome.shiny, false);
  assert.ok(['s1', 's2', 's3'].includes(aimed.item.id));
  dice.push(0, 0, 0.04);
  const random = app.runnerOpenCrate('sam', 'aim-2', { ...flags, target: 'random' });
  assert.equal(random.outcome.target, 'random');
  assert.equal(random.outcome.shiny, true);
  assert.equal(progress().gage, 800);
});

test('a locked or unknown target costs nothing', t => {
  const { app, progress, patch } = setup(t);
  patch({ gage: 500 });
  assert.throws(() => app.runnerOpenCrate('sam', 'locked', { ...flags, target: 'play:altlasten' }), { status: 409, code: 'target_locked' });
  assert.throws(() => app.runnerOpenCrate('sam', 'unknown', { ...flags, target: 'play:nirgends' }), { status: 400, code: 'unknown_target' });
  assert.equal(progress().gage, 500);
});

test('older apps cannot buy: 400, nothing paid, their own crates untouched', t => {
  const { app, progress, patch } = setup(t);
  patch({ gage: 500 });
  assert.throws(() => app.runnerOpenCrate('sam', 'old', { crate: 'gage' }), { status: 400 });
  assert.equal(progress().gage, 500);
  assert.throws(() => app.runnerOpenCrate('sam', 'own', { dupes: true, roles: true }), { status: 409, code: 'no_crate' });
});

test('a full collection pays first and adds the duplicate on top, as earned', t => {
  const { app, dice, progress, patch } = setup(t);
  const all = [...defaults, ...figures].map(x => x.id);
  patch({ gage: 100, gageEarned: 7, owned: all, shiny: all });
  dice.push(0, 0, 0.5);
  const r = app.runnerOpenCrate('sam', 'dup', flags);
  assert.equal(r.outcome.type, 'gage');
  assert.equal(r.outcome.duplicate, true);
  assert.equal(progress().gage, r.outcome.gage);
  assert.equal(progress().gageEarned, 7 + r.outcome.gage);
  assert.ok(r.outcome.gage < 100);
});

test('only the balance limits buying: no count, no day limit, no waiting', t => {
  const { app, progress, patch } = setup(t);
  patch({ gage: 5000 });
  for (let i = 0; i < 50; i++) app.runnerOpenCrate('sam', `many-${i}`, flags);
  assert.ok(progress().gage <= 5000 - 50 * 100 + 50 * 50, 'each crate paid');
  patch({ gage: 0 });
  assert.throws(() => app.runnerOpenCrate('sam', 'broke', flags), { code: 'not_enough_gage' });
});

/**
 * What a crate brings back at most, in gage: for every crate there is and every set of rarities a
 * person may have locked, a full collection with every shine, so that each draw pays. Goes through
 * the real draw on a fine grid of dice. A crate bought must stay below `crateGage`, or gage multiplies.
 */
function bestReturn(c) {
  const lockable = c.rarities.filter(r => r.requires), owned = new Set(c.items.map(x => x.id));
  const pools = [['random', c.collectible], ...c.crateTargets.filter(x => x.kind !== 'random').map(x => [x.id, c.targetItems.get(x.id)])];
  const steps = 2000;
  let best = { value: 0 };
  for (let mask = 0; mask < 1 << lockable.length; mask++) {
    const locked = new Set(lockable.filter((_, i) => mask & 1 << i).map(r => r.id));
    const open = new Set(c.rarities.map(r => r.id).filter(id => !locked.has(id)));
    for (const [id, pool] of pools) {
      if (!pool.some(x => x.drawnBy.some(r => open.has(r)))) continue;
      let sum = 0;
      for (let i = 0; i < steps; i++) sum += drawWithDupes(c, owned, () => (i + .5) / steps, open, pool).tier.gage;
      const value = sum / steps;
      if (value > best.value) best = { value, id, locked: [...locked] };
    }
  }
  return best;
}

test('no money machine: no crate of the bundled catalog brings back what it costs', () => {
  const c = bundledCatalog(), best = bestReturn(c);
  assert.ok(best.value < c.dupes.crateGage, `${best.id} brings ${best.value} Gage, a crate costs ${c.dupes.crateGage}`);
  // The Zufallskiste, without anything locked, by the weights alone.
  const total = c.rarities.reduce((sum, r) => sum + r.weight, 0);
  const plain = c.rarities.reduce((sum, r) => sum + r.weight * r.gage, 0) / total;
  assert.ok(plain > 15 && plain < 30, `the Zufallskiste brings ${plain} Gage`);
  assert.ok(best.value >= plain);
});

test('the check notices a price that would make money', () => {
  const c = bundledCatalog(), best = bestReturn(c);
  const cheap = { ...c, dupes: { ...c.dupes, crateGage: Math.floor(best.value) } };
  assert.ok(bestReturn(cheap).value >= cheap.dupes.crateGage);
  // More gage per duplicate moves the return, too.
  const rich = catalogOf();
  for (const r of rich.rarities) r.gage = 1000;
  assert.ok(bestReturn(rich).value >= rich.dupes.crateGage);
});
