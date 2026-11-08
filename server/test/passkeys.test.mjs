import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { Passkeys } from '../src/passkeys.mjs';
import { createHttpServer } from '../src/http.mjs';
import { authenticator } from './helpers/passkey-authenticator.mjs';

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const theater = new Theater(store, { bootstrapEmail: 'member@example.com' });
  let now = Date.now();
  const identity = { uid: 'member', email: 'member@example.com', name: 'Test Person', email_verified: true, auth_time: Math.floor(now / 1000), firebase: { sign_in_provider: 'password' } };
  theater.session(identity);
  const user = { uid: identity.uid, email: identity.email, emailVerified: true, disabled: false, providerData: [{ providerId: 'password' }] };
  const issued = [];
  const auth = { getUser: async () => user, createCustomToken: async (uid, claims) => { issued.push({ uid, claims }); return 'custom-token-never-persist'; } };
  const service = new Passkeys({ theater, auth, rpId: 'app.example.com', webOrigins: ['https://app.example.com'], clock: () => now });
  async function enroll(device = authenticator()) {
    const start = await service.registrationOptions(identity, 'Mein Gerät');
    const response = device.register(start.options);
    const result = await service.register(identity, { challengeId: start.challengeId, response });
    return { device, key: result.passkeys.at(-1), start, response };
  }
  async function login(device, changes) {
    const start = await service.authenticationOptions('127.0.0.1');
    return service.authenticate({ challengeId: start.challengeId, response: device.authenticate(start.options, changes) }, '127.0.0.1');
  }
  return { store, theater, identity, user, auth, service, issued, enroll, login, advance: ms => now += ms };
}

test('real WebAuthn registration and signature log in the existing Firebase UID', async t => {
  const { service, identity, store, issued, enroll, login, theater } = setup(t);
  const { device, key, start } = await enroll();
  assert.equal(start.options.authenticatorSelection.residentKey, 'required');
  assert.equal(start.options.authenticatorSelection.userVerification, 'required');
  assert.notEqual(start.options.user.id, identity.uid);
  assert.equal(Buffer.from(start.options.user.id, 'base64url').length, 32);
  const result = await login(device);
  assert.deepEqual(result, { token: 'custom-token-never-persist', uid: identity.uid });
  assert.deepEqual(issued, [{ uid: identity.uid, claims: { theater_passkey: key.id } }]);
  assert.equal(service.list(identity.uid).passkeys[0].lastUsedAt !== null, true);
  assert.equal(service.list(identity.uid).passkeys[0].publicKey, undefined);
  assert.equal(JSON.stringify(theater.snapshot(identity.uid)).includes(device.id), false);
  assert.equal(JSON.stringify(store.db.prepare('SELECT data FROM passkeys').all()).includes(result.token), false);
  const next = await service.authenticationOptions('127.0.0.1');
  assert.ok(!next.options.allowCredentials?.length, 'no account enumeration through public options');
});

test('registration challenges are single use, bound to the current UID and expire', async t => {
  const { service, identity, enroll, advance } = setup(t);
  const { start, response } = await enroll();
  await assert.rejects(service.register(identity, { challengeId: start.challengeId, response }), { code: 'passkey_invalid' });
  const other = await service.registrationOptions(identity, 'Zweitgerät');
  const device = authenticator();
  const invalidResponse = device.register(other.options);
  advance(301000);
  identity.auth_time += 301;
  await assert.rejects(service.register(identity, { challengeId: other.challengeId, response: invalidResponse }), { code: 'passkey_invalid' });
});

for (const [name, changes] of [
  ['wrong origin', { origin: 'https://evil.example' }],
  ['wrong RP', { rpId: 'evil.example' }],
  ['missing user verification', { flags: 0x59 }],
  ['cross-origin frame without topOrigin', { extra: { crossOrigin: true } }],
]) test(`registration rejects ${name}`, async t => {
  const { service, identity } = setup(t);
  const start = await service.registrationOptions(identity, 'Gerät');
  await assert.rejects(service.register(identity, { challengeId: start.challengeId, response: authenticator().register(start.options, changes) }), { code: 'passkey_invalid' });
  assert.equal(service.list(identity.uid).passkeys.length, 0);
});

for (const [name, changes] of [
  ['wrong origin', { origin: 'https://evil.example' }],
  ['wrong RP', { rpId: 'evil.example' }],
  ['missing user verification', { flags: 0x19 }],
  ['wrong account handle', { userHandle: 'someone-else' }],
  ['cross-origin frame', { extra: { crossOrigin: true } }],
]) test(`authentication rejects ${name}`, async t => {
  const { enroll, login, issued } = setup(t);
  const { device } = await enroll();
  await assert.rejects(login(device, changes), { code: 'passkey_invalid' });
  assert.equal(issued.length, 0);
});

test('replayed challenges, invalid signatures and a decreasing counter never issue tokens', async t => {
  const { service, enroll, login, issued } = setup(t);
  const { device } = await enroll();
  const start = await service.authenticationOptions('ip');
  const request = { challengeId: start.challengeId, response: device.authenticate(start.options) };
  await service.authenticate(request, 'ip');
  await assert.rejects(service.authenticate(request, 'ip'), { code: 'passkey_invalid' });
  await assert.rejects(login(device, { counter: 1 }), { code: 'passkey_invalid' });
  const next = await service.authenticationOptions('ip');
  const response = device.authenticate(next.options, { counter: 2 });
  response.response.signature = Buffer.from('invalid').toString('base64url');
  await assert.rejects(service.authenticate({ challengeId: next.challengeId, response }, 'ip'), { code: 'passkey_invalid' });
  assert.equal(issued.length, 1);
});

test('expired login challenges are consumed, while synced zero counters remain usable', async t => {
  const { service, enroll, login, advance } = setup(t);
  const { device } = await enroll();
  await login(device, { counter: 0 }); await login(device, { counter: 0 });
  const start = await service.authenticationOptions('ip');
  advance(301000);
  const request = { challengeId: start.challengeId, response: device.authenticate(start.options) };
  await assert.rejects(service.authenticate(request, 'ip'), { code: 'passkey_invalid' });
  await assert.rejects(service.authenticate(request, 'ip'), { code: 'passkey_invalid' });
});

test('enrollment needs recent auth, verified email, membership and a recovery provider', async t => {
  const { service, identity, user, theater, store } = setup(t);
  await assert.rejects(service.registrationOptions({ ...identity, auth_time: identity.auth_time - 400 }, 'Gerät'), { code: 'recent_login_required' });
  user.providerData = [];
  await assert.rejects(service.registrationOptions(identity, 'Gerät'), { code: 'recovery_required' });
  user.providerData = [{ providerId: 'password' }]; user.emailVerified = false;
  await assert.rejects(service.registrationOptions(identity, 'Gerät'), { code: 'passkey_invalid' });
  user.emailVerified = true;
  store.saveAccount({ ...store.account(identity.uid), status: 'pending' });
  await assert.rejects(service.registrationOptions(identity, 'Gerät'), { status: 403 });
  // The provider name "custom" itself must never satisfy email verification.
  assert.equal(theater.session({ ...identity, email_verified: false, firebase: { sign_in_provider: 'custom' }, theater_passkey: 'key' }).identityReady, false);
});

test('Firebase disablement, deletion and unverified mail stop passkey sign-in', async t => {
  const { enroll, login, user, auth, issued } = setup(t);
  const { device } = await enroll();
  user.disabled = true;
  await assert.rejects(login(device), { code: 'passkey_invalid' });
  user.disabled = false; user.emailVerified = false;
  await assert.rejects(login(device), { code: 'passkey_invalid' });
  auth.getUser = async () => { throw Object.assign(new Error('deleted'), { code: 'auth/user-not-found' }); };
  await assert.rejects(login(device), { code: 'passkey_invalid' });
  assert.equal(issued.length, 0);
});

test('suspension or key deletion while signing prevents returning a custom token', async t => {
  const { enroll, login, auth, store, identity } = setup(t);
  const { device } = await enroll();
  auth.createCustomToken = async () => { store.saveAccount({ ...store.account(identity.uid), status: 'suspended' }); return 'must-not-leak'; };
  await assert.rejects(login(device), { code: 'passkey_invalid' });
  store.saveAccount({ ...store.account(identity.uid), status: 'approved' });
  auth.createCustomToken = async () => { store.db.prepare('DELETE FROM passkeys').run(); return 'must-not-leak'; };
  await assert.rejects(login(device), { code: 'passkey_invalid' });
});

test('removal invalidates custom sessions, preserves recovery and account deletion cascades', async t => {
  const { service, enroll, identity, store, user } = setup(t);
  const { key } = await enroll();
  const signedIn = { ...identity, firebase: { sign_in_provider: 'custom' }, theater_passkey: key.id };
  service.assertIdentity(signedIn);
  assert.throws(() => service.assertIdentity({ ...signedIn, uid: 'other' }), { code: 'passkey_invalid' });
  user.providerData = [];
  await assert.rejects(service.remove(identity, key.id), { code: 'recovery_required' });
  user.providerData = [{ providerId: 'password' }];
  await service.remove(identity, key.id);
  assert.throws(() => service.assertIdentity(signedIn), { code: 'passkey_invalid' });
  await enroll(); await service.registrationOptions(identity, 'noch offen');
  store.deleteAccount(identity.uid);
  for (const table of ['passkeys', 'passkey_users', 'passkey_challenges']) assert.equal(store.db.prepare(`SELECT count(*) AS n FROM ${table}`).get().n, 0);
});

test('public options are rate-limited and have a bounded persistent challenge queue', async t => {
  const { service, store, advance } = setup(t);
  for (let i = 0; i < 30; i++) await service.authenticationOptions('ip');
  await assert.rejects(service.authenticationOptions('ip'), { status: 429 });
  advance(600001);
  await service.authenticationOptions('ip');
  assert.equal(store.db.prepare('SELECT count(*) AS n FROM passkey_challenges').get().n, 1);
});

test('HTTP exposes only public options, freshly verifies changes and rejects removed sessions', async t => {
  const { theater, identity, service, enroll, store } = setup(t);
  const { device, key } = await enroll();
  const calls = [];
  const custom = { ...identity, firebase: { sign_in_provider: 'custom' }, theater_passkey: key.id };
  const server = createHttpServer({ theater, passkeys: service, allowedOrigins: ['https://app.example.com'], verifyToken: async (token, opts) => { calls.push(opts); return token === 'custom' ? custom : identity; } });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const request = (path, { method = 'GET', token, body, origin } = {}) => fetch(`${base}/api/mobile/v1${path}`, { method, headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(origin ? { origin } : {}), 'content-type': 'application/json' }, ...(body ? { body: JSON.stringify(body) } : {}) });
  assert.equal((await request('/passkeys')).status, 401);
  const options = await request('/auth/passkeys/options', { method: 'POST', body: {} });
  assert.equal(options.headers.get('cache-control'), 'no-store');
  const start = await options.json();
  const response = device.authenticate(start.options);
  const login = await request('/auth/passkeys/verify', { method: 'POST', body: { challengeId: start.challengeId, response } });
  assert.equal(login.status, 200);
  assert.equal(login.headers.get('cache-control'), 'no-store');
  assert.equal((await request('/auth/passkeys/options', { method: 'POST', origin: 'https://evil.example', body: {} })).status, 403);
  assert.equal((await request('/passkeys/options', { method: 'POST', token: 'normal', body: { name: 'Neu' } })).status, 200);
  assert.deepEqual(calls.at(-1), { fresh: true });
  assert.equal((await request('/auth/session', { token: 'custom' })).status, 200);
  store.db.prepare('DELETE FROM passkeys WHERE id=?').run(key.id);
  assert.equal((await request('/auth/session', { token: 'custom' })).status, 401);
  assert.equal((await request('/auth/passkeys/verify', { method: 'POST', body: { padding: 'x'.repeat(66000) } })).status, 413);
});

test('registration challenges, handles and removal are bound to one account', async t => {
  const { service, theater, store, identity, auth, enroll, login } = setup(t);
  const { device, key } = await enroll();
  const other = { ...identity, uid: 'other', email: 'other@example.com' };
  theater.session(other);
  store.saveAccount({ ...store.account(other.uid), status: 'approved', personId: 2 });
  store.put('members', 2, { id: 2, name: 'Other', active: true });
  auth.getUser = async uid => ({ uid, email: `${uid}@example.com`, emailVerified: true, disabled: false, providerData: [{ providerId: 'password' }] });
  const pending = await service.registrationOptions(identity, 'Member key');
  const response = authenticator().register(pending.options);
  await assert.rejects(service.register(other, { challengeId: pending.challengeId, response }), { code: 'passkey_invalid' });
  await assert.rejects(service.remove(other, key.id), { status: 404 });
  const theirs = await service.registrationOptions(other, 'Other key');
  assert.notEqual(theirs.options.user.id, pending.options.user.id);
  await assert.rejects(login(device, { userHandle: theirs.options.user.id }), { code: 'passkey_invalid' });
  await service.register(identity, { challengeId: pending.challengeId, response });
});

test('concurrent valid assertions cannot both commit from the same counter version', async t => {
  const { service, auth, enroll } = setup(t);
  const { device } = await enroll();
  const requests = await Promise.all([service.authenticationOptions('first'), service.authenticationOptions('second')]);
  let release;
  const gate = new Promise(resolve => release = resolve);
  let arrived = 0, both;
  const ready = new Promise(resolve => both = resolve);
  auth.createCustomToken = async () => { if (++arrived === 2) both(); await gate; return 'token'; };
  const pending = requests.map((r, i) => service.authenticate({ challengeId: r.challengeId, response: device.authenticate(r.options, { counter: i + 1 }) }, `ip${i}`));
  await ready; release();
  const results = await Promise.allSettled(pending);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
  assert.equal(results.find(r => r.status === 'rejected').reason.code, 'passkey_invalid');
});

test('Android accepts only configured signing origins and publishes mutual association', async t => {
  const { theater, auth, identity } = setup(t);
  const fingerprint = 'AB'.repeat(32);
  const service = new Passkeys({ theater, auth, rpId: 'app.example.com', webOrigins: ['https://app.example.com'], androidFingerprints: [fingerprint] });
  const origin = `android:apk-key-hash:${Buffer.from(fingerprint, 'hex').toString('base64url')}`;
  const device = authenticator();
  const r = await service.registrationOptions(identity, 'Android');
  await service.register(identity, { challengeId: r.challengeId, response: device.register(r.options, { origin }) });
  const a = await service.authenticationOptions('ip');
  await service.authenticate({ challengeId: a.challengeId, response: device.authenticate(a.options, { origin }) }, 'ip');
  const b = await service.authenticationOptions('ip');
  await assert.rejects(service.authenticate({ challengeId: b.challengeId, response: device.authenticate(b.options, { origin: 'android:apk-key-hash:wrong', counter: 2 }) }, 'ip'), { code: 'passkey_invalid' });
  assert.deepEqual(service.assetLinks.map(s => s.target.namespace), ['web', 'android_app']);
  assert.equal(service.assetLinks[0].target.site, 'https://app.example.com');
  assert.equal(service.assetLinks[1].target.sha256_cert_fingerprints[0], Array(32).fill('AB').join(':'));
  assert.throws(() => new Passkeys({ theater, auth, rpId: 'app.example.com', webOrigins: ['https://evil.example'] }));
});
