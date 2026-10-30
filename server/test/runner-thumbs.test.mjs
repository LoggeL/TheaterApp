import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { copyFileSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { bundledCatalog, loadCatalog } from '../src/runner-wardrobe.mjs';
import { releasedCatalog } from '../src/runner-content-releases.mjs';

// The small pictures of the wardrobe's cards (`thumb`, the backdrops' `portrait`): made by
// tool/optimize-sprites.py from the committed pictures, gated like what they show.
const images = new URL('../src/wardrobe/images/', import.meta.url);
const fixtures = new URL('./fixtures/wardrobe/', import.meta.url);
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const fileOf = path => path.slice(path.lastIndexOf('/') + 1).split('?')[0];

/** Generated pictures that no longer belong to their source, by [manifest]. */
function outOfDate(manifest, folder, prefix = 'server/src/wardrobe/images/') {
  const names = readdirSync(folder), out = [];
  for (const name of names) {
    const made = name.startsWith('backdrop-') ? (name.endsWith('-portrait.webp') ? null : name.replace(/\.webp$/, '-portrait.webp'))
      : name.endsWith('-portrait.webp') ? name.replace(/-portrait\.webp$/, '-thumb.webp') : null;
    if (!made) continue;
    const entry = manifest[prefix + made];
    if (!names.includes(made)) out.push(`${made} is missing`);
    else if (entry?.sourceSha256 !== sha(readFileSync(new URL(name, folder)))) out.push(`${made} is older than ${name}`);
    else if (entry?.sha256 !== sha(readFileSync(new URL(made, folder)))) out.push(`${made} was changed by hand`);
  }
  return out;
}

const tool = new URL('../../tool/optimize-sprites.json', import.meta.url);

test('every thumbnail belongs to the portrait as it is now', () => {
  assert.deepEqual(outOfDate(JSON.parse(readFileSync(tool)), images), [], 'run python3 tool/optimize-sprites.py --write');
});

test('a re-exported portrait without a new thumbnail is noticed', t => {
  const dir = mkdtempSync(join(tmpdir(), 'runner-thumbs-')) + '/';
  t.after(() => rmSync(dir, { recursive: true }));
  const folder = pathToFileURL(dir);
  const figure = new URL('figure.webp', fixtures), other = new URL('../src/wardrobe/images/crate-random-fx.webp', import.meta.url);
  copyFileSync(figure, `${dir}character-a-portrait.webp`);
  copyFileSync(figure, `${dir}character-a-thumb.webp`);
  const portrait = readFileSync(`${dir}character-a-portrait.webp`);
  const manifest = { 'x/character-a-thumb.webp': { sha256: sha(portrait), sourceSha256: sha(portrait) } };
  assert.deepEqual(outOfDate(manifest, folder, 'x/'), []);
  copyFileSync(other, `${dir}character-a-portrait.webp`);
  assert.deepEqual(outOfDate(manifest, folder, 'x/'), ['character-a-thumb.webp is older than character-a-portrait.webp']);
  rmSync(`${dir}character-a-thumb.webp`);
  assert.deepEqual(outOfDate(manifest, folder, 'x/'), ['character-a-thumb.webp is missing']);
});

test('the catalog brings a thumbnail with every figure\'s portrait and a square picture of every stage', () => {
  const c = bundledCatalog();
  const figures = c.items.filter(x => x.kind === 'character' && x.portrait);
  assert.ok(figures.length > 100);
  for (const x of figures) {
    assert.match(x.thumb, /^\/games\/runner\/skins\/character-.+-thumb\.webp\?v=[0-9a-f]{16}$/, x.id);
    const thumb = c.files.get(fileOf(x.thumb));
    assert.equal(x.thumb.split('v=')[1], thumb.hash, 'the link carries the hash of the thumbnail itself');
    assert.ok(thumb.bytes.length < c.files.get(fileOf(x.portrait)).bytes.length, `${x.id}: smaller than its portrait`);
  }
  const stages = c.items.filter(x => x.kind === 'backdrop' && x.image);
  assert.equal(stages.length, 8);
  for (const x of stages) {
    assert.equal(fileOf(x.portrait), fileOf(x.image).replace('.webp', '-portrait.webp'));
    assert.equal(x.thumb, undefined, 'the portrait of a stage already has the size of a thumbnail');
  }
});

const rarities = [{ id: 'blau', name: 'Blau', color: '#4B69FF', weight: 100, gage: 10 }];
const defaults = ['character', 'backdrop', 'obstacles', 'fx'].map(kind => ({ id: `${kind}.default`, kind, name: 'Standard', rarity: 'blau', default: true }));
const figure = (id, extra = {}) => ({ id, kind: 'character', name: id, rarity: 'blau', image: `${id}.webp`, portrait: `${id}-portrait.webp`, ...extra });

/** A folder with a portrait and a thumbnail each for [ids]. */
function pictures(t, ids) {
  const dir = mkdtempSync(join(tmpdir(), 'runner-thumbs-')) + '/';
  t.after(() => rmSync(dir, { recursive: true }));
  for (const id of ids) for (const name of [`${id}.webp`, `${id}-portrait.webp`, `${id}-thumb.webp`]) copyFileSync(new URL('figure.webp', fixtures), dir + name);
  return pathToFileURL(dir);
}

function setup(t, catalog) {
  const store = new Store(); t.after(() => store.close());
  const clock = { at: new Date('2026-10-18T10:00:00Z') };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.at, runnerCatalog: catalog, random: () => 0.5 });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  const personId = app.action('admin', { action: 'member.save', name: 'Sam' }, 'member').id;
  app.session({ uid: 'sam', name: 'Sam', email: 'sam@example.invalid', email_verified: true });
  app.action('admin', { action: 'account.approve', uid: 'sam', personId, version: 1, role: 'member' }, 'approve');
  return { app, store, personId };
}

test('a locked thumbnail answers like its locked portrait', t => {
  const folder = pictures(t, ['free', 'reward', 'unique']);
  const catalog = loadCatalog({
    rarities, roleFigures: true,
    ensemble: { every: 2, milestones: [{ km: 1, item: 'reward' }] },
    uniqueFigures: { rarity: { id: 'unique', name: 'Unique', color: '#B388FF', style: 'holo' } },
    items: [...defaults, figure('free', { role: 'Rolle', play: 'Creepshow', year: 2026, personId: 1, importance: 50, rarityReason: 'Testrolle' }), { ...figure('reward', { rarity: undefined }), kind: 'backdrop', reward: true, portrait: 'reward-portrait.webp' },
      { ...figure('unique', { rarity: 'unique' }), unlock: { play: 'Creepshow' }, role: 'Figur', play: 'Creepshow', year: 2026 }],
  }, folder);
  assert.equal(catalog.byId.get('reward').thumb.split('?')[0], '/games/runner/skins/reward-thumb.webp');
  const { app } = setup(t, catalog);
  assert.ok(app.runnerSkin('sam', 'free-thumb.webp'));
  for (const name of ['reward-thumb.webp', 'reward-portrait.webp', 'unique-thumb.webp', 'unique-portrait.webp']) {
    assert.throws(() => app.runnerSkin('sam', name), { status: 404 }, name);
  }
});

test('a scheduled pack keeps its thumbnails back and leaves the others served', t => {
  const folder = pictures(t, ['free', 'future']);
  const base = loadCatalog({ rarities, roleFigures: false, items: [...defaults, figure('free'), figure('future')] }, folder);
  const release = { id: 'pack', name: 'Pack', startsAt: '2026-12-01T00:00:00.000Z', itemIds: ['future'], gatedItemIds: [], freeItemIds: [] };
  const before = releasedCatalog(base, [release], new Date('2026-11-01T00:00:00Z'));
  assert.ok(before.files.has('free-thumb.webp'), 'a thumbnail is a file of the catalog like the portrait');
  assert.ok(before.files.has('free-portrait.webp'));
  assert.ok(!before.files.has('future-thumb.webp'));
  assert.ok(!before.files.has('future-portrait.webp'));
});

test('a repeated crate key gives an equal catalog, which is not stored', t => {
  const ids = ['one', 'two', 'three'], folder = pictures(t, ids);
  const catalog = loadCatalog({ rarities, roleFigures: false, items: [...defaults, ...ids.map(id => figure(id))] }, folder);
  const { app, store, personId } = setup(t, catalog);
  app.runnerWardrobe('sam');
  store.put('runnerProgress', personId, { ...store.get('runnerProgress', personId), points: 1e6 });
  for (const [key, body] of [['new', { dupes: true, roles: true, unique: true }], ['old', {}]]) {
    const first = app.runnerOpenCrate('sam', key, body);
    const row = store.db.prepare('SELECT result FROM requests WHERE uid=? AND request_id LIKE ?').get('sam', `%${key}`);
    assert.equal(JSON.parse(row.result).wardrobe.catalog, undefined);
    assert.ok(JSON.parse(row.result).wardrobe.owned);
    const again = app.runnerOpenCrate('sam', key, body);
    assert.deepEqual(again.wardrobe.catalog, JSON.parse(JSON.stringify(first.wardrobe.catalog)));
    assert.deepEqual({ ...again, wardrobe: null }, JSON.parse(JSON.stringify({ ...first, wardrobe: null })));
  }
});

test('a result stored with its catalog still comes back as it is', t => {
  const folder = pictures(t, ['free']);
  const catalog = loadCatalog({ rarities, roleFigures: false, items: [...defaults, figure('free')] }, folder);
  const { app, store } = setup(t, catalog);
  const stored = { item: { id: 'free' }, wardrobe: { catalog: { items: ['from before'] }, owned: [] } };
  store.db.prepare('INSERT INTO requests VALUES(?,?,?,?,?)').run('sam', 'runner-buy:old', 'runner.buy', JSON.stringify(stored), new Date().toISOString());
  assert.deepEqual(app.runnerBuy('sam', 'old', { itemId: 'free' }), stored);
});
