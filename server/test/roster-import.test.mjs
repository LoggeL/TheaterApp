import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { importRoster } from '../src/roster-import.mjs';
function setup(t) {
  const s = new Store(); t.after(() => s.close());
  s.put('members', 1, { id: 1, name: 'Admin', active: true, version: 1 });
  s.saveAccount({ uid: 'admin', personId: 1, status: 'approved', role: 'admin', identityReady: true, email: 'real@example.test', version: 1 });
  s.put('productions', 'play', { id: 'play', version: 1, roles: [{ id: 'A', actor: 'Sam' }, { id: 'B', actor: 'Sam' }, { id: 'C', actor: 'Kim' }, { id: 'ALL', actor: '' }], casting: {} });
  const input = { source: 'legacy', migrationId: 'one', members: [{ sourceId: 8, name: 'Sam', group: 'Ensemble', roleName: 'Technik', email: 'fake@example.test', password: 'DO NOT IMPORT', profileRole: 'admin' }], productionIds: ['play'] };
  return { s, input };
}
test('roster dry run and repeated apply preserve login identities and existing people', t => {
  const { s, input } = setup(t); const account = s.account('admin');
  const preview = importRoster(s, input); assert.equal(preview.createdPeople, 2); assert.equal(s.all('members').length, 1);
  const result = importRoster(s, input, { apply: true }); assert.equal(result.castingCount, 3); assert.equal(s.all('members').length, 3);
  const p = s.get('productions', 'play'); assert.equal(p.casting.A, p.casting.B); assert.notEqual(p.casting.A, p.casting.C);
  assert.equal(p.casting.ALL, undefined); assert.equal(s.get('members', p.casting.A).email, undefined); assert.equal(s.get('members', p.casting.A).password, undefined);
  assert.deepEqual(s.accounts(), [account]);
  assert.equal(importRoster(s, input, { apply: true }).alreadyApplied, true); assert.deepEqual(s.get('productions', 'play'), p);
  const app = new Theater(s);
  app.action('admin', { action: 'member.save', id: p.casting.A, version: 1, name: 'Sam neu', group: 'Ensemble' }, 'edit');
  assert.deepEqual(s.get('members', p.casting.A).sourceRefs, ['legacy:8']); assert.equal(s.get('members', p.casting.A).roleName, 'Technik');
  app.session({ uid: 'sam', name: 'Sam', email: 'fake@example.test', email_verified: true });
  assert.equal(s.account('sam').personId, null); assert.equal(s.account('sam').status, 'pending');
  assert.throws(() => app.adminData('sam'), { status: 403 });
});
test('invalid mapping or casting conflict rolls back the entire roster', t => {
  const { s, input } = setup(t);
  assert.throws(() => importRoster(s, { ...input, actorAliases: { Sam: 999 } }, { apply: true }), /unknown person/);
  s.put('productions', 'play', { ...s.get('productions', 'play'), casting: { A: 1 } });
  assert.throws(() => importRoster(s, input, { apply: true }), /casting conflict/);
  assert.equal(s.all('members').length, 1); assert.equal(s.all('migrations').length, 0);
});
test('explicit aliases share casting; ambiguous actors remain unassigned', t => {
  const { s, input } = setup(t);
  importRoster(s, { ...input, existingPeople: { 8: 1 }, actorAliases: { Kim: null } }, { apply: true });
  assert.equal(s.all('members').length, 1); assert.equal(s.get('productions', 'play').casting.A, 1); assert.equal(s.get('productions', 'play').casting.C, undefined);
});
