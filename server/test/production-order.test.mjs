import test from 'node:test';
import assert from 'node:assert/strict';
import { compareProductionsNewestFirst } from '../src/production-order.mjs';
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
