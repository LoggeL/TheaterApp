import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
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

// Across plays (from 0.11.5): `unlock: { plays }` needs all active role figures of every one of them.
// Gruft: two more role figures; the figure across Spuk and Gruft is apart from Spuk's own.
const gruft = [role('g1', 906, 'Gruft', 2024), role('g2', 907, 'Gruft', 2024, { rarity: 'gold' })];
const hase = { id: 'u.hase', kind: 'character', name: 'Hase Hoppel', role: 'Hase Hoppel', play: 'Spuk', year: 2026, rarity: 'unique', unlock: { plays: ['Spuk', 'Gruft'] }, rarityReason: 'Seit 2020 dabei.', image: 'figure.webp' };
const acrossOf = (extra = []) => catalogOf([...defaults, ...figures, ...gruft, kuschel, waiting, hase, ...extra]);

test('across plays: the catalog checks unlock.plays and keeps { play } as it was', () => {
  const c = acrossOf();
  assert.deepEqual(c.uniques.map(x => x.id), ['u.spuk', 'u.hase']);
  assert.deepEqual(c.byId.get('u.hase').unlock, { plays: ['Spuk', 'Gruft'] });
  // The old form stays exactly as it was.
  assert.deepEqual(c.byId.get('u.spuk').unlock, { play: 'Spuk' });
  assert.deepEqual(catalogOf([...defaults, ...figures, { ...kuschel, unlock: { play: 'Spuk', year: 2026 } }]).byId.get('u.spuk').unlock, { play: 'Spuk', year: 2026 });
  // A play with its year.
  assert.deepEqual(acrossOf().byId.get('u.hase').unlock, { plays: ['Spuk', 'Gruft'] });
  assert.deepEqual(catalogOf([...defaults, ...figures, ...gruft, { ...hase, unlock: { plays: ['Spuk', { play: 'Gruft', year: 2024 }] } }]).byId.get('u.hase').unlock, { plays: ['Spuk', { play: 'Gruft', year: 2024 }] });
  assert.ok(!c.collectible.includes(c.byId.get('u.hase')));
  assert.deepEqual(c.byId.get('u.hase').drawnBy, []);
  const bad = (items, why = /Wardrobe catalog/) => assert.throws(() => catalogOf([...defaults, ...figures, ...gruft, ...items]), why);
  bad([{ ...hase, unlock: { plays: ['Spuk'] } }]);
  bad([{ ...hase, unlock: { plays: [] } }]);
  bad([{ ...hase, unlock: { plays: 'Spuk' } }]);
  bad([{ ...hase, unlock: { plays: ['Spuk', 'Spuk'] } }], /a play twice/);
  bad([{ ...hase, unlock: { plays: ['Spuk', 'Unbekannt'] } }], /no role figure of Unbekannt/);
  bad([{ ...hase, unlock: { plays: ['Spuk', { play: 'Gruft', year: 1999 }] } }], /no role figure of Gruft/);
  bad([{ ...hase, unlock: { plays: ['Spuk', ''] } }]);
  bad([{ ...hase, unlock: { plays: ['Spuk', { play: 'Gruft', year: '2024' }] } }]);
  bad([{ ...hase, unlock: { play: 'Spuk', plays: ['Spuk', 'Gruft'] } }]);
  bad([{ ...hase, unlock: { year: 2026, plays: ['Spuk', 'Gruft'] } }]);
  // One figure per set of plays, in whatever order, a waiting one counted.
  bad([hase, { ...hase, id: 'u.hase2', unlock: { plays: ['Gruft', 'Spuk'] }, disabled: true }], /one unique figure per play/);
  // Next to the single plays' own figures: fine.
  catalogOf([...defaults, ...figures, ...gruft, kuschel, hase, { ...kuschel, id: 'u.gruft', play: 'Gruft', year: 2024, unlock: { play: 'Gruft' } }]);
});

test('across plays: only Spuk complete unlocks Spuk\'s figure, not the one across Spuk and Gruft', t => {
  const { app, give, saved } = setup(t, { catalog: acrossOf() });
  give(['r1', 'r2']);
  let w = app.runnerWardrobe('sam', now);
  // One entry for both plays: the plays named together, the progress summed up and per play.
  const hidden = { play: 'Spuk und Gruft', plays: [{ play: 'Spuk', year: 2026, have: 2, total: 3 }, { play: 'Gruft', year: 2024, have: 0, total: 2 }], have: 2, total: 5, unlocked: false, hidden: true, name: '???' };
  assert.deepEqual(w.uniqueFigures.plays, [{ play: 'Spuk', year: 2026, have: 2, total: 3, unlocked: false, hidden: true, name: '???' }, hidden]);
  assert.deepEqual(leaks(w, [...secrets, 'u.hase', 'Hase', 'Hoppel', 'Seit 2020']), []);
  assert.throws(() => app.runnerOutfit('sam', { kind: 'character', itemId: 'u.hase', ...now }), { status: 404, message: 'Dieses Teil gibt es nicht.' });
  // Spuk complete: its own figure, the one across plays still hidden.
  give(['r1', 'r2', 'r3']);
  w = app.runnerWardrobe('sam', now);
  assert.deepEqual(saved().uniques, ['u.spuk']);
  assert.ok(w.owned.includes('u.spuk') && !w.owned.includes('u.hase'));
  assert.deepEqual(w.uniqueFigures.plays[1], { ...hidden, plays: [{ ...hidden.plays[0], have: 3 }, hidden.plays[1]], have: 3 });
  assert.deepEqual(w.uniqueFigures.unseen, ['u.spuk']);
  assert.deepEqual(leaks(w, ['u.hase', 'Hase', 'Hoppel', 'Seit 2020']), []);
  // Gruft complete and Spuk not is not enough either.
  give(['r1', 'g1', 'g2']);
  assert.deepEqual(app.runnerWardrobe('sam', now).uniqueFigures.plays[1].plays.map(x => x.have), [1, 2]);
  assert.equal(saved().uniques, undefined);
});

test('across plays: both complete unlock it, here with the last role figure bought', t => {
  const { app, give, saved } = setup(t, { catalog: acrossOf() });
  give(['r1', 'r2', 'r3', 'g2'], { gage: 500 });
  assert.deepEqual(app.runnerWardrobe('sam', now).uniqueFigures.plays[1].have, 4);
  assert.deepEqual(saved().uniques, ['u.spuk']);
  const deal = app.runnerBuy('sam', 'b-g1', { itemId: 'g1', ...now });
  const w = deal.wardrobe;
  assert.ok(w.owned.includes('u.hase'));
  assert.deepEqual(saved().uniques, ['u.spuk', 'u.hase']);
  assert.deepEqual(w.uniqueFigures.plays[1], { play: 'Spuk und Gruft', plays: [{ play: 'Spuk', year: 2026, have: 3, total: 3 }, { play: 'Gruft', year: 2024, have: 2, total: 2 }], have: 5, total: 5, unlocked: true, itemId: 'u.hase', name: 'Hase Hoppel', unlockedAt: '2026-10-24T10:00:00.000Z' });
  assert.deepEqual(w.uniqueFigures.unseen, ['u.spuk', 'u.hase']);
  assert.deepEqual(w.catalog.uniques.map(x => [x.id, JSON.stringify(x.unlock)]), [['u.spuk', '{"play":"Spuk"}'], ['u.hase', '{"plays":["Spuk","Gruft"]}']]);
  assert.equal(app.runnerOutfit('sam', { kind: 'character', itemId: 'u.hase', ...now }).selected.character, 'u.hase');
  // Kim has neither.
  assert.deepEqual(leaks(app.runnerWardrobe('kim', now), ['u.hase', 'Hoppel']), []);
  // Apps from before see nothing of it.
  assert.deepEqual(leaks(app.runnerWardrobe('sam', { roles: true }), ['u.hase', 'Hoppel', 'Spuk und Gruft']), []);
});

test('across plays: a play without active role figures unlocks nothing and shows nothing', t => {
  // Gruft's figures all wait for their pictures: the figure across plays is left out.
  const catalog = catalogOf([...defaults, ...figures, ...gruft.map(x => ({ ...x, disabled: true })), kuschel, hase]);
  const { app, give, saved } = setup(t, { catalog });
  give(['r1', 'r2', 'r3']);
  const w = app.runnerWardrobe('sam', now);
  assert.deepEqual(w.uniqueFigures.plays.map(x => x.play), ['Spuk']);
  assert.deepEqual(saved().uniques, ['u.spuk']);
  // The year of a play comes from its role figures if unlock names none, and no year if they differ.
  const mixed = catalogOf([...defaults, ...figures, ...gruft, role('g3', 908, 'Gruft', 2025), hase]);
  const { app: other } = setup(t, { catalog: mixed });
  assert.deepEqual(other.runnerWardrobe('sam', now).uniqueFigures.plays[0].plays[1], { play: 'Gruft', have: 0, total: 3 });
});

test('all technicians: actors do not count, hidden until complete, permanent after new technicians arrive', t => {
  const kolping = { id: 'u.kolping', kind: 'character', name: 'Adolph Kolping', role: 'Adolph Kolping', rarity: 'unique', unlock: { allTechnicians: true }, image: 'figure.webp' };
  const tech = (id, personId, extra = {}) => ({ id, kind: 'character', name: id, role: 'Ton', rarity: 'crew', personId, ...extra });
  const items = [...defaults, ...figures, tech('tech1', 910), tech('tech2', 911), tech('waiting', 912, { disabled: true }), kolping];
  const collectionCatalog = entries => catalogOf(entries, { rarities: [...rarities, { id: 'crew', name: 'Technik', color: '#4A8B6D', weight: 1, crew: true }] });
  const c = collectionCatalog(items);
  const { app, give, saved } = setup(t, { catalog: c });
  give(['r1', 'r2', 'r3', 'a1', 'tech1']);
  let w = app.runnerWardrobe('sam', now);
  assert.deepEqual(w.uniqueFigures.plays[0], {
    play: 'Technik', allTechnicians: true,
    plays: [{ play: 'Technik', have: 1, total: 2 }],
    have: 1, total: 2, unlocked: false, hidden: true, name: '???',
  });
  assert.deepEqual(leaks(w, ['u.kolping', 'Adolph Kolping', 'figure.webp']), []);
  assert.throws(() => app.runnerSkin('sam', 'figure.webp'), { status: 404 });
  // Every actor is owned, but one missing technician still blocks the unlock.
  assert.equal(w.uniqueFigures.plays[0].unlocked, false);
  // All technicians alone are sufficient; neither current nor legacy actor roles are needed.
  give(['tech1', 'tech2']);
  w = app.runnerWardrobe('sam', now);
  assert.equal(w.uniqueFigures.plays[0].unlocked, true);
  assert.equal(w.catalog.uniques[0].name, 'Adolph Kolping');
  assert.deepEqual(saved().uniques, ['u.kolping']);
  assert.ok(!c.collectible.some(x => x.id === kolping.id));
  assert.equal(app.runnerOutfit('sam', { kind: 'character', itemId: kolping.id, ...now }).selected.character, kolping.id);
  assert.equal(app.runnerSkin('sam', 'figure.webp').mime, 'image/webp');
  assert.deepEqual(leaks(app.runnerWardrobe('sam', { roles: true }), ['u.kolping', 'Adolph Kolping']), []);
  app.runnerCatalog = collectionCatalog([...items, role('new', 913, 'Neues Stück', 2027)]);
  give(['tech1', 'tech2']);
  assert.equal(app.runnerWardrobe('sam', now).uniqueFigures.plays[0].unlocked, true, 'new actor roles do not affect the technician collection');
  app.runnerCatalog = collectionCatalog([...items, tech('tech3', 914)]);
  w = app.runnerWardrobe('sam', now);
  assert.deepEqual([w.uniqueFigures.plays[0].have, w.uniqueFigures.plays[0].total, w.uniqueFigures.plays[0].unlocked], [2, 3, true]);
  give(['tech1', 'tech2']);
  assert.equal(app.runnerWardrobe('sam', now).uniqueFigures.plays[0].unlocked, false, 'new collectors also need the newly added technician');
  // No active technicians must not unlock a figure for free, even with actor roles present.
  const empty = setup(t, { catalog: collectionCatalog([...defaults, ...figures, tech('waiting', 912, { disabled: true }), kolping]) });
  assert.deepEqual(empty.app.runnerWardrobe('sam', now).uniqueFigures.plays, []);
  for (const unlock of [{ allTechnicians: false }, { allTechnicians: true, play: 'Spuk' }, { allTechnicians: true, plays: ['Spuk', 'Alt'] }, { allTechnicians: true, year: 2026 }]) {
    assert.throws(() => catalogOf([...defaults, ...figures, { ...kolping, unlock }]), /allTechnicians/);
  }
  assert.throws(() => collectionCatalog([...items, { ...kolping, id: 'u.duplicate', disabled: true }]), /one unique figure for all technicians/);
});

test('the bundled catalog: play-specific uniques and Kolping for the complete technician collection', t => {
  const c = bundledCatalog();
  assert.equal(c.uniqueRarity.id, 'unique');
  assert.equal(c.uniqueRarity.style, 'holo');
  // Every active unique figure has its picture, portrait and wire points.
  for (const u of c.uniques) assert.ok(u.image && u.portrait && u.harness, u.id);
  assert.deepEqual(c.uniques.map(x => [x.id, JSON.stringify(x.unlock)]), [
    ['character.unique-beatrice', '{"play":"Creepshow"}'],
    ['character.unique-ki-nexus', '{"play":"Nexus"}'],
    ['character.unique-captain-kuschel', '{"plays":["Creepshow","Nexus"]}'],
    ['character.unique-adolph-kolping', '{"allTechnicians":true}'],
  ]);
  assert.deepEqual([...c.uniqueFiles.keys()].sort(), ['character-unique-adolph-kolping-portrait.webp', 'character-unique-adolph-kolping.webp', 'character-unique-beatrice-portrait.webp', 'character-unique-beatrice.webp', 'character-unique-captain-kuschel-portrait.webp', 'character-unique-captain-kuschel.webp', 'character-unique-ki-nexus-portrait.webp', 'character-unique-ki-nexus.webp']);
  const raw = JSON.parse(readFileSync(new URL('../src/wardrobe/catalog.json', import.meta.url), 'utf8')).items;
  const beatrice = c.byId.get('character.unique-beatrice');
  assert.deepEqual([beatrice.name, beatrice.play, beatrice.year, beatrice.unlock], ['Beatrice', 'Creepshow', 2026, { play: 'Creepshow' }]);
  // The others still wait for their pictures.
  assert.deepEqual(raw.filter(x => x.rarity === 'unique' && x.disabled).map(x => x.id),
    ['character.unique-ritterpuppe', 'character.unique-willi', 'character.unique-kristall', 'character.unique-rabe']);
  // Logge's role "KI" in Nexus is gone: the AI is a unique figure.
  assert.ok(!raw.some(x => x.id === 'character.logge--nexus'));
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  const w = app.runnerWardrobe('admin', now);
  assert.deepEqual(w.uniqueFigures.plays.map(x => [x.play, x.year]), [['Creepshow', 2026], ['Nexus', 2024], ['Creepshow und Nexus', undefined], ['Technik', undefined]]);
  const [creepshow, nexus, across] = w.uniqueFigures.plays;
  assert.deepEqual(across.plays.map(x => [x.play, x.year]), [['Creepshow', 2026], ['Nexus', 2024]]);
  // Kuschel needs exactly the role figures of Beatrice and of the AI together.
  assert.deepEqual([across.plays[0].total, across.plays[1].total], [creepshow.total, nexus.total]);
  assert.equal(across.total, creepshow.total + nexus.total);
  for (const p of w.uniqueFigures.plays) assert.ok(p.total > 0 && p.hidden, p.play);
  assert.deepEqual(w.catalog.uniques, []);
  const all = w.uniqueFigures.plays[3];
  assert.equal(all.allTechnicians, true);
  assert.equal(all.total, c.collectible.filter(x => x.kind === 'character' && x.rarities.some(id => c.rarities.some(r => r.id === id && r.crew))).length);
  assert.equal(all.total, 8);
  assert.deepEqual(leaks(w, ['Kuschel', 'KI Nexus', 'unique-', 'Beatrice', 'Adolph Kolping']), []);
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
