import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid' });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin', key = `ux-${++sequence}`) => app.action(uid, body, key);
  const memberId = action({ action: 'member.save', name: 'Mitglied Beispiel' }).id;
  app.session({ uid: 'member', name: 'Mitglied Beispiel', email: 'member@example.invalid', email_verified: true });
  action({ action: 'account.approve', uid: 'member', personId: memberId, version: 1, role: 'member' });
  app.session({ uid: 'rejected', name: 'Anfrage Beispiel', email: 'rejected@example.invalid', email_verified: true });
  action({ action: 'account.status', uid: 'rejected', version: 1, status: 'rejected' });
  store.put('productions', 'play', { id: 'play', title: 'Teststück' });
  store.put('scripts', 'play', { productionId: 'play', revision: 'r1', roles: [], scenes: [{ id: 's1' }, { id: 's2' }], cues: [] });
  const eventId = action({ action: 'event.save', title: 'Szenenprobe', startsAt: '2030-10-09T17:00:00Z', endsAt: '2030-10-09T19:00:00Z', productionId: 'play', sceneIds: [] }).id;
  const requestCount = () => store.db.prepare('SELECT COUNT(*) AS count FROM requests').get().count;
  const auditCount = () => store.db.prepare('SELECT COUNT(*) AS count FROM audit').get().count;
  return { store, app, action, eventId, memberId, requestCount, auditCount };
}

test('scene assignment rejects concurrent stale changes without changing event, audit or idempotency data', t => {
  const { store, action, eventId, requestCount, auditCount } = setup(t);
  action({ action: 'event.script', eventId, productionId: 'play', sceneIds: ['s1'], version: 1 });
  const before = store.get('events', eventId), requests = requestCount(), audits = auditCount();
  assert.equal(before.version, 2);
  assert.throws(() => action({ action: 'event.script', eventId, productionId: 'play', sceneIds: ['s2'], version: 1 }), { status: 409 });
  assert.deepEqual(store.get('events', eventId), before);
  assert.equal(requestCount(), requests);
  assert.equal(auditCount(), audits);
});

test('scene assignments support legacy clients and events while retaining validation and admin authorization', t => {
  const { store, action, eventId } = setup(t);
  const original = store.get('events', eventId);
  delete original.version;
  store.put('events', eventId, original);
  action({ action: 'event.script', eventId, productionId: 'play', sceneIds: ['s1'], version: 1 });
  assert.equal(store.get('events', eventId).version, 2);
  action({ action: 'event.script', eventId, productionId: 'play', sceneIds: ['s2'] });
  const before = store.get('events', eventId);
  assert.equal(before.version, 3);
  assert.deepEqual(before.sceneIds, ['s2']);
  assert.throws(() => action({ action: 'event.script', eventId, productionId: 'play', sceneIds: ['s1'] }, 'member'), { status: 403 });
  assert.throws(() => action({ action: 'event.script', eventId, productionId: 'play', sceneIds: ['s1'], version: null }), { status: 409 });
  assert.throws(() => action({ action: 'event.script', eventId, productionId: 'play', sceneIds: ['foreign'], version: 3 }), { status: 400 });
  assert.throws(() => action({ action: 'event.script', eventId, productionId: 'missing', sceneIds: [], version: 3 }), { status: 400 });
  assert.deepEqual(store.get('events', eventId), before);
});

test('scene assignment retries are idempotent and invalid reuse cannot overwrite the saved scenes', t => {
  const { store, action, eventId, requestCount, auditCount } = setup(t);
  const body = { action: 'event.script', eventId, productionId: 'play', sceneIds: ['s1'], version: 1 };
  const first = action(body, 'admin', 'scene-retry');
  const requests = requestCount(), audits = auditCount();
  assert.deepEqual(action(body, 'admin', 'scene-retry'), first);
  assert.equal(store.get('events', eventId).version, 2);
  assert.equal(requestCount(), requests);
  assert.equal(auditCount(), audits);
  assert.throws(() => action({ ...body, sceneIds: ['s2'] }, 'admin', 'scene-retry'), { status: 409 });
  assert.deepEqual(store.get('events', eventId).sceneIds, ['s1']);
});

test('reconsidering an account only reopens its request and never grants data access', t => {
  const { store, app, action, eventId } = setup(t);
  const before = store.account('rejected'), members = store.all('members');
  action({ action: 'account.reconsider', uid: 'rejected', version: 2, role: 'admin', personId: 1, status: 'approved' });
  assert.deepEqual(store.account('rejected'), { ...before, status: 'pending', personId: null, role: 'member', version: 3 });
  assert.deepEqual(store.all('members'), members);
  assert.equal(app.session({ uid: 'rejected', name: 'Anfrage Beispiel', email: 'rejected@example.invalid', email_verified: true }).status, 'pending');
  assert(app.snapshot('admin').pendingAccounts.some(a => a.uid === 'rejected'));
  for (const read of [() => app.snapshot('rejected'), () => app.adminData('rejected'), () => app.eventDetails('rejected', eventId), () => app.script('rejected', 'play')]) assert.throws(read, { status: 403 });
  assert.throws(() => action({ action: 'account.status', uid: 'rejected', version: 3, status: 'approved' }), { status: 409 });
});

test('reconsidering a formerly approved admin drops the old person link, role and approval markers', t => {
  const { store, app, action } = setup(t);
  const formerPerson = action({ action: 'member.save', name: 'Früherer Admin' }).id;
  app.session({ uid: 'former', name: 'Früherer Admin', email: 'former@example.invalid', email_verified: true });
  action({ action: 'account.approve', uid: 'former', personId: formerPerson, version: 1, role: 'admin' });
  action({ action: 'account.status', uid: 'former', version: 2, status: 'rejected' });
  const memberBefore = store.get('members', formerPerson);
  action({ action: 'account.reconsider', uid: 'former', version: 3 });
  const reopened = store.account('former');
  assert.equal(reopened.status, 'pending');
  assert.equal(reopened.role, 'member');
  assert.equal(reopened.personId, null);
  assert.equal(reopened.version, 4);
  assert.equal(reopened.approvedAt, undefined);
  assert.equal(reopened.approvedBy, undefined);
  assert.deepEqual(store.get('members', formerPerson), memberBefore);
  assert.throws(() => app.account('former', true), { status: 403 });
  assert.throws(() => action({ action: 'member.save', name: 'Unzulässig' }, 'former'), { status: 403 });
});

test('reconsider requires an authorized admin, a rejected target and its current version', t => {
  const { store, action, requestCount, auditCount } = setup(t);
  const accountsBefore = store.accounts(), requests = requestCount(), audits = auditCount();
  for (const uid of ['member', 'rejected', 'unknown']) assert.throws(() => action({ action: 'account.reconsider', uid: 'rejected', version: 2 }, uid), { status: 403 });
  for (const version of [undefined, null, 1, '2']) assert.throws(() => action({ action: 'account.reconsider', uid: 'rejected', version }), { status: 409 });
  for (const uid of ['missing', 'member', 'admin']) assert.throws(() => action({ action: 'account.reconsider', uid, version: store.account(uid)?.version ?? 1 }), { status: 409 });
  action({ action: 'account.status', uid: 'member', version: 2, status: 'suspended' });
  assert.throws(() => action({ action: 'account.reconsider', uid: 'member', version: 3 }), { status: 409 });
  const suspended = store.account('member');
  assert.equal(suspended.status, 'suspended');
  assert.deepEqual(store.account('rejected'), accountsBefore.find(a => a.uid === 'rejected'));
  assert.equal(requestCount(), requests + 1);
  assert.equal(auditCount(), audits + 1);
});

test('reconsider retries are idempotent but fresh retries and changed request payloads conflict', t => {
  const { store, action, requestCount, auditCount } = setup(t);
  const body = { action: 'account.reconsider', uid: 'rejected', version: 2 };
  const first = action(body, 'admin', 'reconsider-retry');
  const before = store.account('rejected'), requests = requestCount(), audits = auditCount();
  assert.deepEqual(action(body, 'admin', 'reconsider-retry'), first);
  assert.throws(() => action(body), { status: 409 });
  assert.throws(() => action({ ...body, version: 3 }), { status: 409 });
  assert.throws(() => action({ ...body, uid: 'member' }, 'admin', 'reconsider-retry'), { status: 409 });
  assert.deepEqual(store.account('rejected'), before);
  assert.equal(requestCount(), requests);
  assert.equal(auditCount(), audits);
});

test('reconsider preserves identity and registration prerequisites for subsequent approval', t => {
  const { store, app, action } = setup(t);
  app.session({ uid: 'unverified', email: 'unverified@example.invalid', email_verified: false });
  action({ action: 'account.status', uid: 'unverified', version: 1, status: 'rejected' });
  action({ action: 'account.reconsider', uid: 'unverified', version: 2 });
  const personId = action({ action: 'member.save', name: 'Neue Person' }).id;
  assert.throws(() => action({ action: 'account.approve', uid: 'unverified', personId, version: 3, role: 'member' }), { status: 409 });
  app.session({ uid: 'unverified', email: 'unverified@example.invalid', email_verified: true });
  assert.throws(() => action({ action: 'account.approve', uid: 'unverified', personId, version: 3, role: 'member' }), { status: 409 });
  app.session({ uid: 'unverified', email: 'unverified@example.invalid', email_verified: true }, 'Neue Person');
  action({ action: 'account.approve', uid: 'unverified', personId, version: 4, role: 'member' });
  assert.equal(store.account('unverified').status, 'approved');
});

test('account and scene writes roll back if recording the audit fails after mutation', t => {
  const { store, action, eventId, requestCount, auditCount } = setup(t);
  const accountBefore = store.account('rejected'), eventBefore = store.get('events', eventId);
  const requests = requestCount(), audits = auditCount(), originalAudit = store.audit;
  store.audit = () => { throw Error('simulated audit failure'); };
  try {
    assert.throws(() => action({ action: 'account.reconsider', uid: 'rejected', version: 2 }), /simulated audit failure/);
    assert.throws(() => action({ action: 'event.script', eventId, productionId: 'play', sceneIds: ['s1'], version: 1 }), /simulated audit failure/);
  } finally { store.audit = originalAudit; }
  assert.deepEqual(store.account('rejected'), accountBefore);
  assert.deepEqual(store.get('events', eventId), eventBefore);
  assert.equal(requestCount(), requests);
  assert.equal(auditCount(), audits);
});
