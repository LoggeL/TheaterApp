import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { crateMilestone, loadCatalog } from '../src/runner-wardrobe.mjs';
import { giftFigure, ownFiguresModel } from '../src/runner-own-figures.mjs';
import { parseContentReleases } from '../src/runner-content-releases.mjs';

// Own figures (`runnerGiftFigure`): only the most common own role figure is a gift, the others are
// collected; records from before keep what they owned; Engel Logge only for people without a gift.
// And the Sammel-Rangliste (`runnerCollection`).

const rarities = [
  { id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 60, gage: 10 },
  { id: 'blau', name: 'Blau', color: '#4B69FF', weight: 30, gage: 20 },
  { id: 'tech', name: 'Technik', color: '#888888', weight: 10, gage: 20, crew: true },
  { id: 'legacy', name: 'Legacy', color: '#C0C0C0', weight: 6, gage: 30, requires: { rarity: 'hell', kind: 'character', count: 4 }, hint: 'Sammle 4 hellblaue Figuren' },
  { id: 'gold', name: 'Gold', color: '#E4AE39', weight: 2, gage: 200, buyable: false, exclusive: true },
];
const defaults = [
  { id: 'c0', kind: 'character', name: 'Engel Logge', rarity: 'hell', default: true },
  { id: 'b0', kind: 'backdrop', name: 'Wand', rarity: 'hell', default: true },
  { id: 'o0', kind: 'obstacles', name: 'Lager', rarity: 'hell', default: true },
  { id: 'f0', kind: 'fx', name: 'Ohne', rarity: 'hell', default: true },
];
const fixtures = new URL('./fixtures/wardrobe/', import.meta.url);
const uniqueFigures = { rarity: { id: 'unique', name: 'Unique', color: '#B388FF', style: 'holo' } };
/** A role figure of [personId] with a picture; `image: undefined` for one without. */
const fig = (id, personId, rarity, extra = {}) => ({ id, kind: 'character', name: `Person ${personId}`, role: `Rolle ${id}`, play: 'Spuk', year: 2026, rarity, personId, image: 'figure.webp', ...extra });
const catalogOf = items => loadCatalog({ roleFigures: true, rarities, uniqueFigures, items: [...defaults, ...items] }, fixtures);

test('the gift is the most common own figure with a picture, then the least important, then by id', () => {
  const c = catalogOf([
    fig('s.gold', 1, 'gold', { importance: 90, play: 'Alt', year: 2020 }),
    fig('s.blau', 1, 'blau', { importance: 30, play: 'Neu', year: 2027 }),
    fig('s.hell2', 1, 'hell', { importance: 20 }),
    fig('s.hell1', 1, 'hell', { importance: 20, play: 'Alt', year: 2020 }),
    fig('s.hell3', 1, 'hell', { importance: 40, play: 'Neu', year: 2027 }),
    // Without a picture, or waiting: no gift.
    fig('s.hell0', 1, 'hell', { importance: 5, play: 'Bald', year: 2028, image: undefined }),
    fig('s.waiting', 1, 'hell', { importance: 1, play: 'Später', year: 2029, disabled: true }),
    // Legacy in its place among the rarities (below gold), also when still locked.
    fig('l.gold', 2, 'gold', { importance: 50 }), fig('l.legacy', 2, 'legacy', { importance: 80, play: 'Alt', year: 2020 }),
    // A technician is one figure.
    { id: 't.1', kind: 'character', name: 'Person 3', role: 'Licht', rarity: 'tech', personId: 3, image: 'figure.webp' },
    // Without importance: after those with one.
    fig('n.none', 5, 'hell', { importance: undefined }), fig('n.some', 5, 'hell', { importance: 50, play: 'Alt', year: 2020 }),
  ]);
  assert.equal(giftFigure(c, 1).id, 's.hell1');
  assert.equal(giftFigure(c, 2).id, 'l.legacy');
  assert.equal(giftFigure(c, 3).id, 't.1');
  assert.equal(giftFigure(c, 5).id, 'n.some');
  // No own figure (or none with a picture): no gift.
  assert.equal(giftFigure(c, 4), null);
  assert.equal(giftFigure(catalogOf([fig('x', 6, 'hell', { image: undefined })]), 6), null);
  assert.ok(apiFeatures.includes('runnerGiftFigure') && apiFeatures.includes('runnerCollection'));
});

/** Members sam, kim (no own figure), lee and ina, then the catalog with their person ids. */
function setup(t, { dice = [], fallback = 0.99, items = null } = {}) {
  const store = new Store(); t.after(() => store.close());
  const clock = { now: new Date('2026-10-29T10:00:00Z') };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.now, runnerCatalog: catalogOf([]), random: () => dice.length ? dice.shift() : fallback, missionRules: null });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let n = 0;
  const member = (uid, name) => {
    const personId = app.action('admin', { action: 'member.save', name }, `m-${++n}`).id;
    app.session({ uid, name, email: `${uid}@example.invalid`, email_verified: true });
    app.action('admin', { action: 'account.approve', uid, personId, version: 1, role: 'member' }, `m-${++n}`);
    return personId;
  };
  const sam = member('sam', 'Sam'), kim = member('kim', 'Kim'), lee = member('lee', 'Lee'), ina = member('ina', 'Ina');
  // Spuk: two of Sam's figures and one of Lee's unlock the unique figure.
  const base = [
    fig('s.hell1', sam, 'hell', { importance: 10 }), fig('s.hell2', sam, 'hell', { importance: 20, play: 'Alt', year: 2020 }),
    fig('s.gold', sam, 'gold', { importance: 90, play: 'Neu', year: 2027 }),
    fig('s.noimg', sam, 'blau', { importance: 30, play: 'Bald', year: 2028, image: undefined }),
    fig('l.hell', lee, 'hell', { importance: 10 }),
    fig('x.legacy', 999, 'legacy', { importance: 50, play: 'Alt', year: 2020 }),
    { id: 'bd.1', kind: 'backdrop', name: 'Saal', rarity: 'blau', image: 'figure.webp' },
    { id: 'fx.1', kind: 'fx', name: 'Funken', rarity: 'hell', effect: { trail: 'sparkle' } },
    { id: 'u.spuk', kind: 'character', name: 'Geist', role: 'Geist', play: 'Spuk', year: 2026, rarity: 'unique', unlock: { play: 'Spuk' }, image: 'figure.webp' },
  ];
  app.runnerCatalog = catalogOf(items ? items({ sam, kim, lee, base }) : base);
  const saved = (id = sam) => store.get('runnerProgress', id);
  const patch = (id, change) => store.put('runnerProgress', id, { ...saved(id), ...change });
  // A record as the server before gift figures left it (no `ownFigures`).
  const old = (id, record = {}) => store.put('runnerProgress', id, { personId: id, meters: 0, creditedMeters: 0, creditedRounds: 0, opened: 0, owned: [], selected: {}, deaths: {}, createdAt: '2026-10-01T10:00:00.000Z', model: 2, crateModel: 1, basePoints: 0, points: 0, ...record });
  return { store, app, clock, sam, kim, lee, ina, saved, patch, old };
}
const now = { roles: true, unique: true };

test('a new player owns only the gift: no Engel Logge, the other own figures come from crates', t => {
  const { app, saved, patch, sam } = setup(t, { fallback: 0 });
  const w = app.runnerWardrobe('sam', now);
  assert.deepEqual(w.owned.filter(id => id.startsWith('s.') || id === 'c0'), ['s.hell1']);
  assert.deepEqual([w.gift, w.hiddenDefaults, w.selected.character], ['s.hell1', ['c0'], 's.hell1']);
  // The defaults of the other kinds stay owned; the catalog still lists Engel Logge for older apps.
  assert.ok(['b0', 'o0', 'f0'].every(id => w.owned.includes(id)));
  assert.ok(w.catalog.items.some(x => x.id === 'c0' && x.default));
  const s = saved();
  assert.deepEqual([s.ownFigures, s.gift, s.owned, s.ownFiguresKept], [ownFiguresModel, 's.hell1', ['s.hell1'], undefined]);
  // Spuk is not complete with the gift alone.
  assert.equal(w.uniqueFigures.plays[0].have, 1);
  // The other own figures are in the pool (s.noimg too: drawable, only no gift).
  const pool = w.crateTargets.find(x => x.id === 'random');
  assert.deepEqual([pool.owned, pool.total], [1, 8]);
  // Missing are 7, Legacy (x.legacy) is still locked.
  assert.equal(w.progress.poolSize, 6);
  // dice 0: light blue, its first missing figure (Sam's own s.hell2), shiny.
  patch(sam, { points: crateMilestone(2) });
  const opened = app.runnerOpenCrate('sam', 'k-1', { dupes: true, ...now });
  assert.equal(opened.item.id, 's.hell2');
  assert.deepEqual([opened.outcome.type, opened.outcome.shiny], ['new', true]);
  assert.ok(opened.wardrobe.owned.includes('s.hell2') && opened.wardrobe.shiny.includes('s.hell2'));
  // All light blue owned: a duplicate, the gift can get its shine like any figure.
  patch(sam, { owned: [...saved().owned, 'l.hell', 'fx.1'] });
  const dupe = app.runnerOpenCrate('sam', 'k-2', { dupes: true, ...now });
  assert.deepEqual([dupe.item.id, dupe.outcome.duplicate, dupe.outcome.type], ['s.hell1', true, 'shine']);
  // The gift is kept: a more common own figure added later does not swap it.
  app.runnerCatalog = catalogOf([fig('s.first', sam, 'hell', { importance: 1, play: 'Früh', year: 2019 }), fig('s.hell1', sam, 'hell', { importance: 10 })]);
  const later = app.runnerWardrobe('sam', now);
  assert.equal(later.gift, 's.hell1');
  assert.ok(!later.owned.includes('s.first'));
});

test('Engel Logge only for people without an own figure; worn or not owned falls back to the gift', t => {
  const { app, sam } = setup(t);
  // Kim has no own figure: Engel Logge as always.
  const k = app.runnerWardrobe('kim', now);
  assert.deepEqual([k.gift, k.hiddenDefaults, k.selected.character], [null, [], 'c0']);
  assert.ok(k.owned.includes('c0'));
  assert.equal(app.runnerOutfit('kim', { kind: 'character', itemId: 'c0', ...now }).selected.character, 'c0');
  // Sam cannot wear Engel Logge (older apps take every default for owned: a clear refusal).
  app.runnerWardrobe('sam', now);
  assert.throws(() => app.runnerOutfit('sam', { kind: 'character', itemId: 'c0', ...now }), { status: 409, code: 'not_owned', message: /Ersatzfigur/ });
  assert.throws(() => app.runnerOutfit('sam', { kind: 'character', itemId: 'c0' }), { status: 409, code: 'not_owned' });
  assert.throws(() => app.runnerOutfit('sam', { kind: 'character', itemId: 's.gold', ...now }), { status: 409, code: 'not_owned' });
  // Older apps see the same: Engel Logge not owned, the gift worn.
  const older = app.runnerWardrobe('sam');
  assert.deepEqual([older.owned.includes('c0'), older.owned.includes('s.hell1'), older.selected.character], [false, true, 's.hell1']);
  // A figure worn that is gone from the catalog: back to the gift, not Engel Logge.
  app.runnerCatalog = catalogOf([fig('s.hell1', sam, 'hell', { importance: 10 }), fig('s.hell2', sam, 'hell', { importance: 20, play: 'Alt', year: 2020 })]);
  app.store.put('runnerProgress', sam, { ...app.store.get('runnerProgress', sam), owned: ['s.hell1', 's.hell2'] });
  assert.equal(app.runnerOutfit('sam', { kind: 'character', itemId: 's.hell2', ...now }).selected.character, 's.hell2');
  app.runnerCatalog = catalogOf([fig('s.hell1', sam, 'hell', { importance: 10 })]);
  assert.equal(app.runnerWardrobe('sam', now).selected.character, 's.hell1');
  // The gift itself gone (disabled again): Engel Logge is back as the stand-in, the gift waits.
  app.runnerCatalog = catalogOf([]);
  const gone = app.runnerWardrobe('sam', now);
  assert.deepEqual([gone.gift, gone.hiddenDefaults, gone.selected.character], [null, [], 'c0']);
  assert.equal(app.store.get('runnerProgress', sam).gift, 's.hell1');
});

test('a gift waits for its picture: until then Engel Logge', t => {
  const { app, saved, sam } = setup(t, { items: ({ sam }) => [fig('s.1', sam, 'hell', { image: undefined })] });
  const w = app.runnerWardrobe('sam', now);
  assert.deepEqual([w.gift, w.selected.character, w.owned.includes('c0'), w.owned.includes('s.1')], [null, 'c0', true, false]);
  assert.equal(saved().ownFigures, ownFiguresModel);
  app.runnerCatalog = catalogOf([fig('s.1', sam, 'hell')]);
  const later = app.runnerWardrobe('sam', now);
  assert.deepEqual([later.gift, later.selected.character, later.owned.includes('c0'), later.owned.includes('s.1')], ['s.1', 's.1', false, true]);
});

test('records from before keep every own figure they owned, once; uniques and Legacy stay', t => {
  const { app, store, saved, old, sam, lee } = setup(t);
  // Sam wore Engel Logge and owned Lee's figure from a crate: with his own two Spuk figures (owned
  // under the old rule) Spuk is complete.
  old(sam, { owned: ['l.hell'], selected: { character: 'c0' } });
  const w = app.runnerWardrobe('sam', now);
  // All own figures at the switch, the one without a picture too; the gift among them.
  assert.ok(['s.hell1', 's.hell2', 's.gold', 's.noimg', 'l.hell'].every(id => w.owned.includes(id)));
  assert.deepEqual([w.gift, w.selected.character, w.owned.includes('c0')], ['s.hell1', 's.hell1', false]);
  assert.ok(w.owned.includes('u.spuk'));
  const s = saved();
  assert.deepEqual([s.ownFigures, s.ownFiguresAt, s.ownFiguresKept], [ownFiguresModel, '2026-10-29T10:00:00.000Z', ['s.hell1', 's.hell2', 's.gold', 's.noimg']]);
  assert.deepEqual(s.owned, ['l.hell', 's.hell1', 's.hell2', 's.gold', 's.noimg']);
  assert.deepEqual(store.get('runnerOwnFigures', 'cutover').figures[sam], ['s.hell1', 's.hell2', 's.gold', 's.noimg']);
  // Once: asked again nothing changes.
  const before = JSON.stringify(saved());
  app.runnerWardrobe('sam', now);
  assert.equal(JSON.stringify(saved()), before);
  // Lee's record from before, moved later: an own figure added after the switch is not kept.
  old(lee, {});
  app.runnerCatalog = catalogOf([fig('l.hell', lee, 'hell', { importance: 10 }), fig('l.late', lee, 'blau', { importance: 5, play: 'Neu', year: 2027 })]);
  const l = app.runnerWardrobe('lee', now);
  assert.deepEqual([l.owned.includes('l.hell'), l.owned.includes('l.late'), l.gift], [true, false, 'l.hell']);
  // Unlocked before stays unlocked, also with fewer figures now: unique figures and Legacy.
  old(lee, { ownFigures: ownFiguresModel, gift: 'l.hell', owned: ['l.hell'], uniques: ['u.spuk'], unlockedRarities: ['legacy'] });
  app.runnerCatalog = catalogOf([fig('l.hell', lee, 'hell', { importance: 10 }), fig('s.hell1', sam, 'hell'), fig('x.legacy', 999, 'legacy'),
    { id: 'u.spuk', kind: 'character', name: 'Geist', role: 'Geist', play: 'Spuk', year: 2026, rarity: 'unique', unlock: { play: 'Spuk' }, image: 'figure.webp' }]);
  const kept = app.runnerWardrobe('lee', now);
  assert.ok(kept.owned.includes('u.spuk'));
  assert.ok(!kept.lockedRarities.includes('legacy'));
  assert.equal(kept.uniqueFigures.plays[0].unlocked, true);
});

test('people who played before the wardrobe existed keep their own figures; new ones do not', t => {
  const { app, store, saved, sam, lee } = setup(t);
  store.put('runnerScores', sam, { personId: sam, best: 300, bestAt: null, rounds: 3, lastPlayedAt: null });
  const w = app.runnerWardrobe('sam', now);
  assert.ok(['s.hell1', 's.hell2', 's.gold', 's.noimg'].every(id => w.owned.includes(id)));
  assert.deepEqual([saved().creditedRounds, saved().ownFiguresKept.length, w.gift], [3, 4, 's.hell1']);
  // A first run after the switch creates the record before the run counts: only the gift.
  const { roundId } = app.runnerStart('lee');
  app.runnerScore('lee', { roundId, score: 0, meters: 0 });
  assert.deepEqual([saved(lee).owned, saved(lee).gift, saved(lee).ownFiguresKept], [['l.hell'], 'l.hell', undefined]);
});

test('the Sammel-Rangliste: most collected first, shiny and name break ties, equal ones share a rank', async t => {
  const { app, store, patch, sam, kim, lee, ina } = setup(t);
  for (const uid of ['sam', 'kim', 'lee', 'ina']) app.runnerWardrobe(uid, now);
  // Countable: s.hell1, s.hell2, s.gold, l.hell, x.legacy, bd.1, fx.1 and u.spuk; not s.noimg (no picture), not the defaults.
  patch(sam, { owned: ['s.hell1', 's.hell2', 'fx.1', 'c0', 'gone'], shiny: ['s.hell2', 'b0', 's.noimg'] });
  patch(kim, { owned: ['bd.1', 'x.legacy', 'fx.1'], shiny: ['x.legacy'] });
  patch(lee, { owned: ['l.hell'] });
  // Ina is no active member any more, the admin never played: neither is listed.
  store.put('members', ina, { ...store.get('members', ina), active: false });
  const board = app.runnerCollection('kim');
  assert.equal(board.total, 8);
  assert.deepEqual(board.entries, [
    { personId: kim, name: 'Kim', owned: 3, shiny: 1, percent: 37.5, rank: 1, me: true },
    { personId: sam, name: 'Sam', owned: 3, shiny: 1, percent: 37.5, rank: 1, me: false },
    { personId: lee, name: 'Lee', owned: 1, shiny: 0, percent: 12.5, rank: 3, me: false },
  ]);
  // Nobody's record was changed or created by it.
  assert.equal(store.get('runnerProgress', app.account('admin').personId), null);
  // A record from before counts as it will be moved: with all own figures of the switch.
  store.put('runnerProgress', ina, { personId: ina, owned: [], selected: {}, opened: 0, meters: 0, model: 2, crateModel: 1 });
  store.put('members', ina, { ...store.get('members', ina), active: true });
  store.put('runnerOwnFigures', 'cutover', { ...store.get('runnerOwnFigures', 'cutover'), figures: { [ina]: ['s.gold', 'bd.1'] } });
  const withIna = app.runnerCollection('sam');
  assert.deepEqual(withIna.entries.map(x => [x.name, x.owned, x.rank, x.me]), [['Kim', 3, 1, false], ['Sam', 3, 1, true], ['Ina', 2, 3, false], ['Lee', 1, 4, false]]);
  assert.equal(store.get('runnerProgress', ina).ownFigures, undefined);
  // Over HTTP, signed in like the Bestenliste.
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const response = await fetch(`http://127.0.0.1:${server.address().port}/api/mobile/v1/games/runner/collection`, { headers: { Authorization: 'Bearer lee' } });
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.total, 8);
  assert.deepEqual(body.entries.filter(x => x.me).map(x => x.name), ['Lee']);
});

test('the wardrobe sends the own numbers of the Sammel-Rangliste: free items, pictures and unique figures alike', t => {
  const { app, patch, sam } = setup(t, { items: ({ base }) => [...base, { id: 'bd.free', kind: 'backdrop', name: 'Geschenk', rarity: 'hell', image: 'figure.webp' }] });
  // A release gives everybody bd.free: owned, but not counted.
  app.runnerReleases = parseContentReleases([{ id: 'gift-pack', name: 'Geschenk', startsAt: '2026-10-01T00:00:00Z', freeItemIds: ['bd.free'] }]);
  app.runnerWardrobe('sam', now);
  // All Spuk figures (s.hell1, s.hell2, l.hell) unlock u.spuk; s.noimg has no picture.
  patch(sam, { owned: ['s.hell1', 's.hell2', 'l.hell', 's.noimg', 'fx.1'], shiny: ['s.hell2', 's.noimg', 'bd.free', 'u.spuk'] });
  const w = app.runnerWardrobe('sam', now);
  assert.ok(w.owned.includes('bd.free') && w.owned.includes('u.spuk') && w.owned.includes('s.noimg'));
  assert.deepEqual(w.collection, { owned: 5, total: 8, shiny: 2, free: ['bd.free'] });
  const mine = app.runnerCollection('sam');
  const entry = mine.entries.find(x => x.me);
  assert.deepEqual({ owned: w.collection.owned, total: w.collection.total, shiny: w.collection.shiny }, { owned: entry.owned, total: mine.total, shiny: entry.shiny });
  // Apps from before unique figures and role figures get the same numbers.
  const older = app.runnerWardrobe('sam');
  assert.deepEqual(older.collection, w.collection);
  assert.ok(!older.owned.includes('u.spuk'));
});
