import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, productionEnsemble } from '../src/theater.mjs';

const now = new Date('2026-10-18T12:00:00Z');
function setup(t, { pushEnabled = true } = {}) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.com', pushEnabled, emailEnabled: true, clock: () => now });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.com', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin', key = `ensemble-${++sequence}`) => app.action(uid, body, key);
  const person = (uid, name, role = 'member') => {
    const id = action({ action: 'member.save', name }).id;
    app.session({ uid, name, email: `${uid}@example.com`, email_verified: true });
    action({ action: 'account.approve', uid, personId: id, version: 1, role });
    return id;
  };
  const sam = person('sam', 'Sam'), tobias = person('tobias', 'Tobias'), kim = person('kim', 'Kim'), sebastian = person('sebastian', 'Sebastian');
  store.put('productions', 'winter', { id: 'winter', title: 'Romeo und Julia', roles: [{ id: 'JULIA', name: 'JULIA' }], casting: { JULIA: sam }, directorMemberIds: [sebastian], memberIds: [], version: 1 });
  const at = days => [new Date(+now + days * 86400000).toISOString(), new Date(+now + days * 86400000 + 7200000).toISOString()];
  const put = (id, days, extra = {}) => { const [startsAt, endsAt] = at(days); store.put('events', id, { id, title: id, startsAt, endsAt, place: 'Probebühne', type: 'rehearsal', locked: false, productionId: 'winter', sceneIds: [], roleIds: [], personIds: [], productionIds: ['winter'], version: 1, ...extra }); };
  put('wed1', 3);
  put('wed2', 10);
  put('past', -4);
  put('slot', 5, { slotPoolId: 'pool' });
  put('open', 6, { productionIds: [] });
  const cast = (changes, uid = 'admin') => action({ action: 'production.cast', id: 'winter', changes }, uid);
  const pushes = () => store.all('pushJobs');
  for (const kind of ['pushJobs', 'emailJobs']) for (const j of store.all(kind)) store.delete(kind, j.id);
  return { store, app, action, cast, pushes, sam, tobias, kim, sebastian };
}

test('a person added by hand with notify gets one push about the ensemble events now meant for them', t => {
  const { store, cast, pushes, tobias } = setup(t);
  const result = cast([{ kind: 'member', personId: tobias, on: true, notify: true }]);
  assert.ok(result.ensemble.includes(tobias));
  assert.deepEqual(result.newEvents, { [tobias]: 2 });
  assert.deepEqual(result.notified, [tobias]);
  const [job, ...more] = pushes();
  assert.equal(more.length, 0);
  assert.deepEqual(job.recipientPersonIds, [tobias]);
  assert.equal(job.title, 'Ensemble: Romeo und Julia');
  assert.match(job.body, /^Du gehörst jetzt dazu\. 2 kommende Termine gelten jetzt auch für dich, ab .+ · Probebühne\.$/);
  // Opens the first event; no quick answer, no email copy.
  assert.deepEqual(job.data, { eventId: 'wed1' });
  assert.equal(job.fixedText, true);
  assert.equal(store.all('emailJobs').length, 0);
});

test('without notify, for role casting, removals and people already in the ensemble nothing is pushed', t => {
  const { cast, pushes, tobias, kim, sam, sebastian } = setup(t);
  // Older clients and the casting page send no notify.
  let result = cast([{ kind: 'member', personId: tobias, on: true }]);
  assert.deepEqual(result.newEvents, {});
  assert.deepEqual(result.notified, []);
  // Removing and adding again (e.g. undo) without notify stays silent, too.
  cast([{ kind: 'member', personId: tobias, on: false }]);
  cast([{ kind: 'member', personId: tobias, on: true }]);
  // Role casting adds people silently.
  cast([{ kind: 'role', roleId: 'JULIA', personId: kim, previous: sam }]);
  // Cast and directing people are in the ensemble already.
  result = cast([{ kind: 'member', personId: kim, on: true, notify: true }, { kind: 'member', personId: sebastian, on: true, notify: true }, { kind: 'member', personId: tobias, on: true, notify: true }]);
  assert.deepEqual(result.newEvents, {});
  assert.deepEqual(pushes(), []);
});

test('no push when no upcoming event becomes newly visible or push is not set up', t => {
  {
    const { store, cast, pushes, tobias } = setup(t);
    for (const id of ['wed1', 'wed2']) store.delete('events', id);
    const result = cast([{ kind: 'member', personId: tobias, on: true, notify: true }]);
    assert.deepEqual(result.newEvents, {});
    assert.deepEqual(pushes(), []);
  }
  {
    const { cast, pushes, tobias } = setup(t, { pushEnabled: false });
    const result = cast([{ kind: 'member', personId: tobias, on: true, notify: true }]);
    // The count is still reported, but nobody is told a push went out.
    assert.deepEqual(result.newEvents, { [tobias]: 2 });
    assert.deepEqual(result.notified, []);
    assert.deepEqual(pushes(), []);
  }
});

test('several people added at once each get at most one push', t => {
  const { cast, pushes, tobias, kim } = setup(t);
  cast([{ kind: 'member', personId: tobias, on: true, notify: true }, { kind: 'member', personId: tobias, on: true, notify: true, function: 'Licht' }, { kind: 'member', personId: kim, on: true, notify: true }]);
  assert.deepEqual(pushes().map(j => j.recipientPersonIds).sort(), [[kim], [tobias]].sort());
});

test('only admins maintain the ensemble, also the director of the production', t => {
  const { app, store, sebastian, tobias } = setup(t);
  const before = store.get('productions', 'winter');
  for (const uid of ['sebastian', 'sam']) {
    assert.throws(() => app.action(uid, { action: 'production.cast', id: 'winter', changes: [{ kind: 'member', personId: tobias, on: true, notify: true }] }, `${uid}-try`), { status: 403 });
  }
  assert.deepEqual(store.get('productions', 'winter'), before);
  assert.ok(productionEnsemble(before).includes(sebastian));
  assert.equal(store.all('pushJobs').length, 0);
});
