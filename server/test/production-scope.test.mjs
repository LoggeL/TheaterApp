import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures } from '../src/theater.mjs';

const now = new Date('2026-10-18T12:00:00Z');
function setup(t, { ensemble = true } = {}) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.com', pushEnabled: true, emailEnabled: true, clock: () => now });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.com', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin', key = `scope-${++sequence}`) => app.action(uid, body, key);
  const person = (uid, name) => {
    const id = action({ action: 'member.save', name }).id;
    app.session({ uid, name, email: `${uid}@example.com`, email_verified: true });
    action({ action: 'account.approve', uid, personId: id, version: 1, role: 'member' });
    return id;
  };
  const sam = person('sam', 'Sam'), kim = person('kim', 'Kim');
  store.put('productions', 'winter', { id: 'winter', title: 'Winterstück', roles: [{ id: 'LENA', name: 'LENA' }], casting: ensemble ? { LENA: sam } : {}, directorMemberIds: [], memberIds: [], version: 1 });
  store.put('productions', 'summer', { id: 'summer', title: 'Sommerstück', roles: [], casting: {}, directorMemberIds: [], memberIds: [], version: 1 });
  const at = (days, hours = 2) => [new Date(+now + days * 86400000).toISOString(), new Date(+now + days * 86400000 + hours * 3600000).toISOString()];
  const put = (id, days, extra = {}, hours) => { const [startsAt, endsAt] = at(days, hours); store.put('events', id, { id, title: id, startsAt, endsAt, place: '', type: 'rehearsal', locked: false, productionId: 'winter', sceneIds: [], roleIds: [], personIds: [], productionIds: [], version: 3, ...extra }); };
  put('next', 2);
  put('later', 30);
  // Started an hour ago, still running.
  put('running', -1 / 24, {}, 3);
  put('past', -3);
  put('roles', 4, { roleIds: ['role-3'] });
  put('people', 5, { personIds: [kim] });
  put('ensembles', 6, { productionIds: ['summer'] });
  put('summer', 7, { productionId: 'summer' });
  put('free', 8, { productionId: null });
  put('slot', 9, { slotPoolId: 'pool' });
  // A legacy record without audience fields and version.
  const [startsAt, endsAt] = at(10);
  store.put('events', 'legacy', { id: 'legacy', title: 'Alt', startsAt, endsAt, productionId: 'winter' });
  for (const kind of ['pushJobs', 'emailJobs']) for (const j of store.all(kind)) store.delete(kind, j.id);
  return { store, app, action, sam, kim };
}
const scoped = ['next', 'later', 'running', 'legacy'];
const audits = store => store.db.prepare("SELECT actor, subject FROM audit WHERE action = 'production.scopeEvents'").all().map(r => ({ ...r }));

test('the server offers the silent ensemble scoping as an API feature', () => {
  assert.ok(apiFeatures.includes('productionScopeEvents'));
});

test('only open events of the production without an audience go to its ensemble, silently', t => {
  const { store, app, action } = setup(t);
  const before = Object.fromEntries(store.all('events').map(e => [e.id, e]));
  assert.equal(app.snapshot('kim').events.some(e => e.id === 'next'), true, 'no audience means everyone');
  const result = action({ action: 'production.scopeEvents', productionId: 'winter' });
  assert.deepEqual(result, { ok: true, updated: 4, eventIds: ['running', 'next', 'legacy', 'later'], ensembleSize: 1 });
  for (const id of scoped) {
    const e = store.get('events', id);
    assert.deepEqual(e.productionIds, ['winter'], id);
    assert.equal(e.version, (before[id].version ?? 1) + 1, id);
    // The change time moves with the version (LAST-MODIFIED in the calendar feed).
    assert.ok(e.updatedAt, id);
    const { productionIds, version, updatedAt, ...rest } = e, { productionIds: _p, version: _v, updatedAt: _u, ...was } = before[id];
    assert.deepEqual(rest, was, `${id}: nothing else changes`);
  }
  for (const id of Object.keys(before).filter(id => !scoped.includes(id))) assert.deepEqual(store.get('events', id), before[id], `${id} stays`);
  // No "Termin aktualisiert" or any other notification.
  assert.equal(store.all('pushJobs').length, 0);
  assert.equal(store.all('emailJobs').length, 0);
  const seen = uid => app.snapshot(uid).events.map(e => e.id);
  for (const id of scoped) {
    assert.equal(seen('sam').includes(id), true, `ensemble sees ${id}`);
    assert.equal(seen('kim').includes(id), false, `others no longer see ${id}`);
  }
  assert.equal(seen('kim').includes('past'), true);
  assert.equal(seen('admin').length, Object.keys(before).length);
  assert.deepEqual(audits(store), [{ actor: 'admin', subject: 'winter' }]);
  // Running it again finds nothing left to do.
  assert.deepEqual(action({ action: 'production.scopeEvents', productionId: 'winter' }), { ok: true, updated: 0, eventIds: [], ensembleSize: 1 });
});

test('a dry run only counts, also past events on request', t => {
  const { store, action } = setup(t);
  const before = store.all('events');
  assert.deepEqual(action({ action: 'production.scopeEvents', productionId: 'winter', dryRun: true }), { ok: true, updated: 4, eventIds: ['running', 'next', 'legacy', 'later'], ensembleSize: 1, dryRun: true });
  assert.deepEqual(action({ action: 'production.scopeEvents', productionId: 'winter', dryRun: true, includePast: true }).eventIds, ['past', 'running', 'next', 'legacy', 'later']);
  assert.deepEqual(store.all('events'), before);
  assert.deepEqual(audits(store), []);
  assert.equal(store.all('pushJobs').length + store.all('emailJobs').length, 0);
  assert.equal(action({ action: 'production.scopeEvents', productionId: 'winter', includePast: true }).updated, 5);
  assert.deepEqual(store.get('events', 'past').productionIds, ['winter']);
});

test('an empty ensemble is allowed and reported, so the client can warn', t => {
  const { app, action, kim } = setup(t, { ensemble: false });
  assert.equal(action({ action: 'production.scopeEvents', productionId: 'winter', dryRun: true }).ensembleSize, 0);
  const result = action({ action: 'production.scopeEvents', productionId: 'winter' });
  assert.deepEqual([result.updated, result.ensembleSize], [4, 0]);
  for (const uid of ['sam', 'kim']) assert.equal(app.snapshot(uid).events.some(e => scoped.includes(e.id)), false, uid);
  // Whoever joins the ensemble later sees the events right away.
  action({ action: 'production.cast', id: 'winter', changes: [{ kind: 'member', personId: kim, on: true }] });
  assert.equal(app.snapshot('kim').events.filter(e => scoped.includes(e.id)).length, 4);
});

test('only admins may scope, unknown productions fail and a repeated request changes nothing twice', t => {
  const { store, app, action } = setup(t);
  const before = store.all('events');
  assert.throws(() => app.action('sam', { action: 'production.scopeEvents', productionId: 'winter' }, 'member-scope'), { status: 403 });
  assert.throws(() => action({ action: 'production.scopeEvents', productionId: 'missing' }), { status: 404 });
  assert.deepEqual(store.all('events'), before);
  const body = { action: 'production.scopeEvents', productionId: 'winter' };
  const first = action(body, 'admin', 'same-key');
  const versions = store.all('events').map(e => [e.id, e.version]);
  assert.deepEqual(action(body, 'admin', 'same-key'), first);
  assert.deepEqual(store.all('events').map(e => [e.id, e.version]), versions);
  assert.equal(audits(store).length, 1);
  assert.throws(() => action({ ...body, dryRun: true }, 'admin', 'same-key'), { status: 409, code: 'request_reused' });
});
