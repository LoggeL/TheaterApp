import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { createTokenVerifier } from '../src/auth-cache.mjs';

const origin = 'https://app.example.invalid';

// `verifyToken` decides by token: `admin` signs in, `expired`/`gone`/`google-down` fail like
// firebase-admin and auth-cache.mjs would. Every call is recorded with its options.
async function serve(t, verifyToken) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid' });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  const calls = [];
  const server = createHttpServer({ theater: app, allowedOrigins: [origin], verifyToken: async (token, options) => { calls.push({ token, options }); return verifyToken(token, options); } });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  const request = async (method, path, token, headers = {}, body = {}) => {
    const response = await fetch(`${base}${path}`, { method, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), 'Content-Type': 'application/json', ...headers }, ...(['POST', 'PUT', 'DELETE'].includes(method) ? { body: JSON.stringify(body) } : {}) });
    return { status: response.status, headers: response.headers, body: response.status === 204 ? null : await response.json() };
  };
  return { request, calls, app };
}

const firebaseError = code => Object.assign(new Error(code), { code });
const fakeVerify = async token => {
  if (token === 'expired') throw firebaseError('auth/id-token-expired');
  if (token === 'gone') throw firebaseError('auth/user-not-found');
  if (token === 'google-down') throw Object.assign(new Error('Die Anmeldung kann gerade nicht geprüft werden.'), { code: 'app/network-error', transient: true });
  return { uid: token, email: `${token}@example.invalid`, email_verified: true };
};

test('Google being unreachable answers 503 with Retry-After instead of signing out', async t => {
  const { request } = await serve(t, fakeVerify);
  const { status, headers, body } = await request('GET', '/snapshot', 'google-down');
  assert.equal(status, 503);
  assert.equal(headers.get('retry-after'), '5');
  assert.equal(body.code, 'auth_unavailable');
});

test('a failed renewal of the server\'s access token answers 503 for Google 5xx, 401 for a rejected key', async t => {
  const renewal = status => async () => { throw Object.assign(new Error('Credential implementation failed'), { code: 'app/invalid-credential', cause: { code: status, status } }); };
  const outage = await serve(t, renewal(503));
  const { status, headers, body } = await outage.request('GET', '/snapshot', 'sam');
  assert.equal(status, 503);
  assert.equal(headers.get('retry-after'), '5');
  assert.equal(body.code, 'auth_unavailable');
  const rejected = await serve(t, renewal(400));
  assert.equal((await rejected.request('GET', '/snapshot', 'sam')).status, 401);
});

test('expired, revoked and deleted logins stay 401', async t => {
  const { request } = await serve(t, fakeVerify);
  for (const token of ['expired', 'gone']) {
    const { status, headers, body } = await request('GET', '/snapshot', token);
    assert.equal(status, 401, token);
    assert.equal(headers.get('retry-after'), null);
    assert.deepEqual(body, { error: 'Die Anmeldung ist abgelaufen oder wurde gesperrt.', code: 'unauthenticated' });
  }
  // An unexpected error without the transient mark still rejects, as before.
  const strict = await serve(t, async () => { throw new Error('invalid'); });
  assert.equal((await strict.request('GET', '/snapshot', 'x')).status, 401);
});

test('API answers carry Server-Timing, exposed to allowed origins', async t => {
  const { request } = await serve(t, fakeVerify);
  const signedIn = await request('GET', '/snapshot', 'admin', { Origin: origin });
  assert.equal(signedIn.status, 200);
  assert.match(signedIn.headers.get('server-timing'), /^auth;dur=\d+\.\d, app;dur=\d+\.\d$/);
  assert.equal(signedIn.headers.get('access-control-expose-headers'), 'Server-Timing');
  // Without a token check only the app part; errors and binary answers are timed as well.
  assert.match((await request('GET', '/config')).headers.get('server-timing'), /^app;dur=\d+\.\d$/);
  assert.match((await request('GET', '/snapshot')).headers.get('server-timing'), /^app;dur=/);
  assert.match((await request('GET', '/snapshot', 'google-down')).headers.get('server-timing'), /^auth;dur=\d+\.\d, app;dur=/);
  assert.match((await request('POST', '/telemetry/perf', 'admin')).headers.get('server-timing'), /^auth;dur=/);
  assert.match((await request('GET', '/games/runner/skins/missing', 'admin')).headers.get('server-timing'), /^auth;dur=/);
});

test('the auth part of Server-Timing reflects a slow token check', async t => {
  const { request } = await serve(t, async token => { await new Promise(resolve => setTimeout(resolve, 60)); return fakeVerify(token); });
  const timing = (await request('GET', '/snapshot', 'admin')).headers.get('server-timing');
  const [, auth, app] = timing.match(/^auth;dur=([\d.]+), app;dur=([\d.]+)$/).map(Number);
  assert.ok(auth >= 50, timing);
  assert.ok(app < auth, timing);
});

test('registration, sign-out and admin changes ask for a fresh check; reads may use the cache', async t => {
  const { request, calls } = await serve(t, fakeVerify);
  await request('POST', '/auth/session', 'admin');
  await request('POST', '/auth/logout', 'admin');
  await request('DELETE', '/admin/accounts/nobody', 'admin');
  await request('PUT', '/admin/feedback/none', 'admin');
  await request('GET', '/auth/session', 'admin');
  await request('GET', '/snapshot', 'admin');
  await request('GET', '/admin/accounts', 'admin');
  await request('POST', '/actions', 'admin');
  assert.deepEqual(calls.map(c => c.options), [true, true, true, true, false, false, false, false].map(fresh => ({ fresh })));
});

test('account administration via /actions is checked again without the cache', async t => {
  const { request, calls } = await serve(t, fakeVerify);
  for (const action of ['account.approve', 'account.status', 'account.role', 'account.permissions', 'account.reconsider']) {
    calls.length = 0;
    await request('POST', '/actions', 'admin', {}, { action, uid: 'nobody', version: 0 });
    assert.deepEqual(calls.map(c => c.options), [{ fresh: false }, { fresh: true }], action);
  }
  calls.length = 0;
  await request('POST', '/actions', 'admin', {}, { action: 'settings.reminders', value: {} });
  assert.deepEqual(calls.map(c => c.options), [{ fresh: false }]);
});

test('a login revoked meanwhile cannot change accounts, even with a cached check', async t => {
  let revoked = false;
  const { request, app } = await serve(t, async (token, { fresh }) => {
    if (fresh && revoked) throw firebaseError('auth/id-token-revoked');
    return fakeVerify(token);
  });
  revoked = true;
  const response = await request('POST', '/actions', 'admin', {}, { action: 'account.role', uid: 'admin', role: 'member', version: 1 });
  assert.equal(response.status, 401);
  assert.equal(app.store.account('admin').role, 'admin');
  assert.equal((await request('GET', '/snapshot', 'admin')).status, 200);
});

test('with the real verifier a revocation is seen at the next sign-in, a Google outage is 503', async t => {
  const users = new Map([['admin', { disabled: false, tokensValidAfterTime: null }]]);
  let down = false, lookups = 0;
  const auth = {
    async verifyIdToken(token) { return { uid: token.split('@')[0], email: 'admin@example.invalid', email_verified: true, auth_time: Number(token.split('@')[1] ?? 1000) }; },
    async getUser(uid) { lookups++; if (down) throw Object.assign(new Error('socket hang up'), { code: 'app/network-error' }); if (!users.has(uid)) throw firebaseError('auth/user-not-found'); return users.get(uid); },
  };
  const verifier = createTokenVerifier(auth);
  const { request } = await serve(t, (token, options) => verifier.verify(token, options));
  assert.equal((await request('GET', '/snapshot', 'admin')).status, 200);
  assert.equal((await request('GET', '/snapshot', 'admin')).status, 200);
  assert.equal(lookups, 1);
  users.set('admin', { disabled: false, tokensValidAfterTime: new Date(2_000_000).toUTCString() });
  assert.equal((await request('POST', '/auth/session', 'admin@1000')).status, 401);
  assert.equal((await request('GET', '/snapshot', 'admin@2001')).status, 200);
  // A brand-new account without any entry during an outage: 503, not 401.
  down = true;
  assert.equal((await request('GET', '/snapshot', 'newcomer')).status, 503);
  // A known one keeps working from its entry.
  assert.equal((await request('POST', '/auth/session', 'admin@2001')).status, 200);
  verifier.forget('admin');
  down = false; users.delete('admin');
  assert.equal((await request('GET', '/snapshot', 'admin@2001')).status, 401);
});
