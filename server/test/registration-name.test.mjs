import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid' });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let sequence = 0;
  const action = body => app.action('admin', body, `name-test-${++sequence}`);
  const personId = action({ action: 'member.save', name: 'Sam im Ensemble' }).id;
  const identity = { uid: 'new-user', name: 'Google Alias', email: 'r8x@example.invalid', email_verified: true, firebase: { sign_in_provider: 'google.com' } };
  const approve = version => action({ action: 'account.approve', uid: identity.uid, version, personId, role: 'member' });
  return { app, store, identity, personId, approve };
}

test('new provider accounts must supply a name before linking', t => {
  const { app, identity, approve } = setup(t);
  assert.equal(app.session(identity).needsRegistrationName, true);
  assert.throws(() => approve(1), { status: 409 });
  assert.throws(() => app.snapshot(identity.uid), { status: 403 });
  assert.equal(app.session(identity, '  Sam Beispiel  ').displayName, 'Sam Beispiel');
  assert.equal(app.session(identity).needsRegistrationName, false);
  approve(2);
  assert.equal(app.snapshot(identity.uid).user.displayName, 'Sam im Ensemble');
  assert.equal(app.snapshot('admin').pendingAccounts.length, 0);
});

test('association names survive stale and changed provider claims; admins see the supplied name', t => {
  const { app, store, identity } = setup(t);
  app.session(identity, 'Sam Beispiel');
  app.session({ ...identity, name: undefined });
  app.session({ ...identity, name: 'Anderer Alias' });
  assert.equal(store.account(identity.uid).name, 'Sam Beispiel');
  assert.equal(app.adminData('admin').accounts.find(a => a.uid === identity.uid).name, 'Sam Beispiel');
  assert.equal(app.snapshot('admin').pendingAccounts.find(a => a.uid === identity.uid).name, 'Sam Beispiel');
  assert.equal(store.account(identity.uid).version, 1);
});

test('name corrections invalidate stale approvals and are immutable after approval', t => {
  const { app, identity, approve } = setup(t);
  app.session(identity, 'Sam Beispiel');
  app.session(identity, 'Sam Korrektur');
  assert.throws(() => approve(1), { status: 409 });
  approve(2);
  assert.throws(() => app.session(identity, 'Andere Person'), { status: 403 });
  assert.equal(app.session(identity).displayName, 'Sam im Ensemble');
});

test('email registrations and older email clients retain their entered name', t => {
  const { app, identity, store } = setup(t);
  const emailIdentity = { ...identity, name: 'Sam Beispiel', firebase: { sign_in_provider: 'password' }, email_verified: false };
  assert.equal(app.session(emailIdentity).needsRegistrationName, false);
  app.session({ ...emailIdentity, name: undefined });
  assert.equal(store.account(identity.uid).name, 'Sam Beispiel');
  assert.equal(store.account(identity.uid).identityReady, false);
});

test('invalid names do not create or change accounts', t => {
  const { app, store, identity } = setup(t);
  for (const value of ['', '   ', null, 42, 'x'.repeat(121), 'Sam\nBeispiel']) {
    assert.throws(() => app.session(identity, value), { status: 400 });
    assert.equal(store.account(identity.uid), null);
  }
});

test('HTTP name submission belongs only to the authenticated pending account', async t => {
  const { app, store, identity } = setup(t);
  const server = createHttpServer({ theater: app, verifyToken: async token => { if (token !== 'new-user-token') throw Error('invalid'); return identity; } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  const payload = { registrationName: 'Sam Beispiel', uid: 'admin', role: 'admin', status: 'approved', personId: 1, identityReady: true };
  assert.equal((await fetch(`${base}/auth/session`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) })).status, 401);
  const response = await fetch(`${base}/auth/session`, { method: 'POST', headers: { Authorization: 'Bearer new-user-token', 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
  assert.equal(response.status, 200);
  const { user } = await response.json();
  assert.equal(user.displayName, 'Sam Beispiel');
  assert.equal(user.status, 'pending');
  assert.equal(user.personId, null);
  assert.equal(user.role, 'member');
  assert.equal(store.account('admin').name, 'Admin');
  assert.equal((await fetch(`${base}/snapshot`, { headers: { Authorization: 'Bearer new-user-token' } })).status, 403);
});
