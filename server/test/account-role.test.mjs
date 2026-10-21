import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures } from '../src/theater.mjs';

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.com', pushEnabled: true, clock: () => new Date('2026-10-19T12:00:00Z') });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.com', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `role-${++sequence}`);
  const person = (uid, name, role = 'member') => {
    const id = action({ action: 'member.save', name }).id;
    app.session({ uid, name, email: `${uid}@example.com`, email_verified: true });
    action({ action: 'account.approve', uid, personId: id, version: 1, role });
    return id;
  };
  const setRole = (uid, role, by = 'admin', version = store.account(uid).version) => action({ action: 'account.role', uid, role, version }, by);
  const clearPushes = () => { for (const j of store.all('pushJobs')) store.delete('pushJobs', j.id); };
  return { store, app, action, person, setRole, clearPushes };
}

test('the server announces account roles as a feature', t => {
  const { app } = setup(t);
  assert.ok(apiFeatures.includes('accountRole'));
  assert.ok(app.snapshot('admin').capabilities.features.includes('accountRole'));
});

test('an admin makes an approved member admin; it applies with the next snapshot and request', t => {
  const { store, app, person, setRole, clearPushes } = setup(t);
  const samId = person('sam', 'Sam');
  assert.equal(app.snapshot('sam').user.role, 'member');
  assert.throws(() => app.adminData('sam'), { status: 403 });
  clearPushes();
  const version = store.account('sam').version;
  setRole('sam', 'admin');
  const account = store.account('sam');
  assert.equal(account.role, 'admin');
  assert.equal(account.version, version + 1);
  assert.equal(account.roleChangedBy, 'admin');
  assert.equal(app.snapshot('sam').user.role, 'admin');
  assert.ok(app.adminData('sam').accounts.length >= 2);
  const [push, ...more] = store.all('pushJobs');
  assert.deepEqual(more, []);
  assert.equal(push.title, 'Admin-Rechte erhalten');
  assert.deepEqual(push.recipientPersonIds, [samId]);
  const audit = store.db.prepare("SELECT actor, subject FROM audit WHERE action = 'account.role'").all();
  assert.deepEqual(audit.map(x => ({ ...x })), [{ actor: 'admin', subject: 'sam' }]);
});

test('admins manage each other: a promoted admin can take rights away from another admin', t => {
  const { store, app, person, setRole } = setup(t);
  person('sam', 'Sam', 'admin');
  person('kim', 'Kim', 'admin');
  setRole('kim', 'member', 'sam');
  assert.equal(store.account('kim').role, 'member');
  assert.equal(app.snapshot('kim').user.role, 'member');
  assert.equal(app.snapshot('kim').pendingAccounts.length, 0);
  assert.throws(() => app.adminData('kim'), { status: 403 });
  assert.ok(store.all('pushJobs').some(j => j.title === 'Admin-Rechte entzogen' && j.recipientPersonIds?.includes(store.account('kim').personId)));
  // And back again, by yet another admin.
  setRole('kim', 'admin', 'admin');
  assert.equal(app.snapshot('kim').user.role, 'admin');
});

test('only admins may change admin rights', t => {
  const { store, person, setRole } = setup(t);
  person('sam', 'Sam');
  person('kim', 'Kim');
  assert.throws(() => setRole('kim', 'admin', 'sam'), { status: 403 });
  assert.throws(() => setRole('sam', 'admin', 'sam'), { status: 403 });
  assert.throws(() => setRole('admin', 'member', 'sam'), { status: 403 });
  assert.equal(store.account('kim').role, 'member');
  assert.equal(store.account('sam').role, 'member');
  assert.equal(store.account('admin').role, 'admin');
});

test('the last admin keeps the rights', t => {
  const { store, setRole } = setup(t);
  assert.throws(() => setRole('admin', 'member'), { status: 409, message: 'Der letzte Admin muss erhalten bleiben.' });
  assert.equal(store.account('admin').role, 'admin');
});

test('the last approved admin is kept even when a suspended admin exists', t => {
  const { store, action, person, setRole } = setup(t);
  person('sam', 'Sam', 'admin');
  action({ action: 'account.status', uid: 'sam', status: 'suspended', version: store.account('sam').version });
  // Sam is no longer an approved admin, so the bootstrap admin is the last one.
  assert.throws(() => setRole('admin', 'member'), { status: 409, message: 'Der letzte Admin muss erhalten bleiben.' });
  // Rights are only changed on approved accounts.
  assert.throws(() => setRole('sam', 'member'), { status: 409, message: 'Admin-Rechte gibt es nur für freigegebene Konten.' });
  assert.equal(store.account('sam').role, 'admin');
});

test('an admin cannot take away their own rights; another admin can', t => {
  const { store, person, setRole } = setup(t);
  person('sam', 'Sam', 'admin');
  assert.throws(() => setRole('admin', 'member', 'admin'), { status: 409, message: 'Die eigenen Admin-Rechte kann nur ein anderer Admin entziehen.' });
  assert.equal(store.account('admin').role, 'admin');
  setRole('admin', 'member', 'sam');
  assert.equal(store.account('admin').role, 'member');
});

test('a stale version is a version conflict and changes nothing', t => {
  const { store, person, setRole } = setup(t);
  person('sam', 'Sam');
  const stale = store.account('sam').version;
  setRole('sam', 'admin');
  assert.throws(() => setRole('sam', 'member', 'admin', stale), { status: 409, code: 'version_conflict' });
  assert.equal(store.account('sam').role, 'admin');
});

test('pending accounts, unknown accounts and unknown roles are rejected', t => {
  const { store, app, setRole } = setup(t);
  app.session({ uid: 'new', name: 'Neu', email: 'new@example.com', email_verified: true });
  assert.throws(() => setRole('new', 'admin'), { status: 409, message: 'Admin-Rechte gibt es nur für freigegebene Konten.' });
  assert.equal(store.account('new').role, 'member');
  assert.throws(() => setRole('nobody', 'admin', 'admin', 1), { status: 409, code: 'version_conflict' });
  assert.throws(() => setRole('admin', 'owner'), { status: 400 });
});

test('setting the role an account already has changes nothing', t => {
  const { store, person, setRole, clearPushes } = setup(t);
  person('sam', 'Sam');
  clearPushes();
  const version = store.account('sam').version;
  setRole('sam', 'member');
  assert.equal(store.account('sam').version, version);
  assert.deepEqual(store.all('pushJobs'), []);
});

test('promoting clears the extra rights; demoting keeps only the rights sent along', t => {
  const { store, app, action, person, setRole } = setup(t);
  person('sam', 'Sam');
  action({ action: 'account.permissions', uid: 'sam', permissions: ['events'], version: store.account('sam').version });
  setRole('sam', 'admin');
  assert.deepEqual(store.account('sam').permissions, []);
  assert.deepEqual(app.snapshot('sam').user.permissions, ['events']);
  action({ action: 'account.role', uid: 'sam', role: 'member', permissions: ['events'], version: store.account('sam').version });
  assert.deepEqual(app.snapshot('sam').user.permissions, ['events']);
  assert.throws(() => action({ action: 'account.role', uid: 'sam', role: 'admin', permissions: ['foo'], version: store.account('sam').version }, 'sam'), { status: 403 });
});
