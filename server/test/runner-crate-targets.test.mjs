import test from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { bundledCatalog, crateAnimations, crateMilestone, loadCatalog, playSlug } from '../src/runner-wardrobe.mjs';

// Crate targets (`runnerCrateTargets`): a crate of the own runs opens as the Zufallskiste (all
// items, as before, with the better shine chance) or aimed at a play's role figures or the
// technicians. The rarity weights hold within the chosen pool; unique figures are in no pool.

const rarities = [
  { id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 45, gage: 10 },
  { id: 'blau', name: 'Blau', color: '#4B69FF', weight: 21, gage: 20 },
  { id: 'technik', name: 'Technik', color: '#2FBF71', weight: 11, gage: 30, crew: true },
  { id: 'legacy', name: 'Legacy', color: '#A47A4B', weight: 6, gage: 50, requires: { rarity: 'hell', kind: 'character', count: 2 }, hint: 'Sammle 2 hellblaue Figuren' },
  { id: 'gold', name: 'Gold', color: '#E4AE39', weight: 1.5, gage: 200, exclusive: true, buyable: false },
];
const defaults = [
  { id: 'c0', kind: 'character', name: 'Engel Logge', rarity: 'hell', default: true },
  { id: 'b0', kind: 'backdrop', name: 'Wand', rarity: 'hell', default: true },
  { id: 'o0', kind: 'obstacles', name: 'Lager', rarity: 'hell', default: true },
  { id: 'f0', kind: 'fx', name: 'Ohne', rarity: 'hell', default: true },
];
const role = (id, personId, play, year, rarity, extra = {}) => ({ id, kind: 'character', name: `Person ${personId}`, role: `Rolle ${id}`, play, year, rarity, personId, ...extra });
const figures = [
  // Spuk 2026: four role figures (one gold), one waiting for its picture.
  role('s1', 901, 'Spuk', 2026, 'hell'), role('s2', 902, 'Spuk', 2026, 'hell'), role('s3', 903, 'Spuk', 2026, 'blau'), role('s4', 904, 'Spuk', 2026, 'gold'),
  role('s5', 905, 'Spuk', 2026, 'hell', { disabled: true }),
  // Altlasten 2020: only Legacy, locked until two light blue figures are owned.
  role('a1', 906, 'Altlasten', 2020, 'legacy'), role('a2', 907, 'Altlasten', 2020, 'legacy'),
  // Two technicians: a function, no play.
  { id: 't1', kind: 'character', name: 'Person 908', role: 'Licht', rarity: 'technik', personId: 908 },
  { id: 't2', kind: 'character', name: 'Person 909', role: 'Ton', rarity: 'technik', personId: 909 },
  // Only in the Zufallskiste: a backdrop and an effect.
  { id: 'bd', kind: 'backdrop', name: 'Blaue Wand', rarity: 'blau' },
  { id: 'fx1', kind: 'fx', name: 'Funken', rarity: 'hell', effect: { trail: 'sparkle', colors: ['#FFFFFF'] } },
];
const spukGeist = { id: 'u.spuk', kind: 'character', name: 'Spukgeist', role: 'Spukgeist', play: 'Spuk', year: 2026, rarity: 'unique', unlock: { play: 'Spuk' }, image: 'figure.webp' };
const fixtures = new URL('./fixtures/wardrobe/', import.meta.url);
const dupes = { shinyChance: { costume: 0.05, targeted: 0.03 } };
const catalogOf = (extra = {}, dir = fixtures) => loadCatalog({ roleFigures: true, rarities, uniqueFigures: { rarity: { id: 'unique', name: 'Unique', color: '#B388FF' } }, dupes, items: [...defaults, ...figures, spukGeist], ...extra }, dir);

function setup(t, { catalog = catalogOf(), fallback = 0.99 } = {}) {
  const store = new Store(); t.after(() => store.close());
  const dice = [];
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => new Date('2026-10-24T10:00:00Z'), runnerCatalog: catalog, random: () => dice.length ? dice.shift() : fallback, missionRules: null });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  const personId = app.action('admin', { action: 'member.save', name: 'Sam Beispiel' }, 'm1').id;
  app.session({ uid: 'sam', name: 'Sam', email: 'sam@example.invalid', email_verified: true });
  app.action('admin', { action: 'account.approve', uid: 'sam', personId, version: 1, role: 'member' }, 'm2');
  const patch = change => { app.runnerWardrobe('sam'); const p = store.get('runnerProgress', personId); store.put('runnerProgress', personId, { ...p, ...change(p) }); };
  patch(() => ({ points: crateMilestone(20) }));
  let key = 0;
  /** Opens a crate as the new app does; [roll] are the next dice. */
  const open = (target, ...roll) => { dice.push(...roll); return app.runnerOpenCrate('sam', `t${++key}`, { dupes: true, roles: true, unique: true, ...(target ? { target } : {}) }); };
  const own = (...ids) => patch(p => ({ owned: [...p.owned, ...ids] }));
  const view = () => app.runnerWardrobe('sam', { roles: true, unique: true });
  const targetOf = (w, id) => w.crateTargets.find(x => x.id === id);
  return { store, app, dice, personId, open, own, patch, view, targetOf };
}

test('the targets come from the catalog: the Zufallskiste, the technicians and every play with role figures', () => {
  const c = catalogOf();
  assert.deepEqual(c.crateTargets.map(x => [x.id, x.kind, x.name, x.year]), [
    ['random', 'random', 'Zufallskiste', undefined], ['tech', 'tech', 'Technik-Kiste', undefined],
    ['play:spuk', 'play', 'Spuk', 2026], ['play:altlasten', 'play', 'Altlasten', 2020],
  ]);
  const ids = id => c.targetItems.get(id).map(x => x.id);
  assert.deepEqual(ids('play:spuk'), ['s1', 's2', 's3', 's4'], 'no waiting figure, no unique figure');
  assert.deepEqual(ids('tech'), ['t1', 't2']);
  assert.deepEqual(ids('random').sort(), ['a1', 'a2', 'bd', 'fx1', 's1', 's2', 's3', 's4', 't1', 't2']);
  // No pool holds a unique figure, an ensemble reward or a default.
  for (const items of c.targetItems.values()) assert.ok(items.every(x => !x.unique && !x.reward && !x.default));
  // Without a look in the catalog every crate opens with the generic animation.
  assert.ok(c.crateTargets.every(x => x.animation === 'generic' && !x.image));
});

test('ids and file names follow the play: umlauts spelled out, the year only when a name repeats', () => {
  assert.deepEqual(['Schicksalsfäden', 'Anno 1146', 'Eine höllische Herausforderung', 'Größenwahn!'].map(playSlug), ['schicksalsfaeden', 'anno-1146', 'eine-hoellische-herausforderung', 'groessenwahn']);
  const c = catalogOf({ items: [...defaults, ...figures, role('x1', 950, 'Spuk', 2019, 'hell')] });
  assert.deepEqual(c.crateTargets.filter(x => x.kind === 'play').map(x => x.id), ['play:spuk-2026', 'play:altlasten', 'play:spuk-2019']);
});

test('a crate brings its pictures by name and its animation from the catalog', t => {
  const dir = mkdtempSync(join(tmpdir(), 'crates-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  for (const name of ['crate-random.webp', 'crate-play-spuk.webp', 'crate-play-spuk-open.webp', 'crate-play-spuk-fx.webp']) copyFileSync(new URL('figure.webp', fixtures), join(dir, name));
  const c = catalogOf({ crates: { note: 'Looks.', random: { animation: 'burst', box: [40, 180, 470, 492] }, tech: { box: [1, 2, 3, 4] }, 'play:spuk': { animation: 'maw' } } }, pathToFileURL(`${dir}/`));
  const [random, tech, spuk] = c.crateTargets;
  assert.equal(random.animation, 'burst');
  assert.match(random.image, /^\/games\/runner\/skins\/crate-random\.webp\?v=/);
  assert.equal(random.openImage, undefined, 'only what is there');
  assert.deepEqual(random.imageBox, [40, 180, 470, 492]);
  assert.equal(tech.animation, 'generic');
  assert.equal(tech.imageBox, undefined, 'a box only with its picture');
  assert.deepEqual([spuk.animation, !!spuk.image, !!spuk.openImage, !!spuk.fxImage], ['maw', true, true, true]);
  assert.ok(c.files.has('crate-play-spuk-fx.webp'), 'served like the other pictures');
  // A look for a crate that does not exist, or an animation the app does not know, breaks the catalog.
  assert.throws(() => catalogOf({ crates: { 'play:nirgends': { animation: 'maw' } } }), /crates/);
  assert.throws(() => catalogOf({ crates: { random: { animation: 'feuerwerk' } } }), /crates/);
  for (const box of [[0, 0, 10], [10, 0, 5, 5], [0, 0, 5.5, 5], 'oben']) assert.throws(() => catalogOf({ crates: { random: { box } } }), /crates\.random\.box/);
});

test('the bundled catalog aims at the plays with role figures and the technicians, each with its animation', () => {
  const c = bundledCatalog();
  assert.deepEqual(c.crateTargets.map(x => [x.id, x.animation]), [
    ['random', 'burst'], ['tech', 'flightcase'], ['play:creepshow', 'maw'], ['play:anno-1146', 'heavy'], ['play:schicksalsfaeden', 'threads'], ['play:nexus', 'glitch'],
  ]);
  assert.ok(c.crateTargets.every(x => crateAnimations.includes(x.animation)));
  // Every crate has its three pictures and where it stands on them.
  for (const x of c.crateTargets) {
    const file = x.id.replace(':', '-');
    for (const [field, name] of [['image', ''], ['openImage', '-open'], ['fxImage', '-fx']]) assert.match(x[field] ?? '', new RegExp(`^/games/runner/skins/crate-${file}${name}\\.webp\\?v=`), `${x.id} ${field}`);
    const [x0, y0, x1, y1] = x.imageBox;
    assert.ok(x0 >= 0 && y0 > 100 && x1 <= 512 && y1 <= 512 && x1 - x0 > 300, `${x.id} box`);
  }
  // The Zufallskiste shines more often than an aimed one.
  assert.ok(c.dupes.shinyChance.costume > c.dupes.shinyChance.targeted);
  assert.deepEqual([c.dupes.shinyChance.costume, c.dupes.shinyChance.targeted], [0.05, 0.03]);
  for (const x of c.crateTargets.filter(x => x.kind === 'play')) assert.ok(c.targetItems.get(x.id).every(i => i.play === x.play && i.year === x.year && !i.unique));
  assert.ok(c.targetItems.get('tech').every(i => i.rarities.includes('technik')));
});

test('the wardrobe lists every target with its progress, locks and odds within it', t => {
  const { view, own, targetOf } = setup(t);
  own('s1', 's3');
  const w = view();
  const spuk = targetOf(w, 'play:spuk');
  assert.deepEqual([spuk.owned, spuk.total, spuk.locked, spuk.complete, spuk.available], [2, 4, 0, false, true]);
  // The weights among the rarities in the pool: 45 + 21 + 1,5.
  assert.deepEqual(spuk.odds.map(o => [o.rarity, Math.round(o.chance * 1000) / 1000]), [['hell', 0.667], ['blau', 0.311], ['gold', 0.022]]);
  assert.equal(spuk.shinyChance, 0.03);
  const alt = targetOf(w, 'play:altlasten');
  assert.deepEqual([alt.owned, alt.total, alt.locked, alt.available, alt.odds], [0, 2, 2, false, []]);
  const tech = targetOf(w, 'tech');
  assert.deepEqual([tech.total, tech.odds], [2, [{ rarity: 'technik', chance: 1 }]]);
  const random = targetOf(w, 'random');
  assert.deepEqual([random.owned, random.total, random.locked, random.shinyChance], [2, 10, 2, 0.05]);
});

test('an aimed crate draws only from its pool, the weights within it; the reel shows only the pool', t => {
  const { open } = setup(t);
  // 0.98 of the weights: gold in Spuk (66 of 67,5 passed), technik in the Zufallskiste (66 of 78,5).
  const spuk = open('play:spuk', 0.98, 0);
  assert.equal(spuk.item.id, 's4');
  assert.deepEqual([spuk.outcome.crate, spuk.outcome.target, spuk.outcome.rarity], ['costume', 'play:spuk', 'gold']);
  assert.ok(spuk.reel.every(id => ['s1', 's2', 's3', 's4'].includes(id)), spuk.reel.join());
  const random = open(null, 0.98, 0);
  assert.equal(random.outcome.target, 'random');
  assert.equal(random.outcome.rarity, 'technik');
  // The Technik-Kiste: only technicians.
  for (let i = 0; i < 2; i++) assert.ok(['t1', 't2'].includes(open('tech', i / 2, 0).item.id));
});

test('a complete pool still opens and brings a duplicate: shine or gage', t => {
  const { open, own, view, targetOf } = setup(t);
  own('t1', 't2');
  assert.equal(targetOf(view(), 'tech').complete, true);
  const dupe = open('tech', 0, 0);
  assert.deepEqual([dupe.outcome.type, dupe.outcome.duplicate, dupe.outcome.gage], ['gage', true, 30]);
  // A shiny duplicate makes the figure shiny instead (targeted chance 3 %).
  const shine = open('tech', 0, 0, 0.02);
  assert.deepEqual([shine.outcome.type, shine.outcome.shiny], ['shine', true]);
});

test('legacy opens only after 10 (here 2) light blue figures, also in an aimed crate', t => {
  const { open, own, view, targetOf } = setup(t);
  assert.throws(() => open('play:altlasten'), { status: 409, code: 'target_locked', message: 'Sammle 2 hellblaue Figuren' });
  // Nothing is used up: the crate is still there.
  assert.equal(view().progress.opened, 0);
  own('s1', 's2');
  assert.equal(targetOf(view(), 'play:altlasten').available, true);
  assert.ok(['a1', 'a2'].includes(open('play:altlasten', 0, 0).item.id));
});

test('unique figures never come from a crate, whatever its target', t => {
  const { open, own, view } = setup(t);
  own('s1', 's2', 's3', 's4');
  // All of Spuk owned: the unique figure is unlocked, but never drawn.
  assert.ok(view().owned.includes('u.spuk'));
  for (let i = 0; i < 6; i++) {
    const r = open('play:spuk', i / 6, i / 6);
    assert.notEqual(r.item.id, 'u.spuk');
    assert.ok(!r.reel.includes('u.spuk'));
    assert.equal(r.outcome.duplicate, true);
  }
});

test('the Zufallskiste shines more often than an aimed crate', t => {
  const { open } = setup(t);
  // The third die decides the shine: 0.04 is below 5 % but not below 3 %.
  assert.equal(open(null, 0, 0, 0.04).outcome.shiny, true);
  assert.equal(open('play:spuk', 0, 0, 0.04).outcome.shiny, false);
  assert.equal(open('play:spuk', 0, 0, 0.02).outcome.shiny, true);
});

test('older apps open without a target: that is the Zufallskiste; a target needs the new app', t => {
  const { app, open } = setup(t);
  // An app before runnerDupes: no target, the old draw.
  const older = app.runnerOpenCrate('sam', 'old-1', {});
  assert.ok(older.item.id);
  // An app with duplicates but before crate targets: the Zufallskiste.
  const r = app.runnerOpenCrate('sam', 'old-2', { dupes: true });
  assert.equal(r.outcome.target, 'random');
  assert.ok(Array.isArray(r.wardrobe.crateTargets), 'older apps ignore the list');
  assert.equal(open('random', 0, 0).outcome.target, 'random');
  assert.throws(() => app.runnerOpenCrate('sam', 'bad-1', { target: 'play:spuk' }), { status: 400 });
  assert.throws(() => open('play:nirgends'), { status: 400, code: 'unknown_target' });
  assert.throws(() => open(7), { status: 400, code: 'unknown_target' });
  assert.throws(() => app.runnerOpenCrate('sam', 'bad-2', { dupes: true, crate: 'mission', target: 'tech' }), { status: 400 });
  assert.equal(app.runnerWardrobe('sam').progress.opened, 3);
});

test('the same key opens the same aimed crate once', t => {
  const { app } = setup(t);
  const first = app.runnerOpenCrate('sam', 'same', { dupes: true, target: 'tech' });
  assert.deepEqual(app.runnerOpenCrate('sam', 'same', { dupes: true, target: 'tech' }), first);
  assert.equal(app.runnerWardrobe('sam').progress.opened, 1);
});
