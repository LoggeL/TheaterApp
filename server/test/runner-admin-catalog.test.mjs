import test from 'node:test';
import assert from 'node:assert/strict';
import { copyFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { bundledCatalog, loadCatalog } from '../src/runner-wardrobe.mjs';

// The admins' Skin-Viewer (`runnerAdminCatalog`): every entry with its state for admins, nothing of
// it for anybody else, and the members' picture route as strict as before.
const startsAt = '2026-11-08T17:00:00.000Z';
const fixture = new URL('./fixtures/wardrobe/figure.webp', import.meta.url);
// One picture per state, so a leak of each shows on its own.
const pictures = ['live.webp', 'live-portrait.webp', 'live-thumb.webp', 'future.webp', 'unique.webp', 'reward.webp', 'waiting.webp', 'waiting-portrait.webp', 'waiting-thumb.webp', 'waiting-unique.webp'];
function imageDir(t) {
  const dir = mkdtempSync(join(tmpdir(), 'runner-admin-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  for (const name of pictures) copyFileSync(fixture, join(dir, name));
  return pathToFileURL(`${dir}/`);
}
const data = {
  roleFigures: true,
  rarities: [
    { id: 'blue', name: 'Blau', color: '#0088FF', weight: 1, gage: 10 },
    { id: 'gold', name: 'Gold', color: '#E4AE39', weight: 0.1, gage: 50 },
  ],
  uniqueFigures: { rarity: { id: 'unique', name: 'Unique', color: '#B388FF', style: 'holo' } },
  ensemble: { every: 2, milestones: [{ km: 5, item: 'reward.map', note: 'Secret stage' }] },
  items: [
    ...['character', 'backdrop', 'obstacles', 'fx'].map(kind => ({ id: `${kind}.default`, kind, name: 'Default', rarity: 'blue', default: true })),
    { id: 'live.a', kind: 'character', name: 'Ada', role: 'Lucy', play: 'Spuk', year: 2026, rarity: 'blue', personId: 901, image: 'live.webp', portrait: 'live-portrait.webp', harness: { fly: [100, 40] } },
    { id: 'future.b', kind: 'character', name: 'Ben', role: 'Graf', play: 'Neu', year: 2027, rarity: 'gold', personId: 902, image: 'future.webp' },
    { id: 'unique.spuk', kind: 'character', name: 'Plüschi', role: 'Plüschi', play: 'Spuk', year: 2026, rarity: 'unique', unlock: { play: 'Spuk' }, image: 'unique.webp' },
    { id: 'reward.map', kind: 'backdrop', name: 'Secret stage', reward: true, image: 'reward.webp' },
    { id: 'waiting.c', kind: 'character', name: 'Cleo', role: 'Hexe', play: 'Spuk', year: 2026, rarity: 'gold', personId: 903, disabled: true, image: 'waiting.webp', portrait: 'waiting-portrait.webp', harness: { cheer: [40, 60], bogus: [1, 2] } },
    { id: 'waiting.alt', kind: 'character', name: 'Dora', role: 'Wirtin', play: 'Alt', year: 2020, rarity: 'blue', personId: 904, disabled: true },
    { id: 'waiting.unique', kind: 'character', name: 'Altgeist', role: 'Altgeist', play: 'Alt', year: 2020, rarity: 'unique', unlock: { play: 'Alt' }, disabled: true, image: 'waiting-unique.webp' },
    // A waiting entry may still be incomplete: an unknown rarity or a bad file name must not break the view.
    { id: 'waiting.rough', kind: 'obstacles', name: 'Rohbau', rarity: 'nope', disabled: true, image: '../secret.webp' },
  ],
};
const releases = [{ id: 'neu', name: 'Neues Stück', startsAt, itemIds: ['future.b'], gatedItemIds: [] }];

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const clock = { at: new Date(Date.parse(startsAt) - 1) };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', runnerCatalog: loadCatalog(data, imageDir(t)), runnerReleases: releases, clock: () => clock.at, random: () => 0.9, missionRules: null });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  const personId = app.action('admin', { action: 'member.save', name: 'Sam' }, 'member-sam').id;
  app.session({ uid: 'sam', name: 'Sam', email: 'sam@example.invalid', email_verified: true });
  app.action('admin', { action: 'account.approve', uid: 'sam', personId, version: 1, role: 'member' }, 'approve-sam');
  return { app, store, clock, sam: personId };
}
const fileOf = link => link.match(/\/skins\/([^?]+)/)[1];

test('the server announces the admins\' Skin-Viewer', () => {
  assert.ok(apiFeatures.includes('runnerAdminCatalog'));
});

test('admins see every entry with its state: live, unreleased, secret and disabled', t => {
  const { app, clock } = setup(t);
  const view = app.runnerAdminCatalog('admin');
  const byId = new Map(view.items.map(x => [x.id, x]));
  assert.deepEqual([...byId.keys()].sort(), ['backdrop.default', 'character.default', 'future.b', 'fx.default', 'live.a', 'obstacles.default', 'reward.map', 'unique.spuk', 'waiting.alt', 'waiting.c', 'waiting.rough', 'waiting.unique']);
  assert.deepEqual(byId.get('live.a').admin, { disabled: false, live: true, release: null, secret: null });
  assert.deepEqual(byId.get('future.b').admin, { disabled: false, live: false, release: { id: 'neu', name: 'Neues Stück', startsAt, active: false, part: 'items' }, secret: null });
  assert.deepEqual(byId.get('unique.spuk').admin, { disabled: false, live: true, release: null, secret: 'unique' });
  assert.equal(byId.get('unique.spuk').name, 'Plüschi', 'admins see the secret name');
  assert.deepEqual(byId.get('reward.map').admin, { disabled: false, live: true, release: null, secret: 'reward', milestoneKm: 5 });
  const waiting = byId.get('waiting.c');
  assert.deepEqual(waiting.admin, { disabled: true, live: false, release: null, secret: null });
  assert.deepEqual([waiting.role, waiting.play, waiting.year, waiting.rarity, waiting.personId], ['Hexe', 'Spuk', 2026, 'gold', 903]);
  assert.deepEqual(waiting.harness, { cheer: [40, 60] });
  assert.deepEqual([byId.get('waiting.unique').unique, byId.get('waiting.unique').admin.secret], [true, 'unique']);
  // Unknown rarity: shown with the first one; a bad file name: without the picture.
  assert.equal(byId.get('waiting.rough').rarity, 'blue');
  assert.equal(byId.get('waiting.rough').image, undefined);
  // Every picture link points to the admins' route, never to the members' one.
  const links = view.items.flatMap(x => ['image', 'portrait', 'thumb', 'obstacles', 'collectibles'].map(k => x[k]).filter(Boolean));
  assert.ok(links.length >= 9);
  assert.ok(!JSON.stringify(view).includes('/games/runner/skins/'));
  assert.match(byId.get('live.a').thumb, /^\/admin\/runner\/skins\/live-thumb\.webp\?v=/);
  assert.match(waiting.thumb, /^\/admin\/runner\/skins\/waiting-thumb\.webp\?v=/);
  assert.ok(links.every(link => /^\/admin\/runner\/skins\/[a-z0-9._-]+\?v=[0-9a-f]{16}$/.test(link)), links.join(' '));
  assert.deepEqual(view.uniqueRarity, { id: 'unique', name: 'Unique', color: '#B388FF', style: 'holo' });
  assert.deepEqual(view.releases, [{ id: 'neu', name: 'Neues Stück', startsAt, active: false }]);
  // Every picture of the view loads for admins, disabled ones included.
  for (const link of links) assert.ok(app.runnerAdminSkin('admin', fileOf(link)).bytes.length > 0);
  // At the release the unreleased figure goes live; the view follows the server's clock.
  clock.at = new Date(startsAt);
  const after = new Map(app.runnerAdminCatalog('admin').items.map(x => [x.id, x]));
  assert.deepEqual([after.get('future.b').admin.live, after.get('future.b').admin.release.active], [true, true]);
  assert.equal(after.get('waiting.c').admin.live, false);
});

test('members get nothing of the admin view, and the members\' route stays as strict, for admins too', t => {
  const { app } = setup(t);
  assert.throws(() => app.runnerAdminCatalog('sam'), { status: 403 });
  assert.throws(() => app.runnerAdminCatalog('nobody'), { status: 403 });
  for (const name of pictures) {
    assert.throws(() => app.runnerAdminSkin('sam', name), { status: 403 }, name);
    assert.throws(() => app.runnerAdminSkin('nobody', name), { status: 403 }, name);
  }
  // The members' own wardrobe holds none of the hidden entries.
  const own = JSON.stringify(app.runnerWardrobe('sam', { roles: true, unique: true }));
  for (const secret of ['future.b', 'waiting.c', 'waiting.unique', 'waiting.rough', 'Cleo', 'Altgeist', 'Plüschi', 'Secret stage', 'future.webp', 'waiting', '/admin/']) assert.ok(!own.includes(secret), secret);
  // Unreleased, disabled and secret pictures stay 404 on the members' route, whoever asks.
  for (const uid of ['sam', 'admin']) {
    for (const name of ['future.webp', 'unique.webp', 'reward.webp', 'waiting.webp', 'waiting-portrait.webp', 'waiting-thumb.webp', 'waiting-unique.webp']) assert.throws(() => app.runnerSkin(uid, name), { status: 404 }, `${uid} ${name}`);
    assert.ok(app.runnerSkin(uid, 'live.webp').bytes.length > 0);
  }
  // Admins get 404 for anything that is not a picture of the view.
  for (const name of ['unknown.webp', '..', '../secret.webp', 'secret.webp', 'tune.m4a']) assert.throws(() => app.runnerAdminSkin('admin', name), { status: 404 }, name);
});

test('over HTTP: 403 for members, the catalog and uncached pictures for admins', async t => {
  const { app } = setup(t);
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  const get = (uid, path) => fetch(`${base}${path}`, { headers: uid ? { Authorization: `Bearer ${uid}` } : {} });
  assert.equal((await get(null, '/admin/runner/catalog')).status, 401);
  const denied = await get('sam', '/admin/runner/catalog');
  assert.equal(denied.status, 403);
  assert.ok(!(await denied.text()).includes('waiting'));
  for (const name of ['waiting.webp', 'live.webp']) assert.equal((await get('sam', `/admin/runner/skins/${name}`)).status, 403);
  const ok = await get('admin', '/admin/runner/catalog');
  assert.equal(ok.status, 200);
  assert.equal(ok.headers.get('cache-control'), 'no-store');
  const view = await ok.json();
  const link = view.items.find(x => x.id === 'waiting.c').image;
  const picture = await get('admin', link);
  assert.equal(picture.status, 200);
  assert.equal(picture.headers.get('content-type'), 'image/webp');
  assert.equal(picture.headers.get('cache-control'), 'private, no-store, max-age=0');
  assert.match(picture.headers.get('server-timing'), /app;dur=/);
  assert.ok((await picture.arrayBuffer()).byteLength > 0);
  assert.equal((await get('admin', '/games/runner/skins/waiting.webp')).status, 404);
  assert.equal((await get('admin', '/admin/runner/skins/unknown.webp')).status, 404);
});

test('the bundled catalog: the admin view holds every entry of catalog.json', t => {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', runnerCatalog: bundledCatalog(), missionRules: null });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  const view = app.runnerAdminCatalog('admin');
  const raw = bundledCatalog().source.data.items;
  assert.equal(view.items.length, raw.length);
  assert.equal(view.items.filter(x => x.admin.disabled).length, raw.filter(x => x.disabled === true).length);
  assert.equal(new Set(view.items.map(x => x.id)).size, view.items.length);
  // The real catalog brings thumbnails and music: every link of the view stays on the admins' route.
  assert.ok(view.items.some(x => x.thumb));
  assert.ok(!JSON.stringify(view).includes('/games/runner/skins/'));
  assert.ok(!view.items.some(x => x.music));
  // The raw entries behind the view never travel with a catalog.
  assert.ok(!Object.keys(bundledCatalog()).includes('source'));
  assert.ok(!Object.keys(app.runnerCatalog).includes('source'));
});
