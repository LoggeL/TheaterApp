import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { bundledCatalog, loadCatalog, shinyChanceOf } from '../src/runner-wardrobe.mjs';
import { milestoneAt, reachedMilestones } from '../src/runner-ensemble.mjs';

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
const fixtures = new URL('./fixtures/wardrobe/', import.meta.url);
// 1 km: a backdrop whose picture is still missing; 2 km: only the crate; 5 km: an effect; then every 10 km.
const ensemble = { every: 10, milestones: [{ km: 1, item: 'bd.anno' }, { km: 2 }, { km: 5, item: 'fx.gold', note: 'Premiere' }] };
const items = (picture = 'not-there-yet.webp') => [...defaults,
  { id: 'h1', kind: 'character', name: 'Hell 1', rarity: 'hell' },
  { id: 'g1', kind: 'character', name: 'Gold 1', rarity: 'gold' },
  { id: 'bd.anno', kind: 'backdrop', name: 'Anno 1146', reward: true, image: picture },
  { id: 'fx.gold', kind: 'fx', name: 'Goldregen', reward: true, effect: { trail: 'sparkle', colors: ['#E4AE39'] } },
];
const catalogOf = picture => loadCatalog({ rarities, items: items(picture), ensemble }, fixtures);

function setup(t, { catalog = catalogOf() } = {}) {
  const store = new Store(); t.after(() => store.close());
  const clock = { now: new Date('2026-10-24T10:00:00Z') };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.now, runnerCatalog: catalog, random: () => 0.99 });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let n = 0;
  const action = body => app.action('admin', body, `e-${++n}`);
  const member = (uid, name) => {
    const personId = action({ action: 'member.save', name }).id;
    app.session({ uid, name, email: `${uid}@example.invalid`, email_verified: true });
    action({ action: 'account.approve', uid, personId, version: 1, role: 'member' });
    return personId;
  };
  const sam = member('sam', 'Sam Beispiel'), kim = member('kim', 'Kim Beispiel');
  const play = (uid, meters) => { const { roundId } = app.runnerStart(uid); clock.now = new Date(+clock.now + 600000); return app.runnerScore(uid, { roundId, score: meters, meters }); };
  return { store, app, action, member, sam, kim, play, clock };
}

test('milestones: the listed ones, then one every few km', () => {
  const e = catalogOf().ensemble;
  assert.deepEqual([0, 1, 2, 3, 4].map(i => milestoneAt(e, i).km), [1, 2, 5, 15, 25]);
  assert.deepEqual(reachedMilestones(e, 4999).map(m => m.km), [1, 2]);
  assert.deepEqual(reachedMilestones(e, 15000).map(m => m.km), [1, 2, 5, 15]);
  const b = bundledCatalog().ensemble;
  assert.deepEqual(b.milestones.map(m => m.km), [25, 50, 100, 175, 250, 350, 500, 650, 800, 1000]);
  assert.equal(milestoneAt(b, 10).km, 1250);
  assert.equal(b.milestones.at(-1).item, 'backdrop.romeo-julia');
});

test('the shared distance starts with everything run before, credit included, and grows with every run', t => {
  const { store, app, sam, kim, play } = setup(t);
  // Sam opened the wardrobe before (300 m credit + 200 m run); Kim only played 4 times back then.
  store.put('runnerProgress', sam, { personId: sam, meters: 500, creditedMeters: 300, creditedRounds: 2, opened: 0, owned: [], selected: {}, deaths: {} });
  store.put('runnerScores', kim, { personId: kim, best: 10, bestAt: null, rounds: 4, lastPlayedAt: null });
  assert.equal(app.runnerWardrobe('sam').ensemble.meters, 500 + 4 * 150);
  // Kim's first wardrobe credits Kim, but the ensemble had those metres already.
  assert.equal(app.runnerWardrobe('kim').progress.meters, 600);
  assert.equal(app.runnerWardrobe('kim').ensemble.meters, 1100);
  const run = play('kim', 700);
  assert.equal(run.progress.ensemble.gained, 700);
  assert.equal(run.progress.ensemble.meters, 1800);
  assert.equal(app.runnerWardrobe('sam').ensemble.meters, 1800);
});

test('a reached milestone gives every active member one Ensemble-Kiste, once', t => {
  const { store, app, action, member, sam, kim, play } = setup(t);
  const run = play('sam', 1200);
  assert.deepEqual(run.progress.ensemble.reached.map(m => [m.km, m.name]), [[1, 'Anno 1146']]);
  assert.deepEqual([run.progress.ensemble.next.km, run.progress.ensemble.next.name], [2, 'Ensemble-Kiste']);
  assert.equal(run.progress.ensembleCrates, 1);
  // Kim gets it with the next request, and only once.
  assert.equal(app.runnerWardrobe('kim').ensemble.crates, 1);
  assert.equal(app.runnerWardrobe('kim').ensemble.crates, 1);
  assert.deepEqual(store.get('runnerProgress', kim).ensembleGranted, [1]);
  // An inactive member gets nothing (and has no access) until active again.
  const lee = member('lee', 'Lee Beispiel');
  action({ action: 'member.save', id: lee, name: 'Lee Beispiel', active: false, version: store.get('members', lee).version });
  play('kim', 900);
  assert.throws(() => app.runnerWardrobe('lee'), { status: 403 });
  assert.equal(store.get('runnerProgress', lee), null);
  action({ action: 'member.save', id: lee, name: 'Lee Beispiel', active: true, version: store.get('members', lee).version });
  // Later active (or new): every milestone reached so far, 1 km and 2 km.
  assert.equal(app.runnerWardrobe('lee').ensemble.crates, 2);
  assert.equal(app.runnerWardrobe('sam').ensemble.crates, 2);
  assert.equal(sam > 0, true);
});

test('Ensemble-Kisten shine with their own chance and are counted apart from the own crates', t => {
  const { app, play } = setup(t);
  play('sam', 1200);
  assert.throws(() => app.runnerOpenCrate('sam', 'e0', { crate: 'ensemble' }), { status: 400 });
  // The dice show 0.99: above the 3 % of an Ensemble-Kiste, no shine.
  const opened = app.runnerOpenCrate('sam', 'e1', { dupes: true, crate: 'ensemble' });
  assert.deepEqual([opened.outcome.shiny, opened.outcome.crate, opened.outcome.type], [false, 'ensemble', 'new']);
  assert.deepEqual(opened.wardrobe.shiny, []);
  assert.equal(opened.wardrobe.ensemble.crates, 0);
  assert.equal(opened.wardrobe.progress.opened, 0, 'the own crates are untouched');
  assert.deepEqual(app.runnerOpenCrate('sam', 'e1', { dupes: true, crate: 'ensemble' }), opened);
  assert.throws(() => app.runnerOpenCrate('sam', 'e2', { dupes: true, crate: 'ensemble' }), { status: 409, code: 'no_crate' });
});

test('the chance of a shine is set per crate kind', t => {
  const sure = loadCatalog({ rarities, items: items(), ensemble, dupes: { shinyChance: { costume: 0, ensemble: 1 } } }, fixtures);
  assert.equal(shinyChanceOf(sure, 'ensemble'), 1);
  assert.equal(shinyChanceOf(sure, 'mission'), 0, 'a kind not listed has the chance of costume');
  assert.equal(shinyChanceOf(bundledCatalog(), 'costume'), 0.03);
  assert.equal(shinyChanceOf(bundledCatalog(), 'ensemble'), 0.03);
  const { app, store, sam, play } = setup(t, { catalog: sure });
  play('sam', 1200);
  assert.equal(app.runnerOpenCrate('sam', 'e1', { dupes: true, crate: 'ensemble' }).outcome.shiny, true);
  store.put('runnerProgress', sam, { ...store.get('runnerProgress', sam), meters: 100000 });
  assert.equal(app.runnerOpenCrate('sam', 'c1', { dupes: true }).outcome.shiny, false);
  // Shiny items won before (when Ensemble-Kisten always shone) stay shiny.
  app.runnerCatalog = catalogOf();
  assert.ok(app.runnerWardrobe('sam').shiny.length === 1);
});

test('a reward is everybody\'s once reached, as soon as its picture is there', t => {
  const { app, play } = setup(t);
  let w = app.runnerWardrobe('kim');
  assert.deepEqual(w.catalog.rewards.map(x => x.id), ['bd.anno', 'fx.gold']);
  assert.ok(!w.catalog.items.some(x => x.reward), 'older apps do not see rewards as costumes');
  assert.deepEqual(w.catalog.ensembleRarity, { id: 'ensemble', name: 'Ensemble', color: '#F28C28' });
  play('sam', 5200);
  w = app.runnerWardrobe('kim');
  // The effect is ready; the backdrop has no picture yet: "Belohnung wird vorbereitet".
  assert.ok(w.owned.includes('fx.gold'));
  assert.ok(!w.owned.includes('bd.anno'));
  assert.deepEqual(w.ensemble.milestones.slice(0, 3).map(m => [m.km, m.reached, m.reward?.ready ?? null]), [[1, true, false], [2, true, null], [5, true, true]]);
  assert.equal(w.ensemble.milestones[2].note, 'Premiere');
  assert.throws(() => app.runnerOutfit('kim', { kind: 'backdrop', itemId: 'bd.anno' }), { code: 'not_owned' });
  // Rewards never come from crates or the shop.
  assert.throws(() => app.runnerBuy('kim', 'b', { itemId: 'fx.gold' }), { status: 404 });
  // The picture arrives with a deployment: delivered without anything else to do.
  app.runnerCatalog = catalogOf('figure.webp');
  assert.ok(app.runnerWardrobe('kim').owned.includes('bd.anno'));
  assert.equal(app.runnerOutfit('kim', { kind: 'backdrop', itemId: 'bd.anno' }).selected.backdrop, 'bd.anno');
  // Not reached yet: not owned.
  const fresh = setup(t, { catalog: catalogOf('figure.webp') });
  assert.ok(!fresh.app.runnerWardrobe('kim').owned.includes('bd.anno'));
});

test('the celebration shows until it is marked seen', t => {
  const { app, play } = setup(t);
  play('sam', 2100);
  assert.deepEqual(app.runnerWardrobe('kim').ensemble.unseen, [1, 2]);
  assert.deepEqual(app.runnerEnsembleSeen('kim', { km: 2 }).ensemble.unseen, []);
  // Never past what is reached.
  assert.equal(app.runnerEnsembleSeen('kim', { km: 99 }).ensemble.unseen.length, 0);
  play('sam', 3000);
  assert.deepEqual(app.runnerWardrobe('kim').ensemble.unseen, [5]);
  assert.throws(() => app.runnerEnsembleSeen('kim', { km: 'x' }), { status: 400 });
});

test('own share and players of the current section, without a ranking', t => {
  const { app, play } = setup(t);
  play('sam', 300);
  play('kim', 200);
  play('kim', 100);
  assert.deepEqual(app.runnerWardrobe('kim').ensemble.section, { from: 0, own: 300, players: 2 });
  // Sam's run crosses 1 km: it still counts for the section it was run in; the next one starts empty.
  play('sam', 500);
  assert.deepEqual(app.runnerWardrobe('sam').ensemble.section, { from: 1, own: 0, players: 0 });
  play('sam', 50);
  assert.deepEqual(app.runnerWardrobe('kim').ensemble.section, { from: 1, own: 0, players: 1 });
});

test('deleting a person keeps their metres in the ensemble', async t => {
  const { app, action, store, kim, play } = setup(t);
  play('kim', 1500);
  await app.deleteAccount('admin', 'kim', store.account('kim').version);
  action({ action: 'member.delete', id: kim, version: store.get('members', kim).version });
  const w = app.runnerWardrobe('sam');
  assert.equal(w.ensemble.meters, 1500);
  assert.ok(w.ensemble.milestones[0].reached);
});

test('broken ensemble settings are refused', () => {
  const load = e => loadCatalog({ rarities, items: items(), ensemble: e });
  assert.throws(() => load({ every: 10, milestones: [{ km: 5 }, { km: 5 }] }), /km must grow/);
  assert.throws(() => load({ every: 0, milestones: [{ km: 1, item: 'bd.anno' }, { km: 2, item: 'fx.gold' }] }), /every/);
  assert.throws(() => load({ every: 10, milestones: [{ km: 1, item: 'nope' }] }), /missing/);
  // A reward without a milestone, or an item that is no reward on a milestone.
  assert.throws(() => load({ every: 10, milestones: [{ km: 1, item: 'bd.anno' }] }), /fx.gold needs exactly one/);
  assert.throws(() => load({ every: 10, milestones: [{ km: 1, item: 'bd.anno' }, { km: 2, item: 'fx.gold' }, { km: 3, item: 'h1' }] }), /h1 needs exactly one/);
});

test('the bundled rewards are the backdrops of earlier plays, Romeo und Julia at 1000 km', () => {
  const c = bundledCatalog();
  const named = c.ensemble.milestones.filter(m => m.item).map(m => [m.km, c.byId.get(m.item).name]);
  assert.deepEqual(named.filter(([, name]) => !['Goldregen', 'Applaus', 'Höllenglut', 'Schwanenfedern'].includes(name)), [
    [25, 'Anno 1146'], [100, 'Schicksalsfäden'], [250, 'Eine höllische Herausforderung'], [500, 'Nexus'], [800, 'Die Geschichte der Black Swan'], [1000, 'Romeo und Julia'],
  ]);
  for (const x of c.items.filter(x => x.reward)) {
    assert.ok(!c.collectible.includes(x), `${x.id} is not in crates`);
    if (x.kind === 'backdrop') assert.match(x.image ?? '', /^\/games\/runner\/skins\/backdrop-[a-z-]+\.webp\?v=/, x.id);
  }
  assert.equal(c.byId.get('backdrop.creepshow').reward, undefined, 'Creepshow stays a crate item');
});

test('the HTTP API marks the celebration seen', async t => {
  const { app, play } = setup(t);
  play('sam', 1100);
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const response = await fetch(`http://127.0.0.1:${server.address().port}/api/mobile/v1/games/runner/ensemble/seen`, { method: 'PUT', headers: { Authorization: 'Bearer sam', 'Content-Type': 'application/json' }, body: JSON.stringify({ km: 1 }) });
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).ensemble.unseen, []);
});
