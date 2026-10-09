import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';

test('old free-text groups become person roles once and disappear', t => {
  const store = new Store(); t.after(() => store.close());
  new Theater(store);
  // Simulate data written before the migration existed.
  store.delete('settings', 'groupsMigrated');
  store.put('members', 1, { id: 1, name: 'Sam', group: 'Ensemble', roleIds: [], active: true, version: 3 });
  store.put('members', 2, { id: 2, name: 'Toni', group: 'Technik', roleIds: ['role-3'], active: true, version: 1 });
  store.put('members', 3, { id: 3, name: 'Kim', group: 'Kostümteam', active: true, version: 1 });
  store.put('members', 4, { id: 4, name: 'Alex', group: 'Admin', roleIds: ['role-7'], active: true, version: 1 });
  store.put('members', 5, { id: 5, name: 'Robin', group: 'Licht', active: true, version: 1 });
  store.put('events', 'e1', { id: 'e1', title: 'Probe', group: 'ALLE', roleIds: [], version: 2 });

  new Theater(store);
  const member = id => store.get('members', id);
  const roleName = id => store.get('personRoles', id)?.name;
  assert.deepEqual(member(1).roleIds, ['role-1']);
  assert.equal(member(1).version, 4);
  assert.deepEqual(member(2).roleIds, ['role-3']);
  assert.deepEqual(member(3).roleIds, ['role-4']);
  assert.deepEqual(member(4).roleIds, ['role-7']);
  assert.deepEqual(member(5).roleIds.map(roleName), ['Licht']);
  for (const id of [1, 2, 3, 4, 5]) assert.equal(Object.hasOwn(member(id), 'group'), false);
  assert.equal(Object.hasOwn(store.get('events', 'e1'), 'group'), false);
  assert.equal(store.get('events', 'e1').version, 3);

  // A second start leaves everything as it is.
  const roles = store.all('personRoles').length;
  new Theater(store);
  assert.equal(store.all('personRoles').length, roles);
  assert.equal(member(1).version, 4);
});
