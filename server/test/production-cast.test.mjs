import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, productionEnsemble } from '../src/theater.mjs';

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const theater = new Theater(store, { bootstrapEmail: 'owner@example.invalid' });
  theater.session({ uid: 'owner', email: 'owner@example.invalid', email_verified: true });
  let request = 0;
  const action = (body, uid = 'owner', key = `cast-${++request}`) => theater.action(uid, body, key);
  const [mara, kim, toni] = ['Mara Beispiel', 'Kim Kulisse', 'Toni Lichtblick'].map(name => action({ action: 'member.save', name }).id);
  theater.session({ uid: 'member', name: 'Mara Beispiel', email: 'member@example.invalid', email_verified: true });
  action({ action: 'account.approve', uid: 'member', personId: mara, version: 1, role: 'member' });
  const document = { productionId: 'winter', revision: 'r1', roles: [{ id: 'LENA', name: 'LENA', actor: 'Mara Beispiel' }, { id: 'OSKAR', name: 'OSKAR', actor: '' }], scenes: [{ id: '1', title: 'Anfang', ordinal: 0 }], cues: [{ id: 'c1', sceneId: '1', ordinal: 0, kind: 'dialogue', role: 'LENA', text: 'Hallo.' }] };
  theater.importScript('owner', { id: 'winter', title: 'Winterstück' }, document);
  const cast = (changes, extra = {}) => action({ action: 'production.cast', id: 'winter', changes, ...extra });
  const production = () => store.get('productions', 'winter');
  return { store, theater, action, cast, production, document, mara, kim, toni };
}

test('single casting changes update roles, directors and team without a full save', t => {
  const { cast, production, mara, kim, toni } = setup(t);
  const result = cast([{ kind: 'role', roleId: 'LENA', personId: mara, previous: null }, { kind: 'director', personId: kim, on: true }, { kind: 'member', personId: toni, on: true, function: '  Licht  ' }]);
  assert.deepEqual(result.ensemble.sort(), [mara, kim, toni].sort());
  assert.deepEqual(production().casting, { LENA: mara });
  assert.deepEqual(production().directorMemberIds, [kim]);
  assert.deepEqual(production().memberIds, [toni]);
  assert.deepEqual(production().memberFunctions, { [toni]: 'Licht' });
  assert.equal(production().version, 2);

  // Recasting, a second role for the same person and clearing a function.
  cast([{ kind: 'role', roleId: 'LENA', personId: kim, previous: mara }, { kind: 'role', roleId: 'OSKAR', personId: kim }, { kind: 'member', personId: toni, function: '' }]);
  assert.deepEqual(production().casting, { LENA: kim, OSKAR: kim });
  assert.deepEqual(production().memberFunctions, {});
  // Removing is idempotent; the team function leaves with the person.
  cast([{ kind: 'member', personId: toni, on: true, function: 'Souffleuse' }]);
  cast([{ kind: 'role', roleId: 'OSKAR', personId: null }, { kind: 'member', personId: toni, on: false }, { kind: 'director', personId: kim, on: false }, { kind: 'director', personId: kim, on: false }]);
  assert.deepEqual(production().casting, { LENA: kim });
  assert.deepEqual(production().memberIds, []);
  assert.deepEqual(production().memberFunctions, {});
  assert.deepEqual(productionEnsemble(production()), [kim]);
});

test('casting changes are validated and conflicts surface per role', t => {
  const { theater, action, cast, production, mara, kim } = setup(t);
  cast([{ kind: 'role', roleId: 'LENA', personId: mara }]);
  const before = production();
  assert.throws(() => cast([{ kind: 'role', roleId: 'LENA', personId: kim, previous: null }]), { status: 409, message: /LENA.*anders besetzt/ });
  assert.throws(() => cast([{ kind: 'role', roleId: 'HAMLET', personId: kim }]), { status: 400 });
  assert.throws(() => cast([{ kind: 'role', roleId: 'OSKAR', personId: 999 }]), { status: 400 });
  assert.throws(() => cast([{ kind: 'role', roleId: 'OSKAR', personId: 'abc' }]), { status: 400 });
  assert.throws(() => cast([{ kind: 'member', personId: kim, function: 7 }]), { status: 400 });
  assert.throws(() => cast([{ kind: 'director', personId: kim, on: 'yes' }]), { status: 400 });
  assert.throws(() => cast([{ kind: 'unknown' }]), { status: 400 });
  assert.throws(() => cast([]), { status: 400 });
  assert.throws(() => action({ action: 'production.cast', id: 'missing', changes: [{ kind: 'director', personId: kim }] }), { status: 404 });
  assert.throws(() => theater.action('member', { action: 'production.cast', id: 'winter', changes: [{ kind: 'director', personId: mara }] }, 'member-cast'), { status: 403 });
  // A failing change in a batch leaves the production untouched.
  assert.throws(() => cast([{ kind: 'role', roleId: 'OSKAR', personId: kim }, { kind: 'role', roleId: 'OSKAR', personId: 999 }]), { status: 400 });
  assert.deepEqual(production(), before);
  // Function labels are capped.
  cast([{ kind: 'member', personId: kim, function: 'x'.repeat(100) }]);
  assert.equal(production().memberFunctions[kim].length, 60);
});

test('inactive people stay where they are but cannot be newly assigned', t => {
  const { action, cast, production, mara, kim } = setup(t);
  cast([{ kind: 'role', roleId: 'LENA', personId: kim }, { kind: 'member', personId: kim }]);
  action({ action: 'member.save', id: kim, version: 1, name: 'Kim Kulisse', active: false });
  cast([{ kind: 'role', roleId: 'LENA', personId: kim, previous: kim }, { kind: 'member', personId: kim, function: 'Bühne' }]);
  assert.throws(() => cast([{ kind: 'role', roleId: 'OSKAR', personId: kim }]), { status: 400 });
  assert.throws(() => cast([{ kind: 'director', personId: kim }]), { status: 400 });
  cast([{ kind: 'role', roleId: 'LENA', personId: mara, previous: kim }]);
  assert.deepEqual(production().casting, { LENA: mara });
});

test('replayed casting requests are idempotent and older production saves conflict', t => {
  const { action, production, mara, kim } = setup(t);
  const body = { action: 'production.cast', id: 'winter', changes: [{ kind: 'role', roleId: 'LENA', personId: mara, previous: null }] };
  const first = action(body, 'owner', 'same-key');
  assert.deepEqual(action(body, 'owner', 'same-key'), first);
  assert.equal(production().version, 2);
  // An editor still holding version 1 must reload instead of overwriting the casting.
  assert.throws(() => action({ action: 'production.save', id: 'winter', version: 1, title: 'Winterstück' }), { status: 409 });
  // Saving only title data keeps casting, directors, team and functions.
  action({ action: 'production.cast', id: 'winter', changes: [{ kind: 'director', personId: kim }, { kind: 'member', personId: kim, function: 'Licht' }] });
  action({ action: 'production.save', id: 'winter', version: 3, title: 'Winterstück 2026', subtitle: 'Neu' });
  assert.deepEqual(production().casting, { LENA: mara });
  assert.deepEqual(production().directorMemberIds, [kim]);
  assert.deepEqual(production().memberFunctions, { [kim]: 'Licht' });
  // Older clients sending the full team drop functions of removed members.
  action({ action: 'production.save', id: 'winter', version: 4, title: 'Winterstück 2026', casting: { LENA: mara }, directorMemberIds: [kim], memberIds: [] });
  assert.deepEqual(production().memberFunctions, {});
});

test('a script reimport keeps the team and its functions', t => {
  const { theater, cast, production, document, mara, toni } = setup(t);
  cast([{ kind: 'role', roleId: 'LENA', personId: mara }, { kind: 'member', personId: toni, function: 'Licht' }]);
  theater.importScript('owner', { id: 'winter', title: 'Winterstück' }, { ...document, revision: 'r2', roles: [document.roles[1]] });
  assert.deepEqual(production().casting, {});
  assert.deepEqual(production().memberIds, [toni]);
  assert.deepEqual(production().memberFunctions, { [toni]: 'Licht' });
  assert.deepEqual(theater.snapshot('member').productions.find(p => p.id === 'winter').ensemble, [toni]);
});
