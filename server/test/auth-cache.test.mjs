import test from 'node:test';
import assert from 'node:assert/strict';
import { createTokenVerifier, isTransientAuthError } from '../src/auth-cache.mjs';

// Tokens are `uid` or `uid@authTimeSeconds`; the fake checks nothing else, like a valid signature.
function fakeAuth() {
  const users = new Map([['sam', { disabled: false, tokensValidAfterTime: null }]]);
  const calls = { verify: [], getUser: 0 };
  let failure = null, verifyFailure = null, gate = null;
  const auth = {
    async verifyIdToken(token, checkRevoked) {
      calls.verify.push(checkRevoked);
      if (verifyFailure) throw verifyFailure;
      if (token === 'expired') throw Object.assign(new Error('expired'), { code: 'auth/id-token-expired' });
      const [uid, authTime = '1000'] = token.split('@');
      return { uid, sub: uid, auth_time: Number(authTime) };
    },
    async getUser(uid) {
      calls.getUser++;
      const user = users.get(uid); // read when Google answers, before the reply travels back
      if (gate) await gate;
      if (failure) throw failure;
      if (!user) throw Object.assign(new Error('no user'), { code: 'auth/user-not-found' });
      return { uid, ...user };
    },
  };
  return {
    auth, users, calls,
    fail(error) { failure = error; },
    failVerify(error) { verifyFailure = error; },
    hold() { let open; gate = new Promise(resolve => { open = resolve; }); return () => { gate = null; open(); }; },
  };
}

const networkError = () => Object.assign(new Error('Error while making request: socket hang up. Error code: ECONNRESET'), { code: 'app/network-error' });

function setup(options = {}) {
  const fake = fakeAuth();
  const clock = { now: 1_000_000 };
  const verifier = createTokenVerifier(fake.auth, { now: () => clock.now, ...options });
  return { ...fake, clock, verifier, tick: ms => { clock.now += ms; } };
}

test('a cached revocation check spares Google until the TTL ends', async () => {
  const { verifier, calls, tick } = setup();
  assert.equal((await verifier.verify('sam')).uid, 'sam');
  await verifier.verify('sam');
  tick(299_000);
  await verifier.verify('sam');
  assert.equal(calls.getUser, 1);
  // The signature is still checked locally every time, never with firebase-admin's own revocation lookup.
  assert.deepEqual(calls.verify, [false, false, false]);
  tick(2_000);
  await verifier.verify('sam');
  assert.equal(calls.getUser, 2);
});

test('parallel requests of one account share a single lookup', async () => {
  const { verifier, calls, hold } = setup();
  const release = hold();
  const pending = Array.from({ length: 56 }, () => verifier.verify('sam'));
  await new Promise(resolve => setImmediate(resolve));
  release();
  const results = await Promise.all(pending);
  assert.equal(results.length, 56);
  assert.ok(results.every(r => r.uid === 'sam'));
  assert.equal(calls.getUser, 1);
});

test('revoked tokens are rejected, newer sign-ins of the same user are not', async () => {
  const { verifier, users } = setup();
  users.set('sam', { disabled: false, tokensValidAfterTime: new Date(2_000_000).toUTCString() });
  await assert.rejects(verifier.verify('sam@1999'), { code: 'auth/id-token-revoked' });
  assert.equal((await verifier.verify('sam@2000')).uid, 'sam');
});

test('disabled users are rejected and never cached', async () => {
  const { verifier, users, calls } = setup();
  users.set('sam', { disabled: true, tokensValidAfterTime: null });
  await assert.rejects(verifier.verify('sam'), { code: 'auth/user-disabled' });
  await assert.rejects(verifier.verify('sam'), { code: 'auth/user-disabled' });
  assert.equal(calls.getUser, 2);
  users.set('sam', { disabled: false, tokensValidAfterTime: null });
  assert.equal((await verifier.verify('sam')).uid, 'sam');
  assert.equal(verifier.size, 1);
});

test('unknown users are rejected, not cached, and drop an older entry', async () => {
  const { verifier, users, calls, tick } = setup();
  await verifier.verify('sam');
  users.delete('sam');
  tick(301_000);
  await assert.rejects(verifier.verify('sam'), { code: 'auth/user-not-found' });
  assert.equal(verifier.size, 0);
  await assert.rejects(verifier.verify('sam'), { code: 'auth/user-not-found' });
  assert.equal(calls.getUser, 3);
});

test('network errors keep a recent entry and are transient without one', async () => {
  const { verifier, fail, tick } = setup();
  await verifier.verify('sam');
  fail(networkError());
  tick(301_000);
  assert.equal((await verifier.verify('sam')).uid, 'sam');
  tick(3_300_000); // the entry is now older than staleMs (1 h)
  const error = await verifier.verify('sam').then(() => null, e => e);
  assert.equal(error.transient, true);
  assert.equal(error.code, 'app/network-error');
  assert.ok(isTransientAuthError(error));
  const newcomer = await verifier.verify('kim').then(() => null, e => e);
  assert.equal(newcomer.transient, true);
});

test('a hanging lookup answers from a recent entry after staleWaitMs and refreshes it later', async () => {
  const { verifier, users, calls, hold, tick } = setup({ staleWaitMs: 20 });
  await verifier.verify('sam');
  tick(360_000); // 6 minutes: past the TTL, well within staleMs
  users.set('sam', { disabled: false, tokensValidAfterTime: new Date(2_000_000).toUTCString() });
  const release = hold(); // Google never answers until released
  const started = Date.now();
  const results = await Promise.all(Array.from({ length: 5 }, () => verifier.verify('sam@1000')));
  assert.ok(results.every(r => r.uid === 'sam'));
  assert.ok(Date.now() - started < 1000);
  assert.equal(calls.getUser, 2); // one shared lookup, still running
  release();
  await new Promise(resolve => setImmediate(resolve));
  // The background lookup stored Google's answer: the revocation now applies.
  await assert.rejects(verifier.verify('sam@1000'), { code: 'auth/id-token-revoked' });
  assert.equal(calls.getUser, 2);
});

test('a lookup that answers in time decides, even past the TTL; fresh checks and newcomers wait', async () => {
  const { verifier, users, hold, tick } = setup({ staleWaitMs: 20 });
  await verifier.verify('sam');
  tick(360_000);
  users.delete('sam');
  await assert.rejects(verifier.verify('sam'), { code: 'auth/user-not-found' });
  users.set('sam', { disabled: false, tokensValidAfterTime: null });
  await verifier.verify('sam');
  tick(360_000);
  const release = hold();
  let settled = false;
  const fresh = verifier.verify('sam', { fresh: true }).finally(() => { settled = true; });
  const newcomer = verifier.verify('kim').then(() => null, e => e);
  await new Promise(resolve => setTimeout(resolve, 60));
  assert.equal(settled, false);
  release();
  assert.equal((await fresh).uid, 'sam');
  assert.equal((await newcomer).code, 'auth/user-not-found');
});

test('5xx answers and socket errors count as transient, token errors do not', async () => {
  assert.ok(isTransientAuthError({ code: 'auth/internal-error' }));
  assert.ok(isTransientAuthError({ code: 'app/network-timeout' }));
  assert.ok(isTransientAuthError({ code: 'ETIMEDOUT' }));
  assert.ok(isTransientAuthError({ code: 'app/network-error', cause: { code: 'EAI_AGAIN' } }));
  assert.ok(isTransientAuthError({ code: 'auth/argument-error', message: 'Error fetching public keys for Google certs: 503' }));
  for (const code of ['auth/id-token-expired', 'auth/id-token-revoked', 'auth/user-disabled', 'auth/user-not-found', 'auth/argument-error']) assert.equal(isTransientAuthError({ code, message: 'Firebase ID token has invalid signature.' }), false, code);
  assert.equal(isTransientAuthError(new Error('invalid')), false);
});

test('a failed renewal of the server\'s own access token is transient only for 5xx and 429', async () => {
  const renewal = status => Object.assign(new Error('Credential implementation failed'), { code: 'app/invalid-credential', cause: { code: status, status } });
  assert.ok(isTransientAuthError(renewal(503)));
  assert.ok(isTransientAuthError(renewal(429)));
  // gaxios reports the status in `code`; a socket error has none.
  assert.ok(isTransientAuthError({ code: 'app/invalid-credential', cause: { code: 500 } }));
  assert.ok(isTransientAuthError({ code: 'app/invalid-credential', cause: { code: 'ECONNRESET' } }));
  assert.equal(isTransientAuthError(renewal(400)), false);
  assert.equal(isTransientAuthError(renewal(401)), false);
  assert.equal(isTransientAuthError({ code: 'app/invalid-credential', cause: new Error('invalid_grant') }), false);
  assert.equal(isTransientAuthError({ code: 'app/invalid-credential' }), false);

  const { verifier, fail, tick } = setup();
  await verifier.verify('sam');
  tick(360_000);
  fail(renewal(503));
  assert.equal((await verifier.verify('sam')).uid, 'sam');
  await assert.rejects(verifier.verify('kim'), e => e.transient === true && isTransientAuthError(e));
  // A rejected service account is no outage: the entry does not hide it.
  fail(renewal(400));
  await assert.rejects(verifier.verify('sam'), e => e.code === 'app/invalid-credential' && !e.transient);
});

test('a failed local check is transient only when the keys could not be fetched', async () => {
  const { verifier, failVerify, calls } = setup();
  await assert.rejects(verifier.verify('expired'), e => e.code === 'auth/id-token-expired' && !e.transient);
  failVerify(networkError());
  await assert.rejects(verifier.verify('sam'), { transient: true });
  assert.equal(calls.getUser, 0);
});

test('forget forces a new lookup, also over a running one', async () => {
  const { verifier, users, calls, hold } = setup();
  await verifier.verify('sam');
  verifier.forget('sam');
  await verifier.verify('sam');
  assert.equal(calls.getUser, 2);
  // A lookup that started before the deletion must not store the user afterwards.
  verifier.forget('sam');
  const release = hold();
  const running = verifier.verify('sam');
  await new Promise(resolve => setImmediate(resolve));
  users.delete('sam');
  verifier.forget('sam');
  release();
  assert.equal((await running).uid, 'sam');
  assert.equal(verifier.size, 0);
  await assert.rejects(verifier.verify('sam'), { code: 'auth/user-not-found' });
  assert.equal(calls.getUser, 4);
});

test('fresh skips the cache and refreshes the entry', async () => {
  const { verifier, users, calls } = setup();
  await verifier.verify('sam');
  users.set('sam', { disabled: false, tokensValidAfterTime: new Date(2_000_000).toUTCString() });
  assert.equal((await verifier.verify('sam@1000')).uid, 'sam'); // still the cached state
  await assert.rejects(verifier.verify('sam@1000', { fresh: true }), { code: 'auth/id-token-revoked' });
  await assert.rejects(verifier.verify('sam@1000'), { code: 'auth/id-token-revoked' }); // refreshed entry
  assert.equal(calls.getUser, 2);
});

test('the cache stays bounded', async () => {
  const { verifier, users } = setup({ maxEntries: 3 });
  for (const uid of ['a', 'b', 'c', 'd', 'e']) { users.set(uid, { disabled: false }); await verifier.verify(uid); }
  assert.equal(verifier.size, 3);
});
