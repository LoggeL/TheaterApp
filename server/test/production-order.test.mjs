import test from 'node:test';
import assert from 'node:assert/strict';
import { compareGalleriesNewestFirst, compareProductionsNewestFirst, gallerySortTime } from '../src/production-order.mjs';
import { MediaService } from '../src/media.mjs';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';

test('historical seasons sort newest first regardless of import time or alphabetical IDs', () => {
  const productions = [
    { id: 'sommerstueck2025', title: 'Sommerstück 2025', createdAt: '2027-01-01T00:00:00Z' },
    { id: 'winterstueck2026', title: 'Winterstück 2026 (Romeo und Julia)' },
    { id: 'sommerstueck2026', title: 'Sommerstück 2026' },
    { id: 'sommerstueck2027', title: 'Sommerstück 2027' },
  ];
  assert.deepEqual(productions.sort(compareProductionsNewestFirst).map(p => p.id), ['sommerstueck2027', 'winterstueck2026', 'sommerstueck2026', 'sommerstueck2025']);
});

test('an explicit premiere orders named productions; undated ties are stable', () => {
  const productions = [
    { id: 'a', title: 'Zuerst', premiereAt: '2026-12-20T16:00:00Z' },
    { id: 'b', title: 'Danach', premiereAt: '2026-12-27T16:00:00Z' },
    { id: 'd', title: 'Foyer' }, { id: 'c', title: 'Foyer' },
  ];
  assert.deepEqual(productions.sort(compareProductionsNewestFirst).map(p => p.id), ['b', 'a', 'c', 'd']);
});

test('API views sort productions and reimport keeps premiere and creation date', t => {
  const store = new Store(); t.after(() => store.close());
  const theater = new Theater(store, { bootstrapEmail: 'admin@example.com' });
  theater.session({ uid: 'admin', email: 'admin@example.com', email_verified: true });
  const document = id => ({ productionId: id, revision: 'r1', roles: [], scenes: [], cues: [] });
  theater.importScript('admin', { id: 'sommerstueck2026', title: 'Sommerstück 2026' }, document('sommerstueck2026'));
  const production = { id: 'winterstueck2026', title: 'Winterstück 2026', premiereAt: '2026-12-27T16:00:00Z' };
  theater.importScript('admin', production, document(production.id));
  const previous = store.get('productions', production.id);
  theater.importScript('admin', { id: production.id, title: production.title }, document(production.id));
  assert.equal(store.get('productions', production.id).createdAt, previous.createdAt);
  assert.equal(store.get('productions', production.id).premiereAt, previous.premiereAt);
  assert.equal(theater.snapshot('admin').productions[0].id, production.id);
  assert.equal(theater.adminData('admin').productions[0].id, production.id);
});

test('galleries sort by their play: linked production, season in the title, newest photo', () => {
  const winter = { id: 'winterstueck2026', title: 'Romeo und Julia' };
  const galleries = [
    { id: '3', title: 'Creepshow', time: gallerySortTime({ title: 'Creepshow', createdAt: '2026-10-01T00:00:00Z' }, null, ['2026-07-12T20:00:00Z', null]) },
    { id: '1', title: 'Romeo und Julia', time: gallerySortTime({ title: 'Romeo und Julia', createdAt: '2026-09-01T00:00:00Z' }, winter) },
    { id: '2', title: 'Sommerstück 2025', time: gallerySortTime({ title: 'Sommerstück 2025', createdAt: '2026-10-02T00:00:00Z' }) },
    { id: '4', title: 'Probenfotos', time: gallerySortTime({ title: 'Probenfotos', createdAt: '2024-05-01T00:00:00Z' }, { id: 'x', title: 'Ohne Jahr' }) },
  ];
  assert.deepEqual(galleries.sort(compareGalleriesNewestFirst).map(g => g.title), ['Romeo und Julia', 'Creepshow', 'Sommerstück 2025', 'Probenfotos']);
});

test('the gallery list is newest first', async t => {
  const store = new Store(); t.after(() => store.close());
  const theater = new Theater(store, { bootstrapEmail: 'admin@example.com' });
  theater.session({ uid: 'admin', email: 'admin@example.com', email_verified: true });
  const media = new MediaService(theater, { directory: '/nonexistent' });
  store.put('productions', 'winterstueck2026', { id: 'winterstueck2026', title: 'Romeo und Julia', version: 1 });
  store.put('productions', 'sommerstueck2026', { id: 'sommerstueck2026', title: 'Sommerstück 2026 (Creepshow)', version: 1 });
  await media.saveGallery('admin', { title: 'Creepshow', productionId: 'sommerstueck2026' });
  await media.saveGallery('admin', { title: 'Romeo und Julia', productionId: 'winterstueck2026' });
  await media.saveGallery('admin', { title: 'Anno 1146 (2025)' });
  assert.deepEqual((await media.list('admin')).galleries.map(g => g.title), ['Romeo und Julia', 'Creepshow', 'Anno 1146 (2025)']);
});
