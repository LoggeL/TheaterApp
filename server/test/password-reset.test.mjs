import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { createPasswordResetLink } from '../src/password-reset.mjs';

const link = 'https://theater.example.invalid/__/auth/action?mode=resetPassword&oobCode=secret-test-code';
function setup(t, admin = 'admin') {
  const store = new Store();
  t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: `${admin}@example.invalid` });
  app.session({ uid: admin, email: `${admin}@example.invalid`, email_verified: true });
  const personId = app.action(admin, { action: 'member.save', name: 'Sam' }, 'person').id;
  app.session({ uid: 'sam', email: 'sam@example.invalid', email_verified: true });
  app.action(admin, { action: 'account.approve', uid: 'sam', personId, version: 1, role: 'member' }, 'approve');
  const calls = [];
  const user = { uid: 'sam', email: 'sam@example.invalid', disabled: false, providerData: [{ providerId: 'password' }] };
  const auth = {
    getUser: async uid => { calls.push(['getUser', uid]); return user; },
    generatePasswordResetLink: async email => { calls.push(['generate', email]); return link; },
  };
  const version = store.account('sam').version;
  const generate = () => createPasswordResetLink(app, admin, 'sam', version, auth);
  return { store, app, calls, user, auth, version, generate };
}

async function serve(t, app, options = {}) {
  const server = createHttpServer({ theater: app, verifyToken: async uid => ({ uid }), ...options });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  return async (uid, { target = 'sam', version = 1, method = 'POST', email } = {}) => {
    const res = await fetch(`http://127.0.0.1:${server.address().port}/api/mobile/v1/admin/accounts/${target}/password-reset-link`, {
      method, headers: { 'Content-Type': 'application/json', ...(uid ? { Authorization: `Bearer ${uid}` } : {}) },
      ...(method === 'POST' ? { body: JSON.stringify({ version, email }) } : {}),
    });
    return { status: res.status, cache: res.headers.get('cache-control'), body: await res.json() };
  };
}

test('only an authenticated admin generates a link for the selected UID; no email or secret is stored', async t => {
  const { app, auth, store, calls, version } = setup(t);
  const api = await serve(t, app, { passwordResetAuth: auth });
  assert.ok(apiFeatures.includes('accountPasswordResetLink'));
  assert.equal((await api(null, { version })).status, 401);
  assert.equal((await api('sam', { version })).status, 403);
  assert.equal((await api('admin', { method: 'GET' })).status, 404);
  assert.deepEqual(calls, []);
  const before = store.account('sam');
  const result = await api('admin', { version, email: 'attacker@example.invalid' });
  assert.equal(result.status, 200);
  assert.equal(result.cache, 'no-store');
  assert.deepEqual(result.body, { link, email: 'sam@example.invalid' });
  assert.deepEqual(calls, [['getUser', 'sam'], ['generate', 'sam@example.invalid']]);
  assert.deepEqual(store.account('sam'), before);
  assert.deepEqual(store.all('emailJobs'), []);
  const audits = store.db.prepare("SELECT actor, action, subject FROM audit WHERE action = 'account.passwordResetLink'").all();
  assert.deepEqual(audits.map(x => ({ ...x })), [{ actor: 'admin', action: 'account.passwordResetLink', subject: 'sam' }]);
  const persisted = JSON.stringify({ accounts: store.accounts(), entities: store.db.prepare('SELECT * FROM entities').all(), requests: store.db.prepare('SELECT * FROM requests').all(), audit: store.db.prepare('SELECT * FROM audit').all() });
  assert.ok(!persisted.includes('secret-test-code'));
  assert.ok(!JSON.stringify(app.snapshot('admin')).includes('secret-test-code'));
});

test('stale, missing and own accounts fail before contacting Firebase', async t => {
  const { app, auth, calls, version, store } = setup(t);
  const api = await serve(t, app, { passwordResetAuth: auth });
  for (const options of [{ version: version + 1 }, { target: 'missing' }, { version: null }]) {
    const result = await api('admin', options);
    assert.equal(result.status, 409);
    assert.equal(result.body.code, 'version_conflict');
  }
  assert.equal((await api('admin', { target: 'admin', version: store.account('admin').version })).status, 409);
  store.saveAccount({ ...store.account('sam'), permissions: ['events'] });
  assert.equal((await api('sam', { target: 'admin', version: store.account('admin').version })).status, 403);
  store.saveAccount({ ...store.account('admin'), status: 'suspended' });
  assert.equal((await api('admin', { version })).status, 403);
  assert.deepEqual(calls, []);
});

test('the actual Firebase providers decide, including password plus Google', async t => {
  const { store, user, generate, calls } = setup(t);
  store.saveAccount({ ...store.account('sam'), provider: 'google.com' });
  user.providerData = [{ providerId: 'google.com' }];
  await assert.rejects(generate, { status: 409, code: 'password_provider_required' });
  assert.deepEqual(calls, [['getUser', 'sam']]);
  user.providerData.push({ providerId: 'password' });
  assert.equal((await generate()).link, link);
});

test('disabled identities, missing emails and mismatched login addresses cannot get a link', async t => {
  const { user, calls, generate } = setup(t);
  user.disabled = true;
  await assert.rejects(generate, { status: 409 });
  user.disabled = false;
  user.email = undefined;
  await assert.rejects(generate, { status: 409, code: 'password_provider_required' });
  user.email = 'other@example.invalid';
  await assert.rejects(generate, { status: 409, code: 'version_conflict' });
  assert.ok(calls.every(([method]) => method === 'getUser'));
});

test('pending and suspended accounts retain their status and permissions', async t => {
  const { store, generate } = setup(t);
  for (const status of ['pending', 'suspended', 'rejected']) {
    store.saveAccount({ ...store.account('sam'), status, permissions: ['events'] });
    const before = store.account('sam');
    assert.equal((await generate()).link, link);
    assert.deepEqual(store.account('sam'), before);
  }
});

for (const stage of ['getUser', 'generatePasswordResetLink']) {
  test(`admin rights are rechecked after ${stage}`, async t => {
    const { store, auth, generate, calls } = setup(t);
    const original = auth[stage];
    auth[stage] = async arg => {
      const result = await original(arg);
      store.saveAccount({ ...store.account('admin'), role: 'member' });
      return result;
    };
    await assert.rejects(generate, { status: 403 });
    if (stage === 'getUser') assert.equal(calls.length, 1);
    assert.equal(store.db.prepare("SELECT COUNT(*) AS n FROM audit WHERE action = 'account.passwordResetLink'").get().n, 0);
  });
}

for (const change of ['version', 'email', 'delete']) {
  test(`a concurrent target ${change} change prevents handing out a generated link`, async t => {
    const { store, auth, generate } = setup(t);
    auth.generatePasswordResetLink = async () => {
      const account = store.account('sam');
      if (change === 'delete') store.deleteAccount('sam');
      else store.saveAccount({ ...account, ...(change === 'version' ? { version: account.version + 1 } : { email: 'other@example.invalid' }) });
      return link;
    };
    await assert.rejects(generate, { status: 409, code: 'version_conflict' });
  });
}

test('Firebase failures return useful errors without provider details or links', async t => {
  const { app, auth, version } = setup(t);
  const api = await serve(t, app, { passwordResetAuth: auth });
  for (const [code, status] of [['auth/user-not-found', 404], ['auth/too-many-requests', 429], ['auth/quota-exceeded', 429], ['auth/internal-error', 503]]) {
    auth.getUser = async () => { throw Object.assign(new Error(`private provider details ${link}`), { code }); };
    const result = await api('admin', { version });
    assert.equal(result.status, status);
    assert.ok(!JSON.stringify(result.body).includes('private provider details'));
    assert.ok(!JSON.stringify(result.body).includes('secret-test-code'));
  }
});

test('unconfigured servers and review accounts cannot use production Firebase', async t => {
  const real = setup(t), review = setup(t, 'reviewer');
  const unconfigured = await serve(t, real.app);
  assert.equal((await unconfigured('admin', { version: real.version })).body.code, 'password_reset_unavailable');
  const api = await serve(t, real.app, { passwordResetAuth: real.auth, review: { uid: 'reviewer', theater: review.app } });
  const result = await api('reviewer', { version: review.version });
  assert.equal(result.status, 409);
  assert.equal(result.body.code, 'password_reset_unavailable');
  assert.deepEqual(real.calls, []);
});
