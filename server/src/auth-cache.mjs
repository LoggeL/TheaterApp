// Firebase ID tokens checked without a Google round trip per request (see docs/operations.md
// "Anmeldeprüfung"). `auth.verifyIdToken(token, true)` asks Google for the user record on every
// call (~150–250 ms). Signature, expiry, audience and issuer are checked locally with the public
// keys firebase-admin caches; only the revocation state (disabled, tokensValidAfterTime) comes
// from `auth.getUser` and is remembered per uid for `ttlMs`. Parallel requests of one account
// share a single lookup. A failed lookup at Google (network, 5xx, also while the server renews its
// own access token) keeps using an entry younger than `staleMs`; without one the error is
// `transient` and the API answers 503 instead of 401, so an outage at Google never signs anyone
// out. Such an entry also answers when Google has not
// replied within `staleWaitMs` (firebase-admin itself waits 25 s per attempt and retries, longer
// than the app's 20 s); the lookup then refreshes it in the background. Disabled or unknown users
// are never cached.

// firebase-admin codes and Node socket errors that say nothing about the token or the account.
const transientCodes = new Set(['app/network-error', 'app/network-timeout', 'auth/internal-error', 'ECONNRESET', 'ETIMEDOUT', 'ENOTFOUND', 'EAI_AGAIN', 'ECONNREFUSED', 'EPIPE']);
// A failed fetch of Google's public keys surfaces as `auth/argument-error`; only its message tells.
const keyFetchFailure = /Error fetching public keys|Error while making request/;
// The server's own access token could not be renewed: `cause` is Google's answer. 5xx and 429 are
// Google's doing; `invalid_grant` and other 4xx mean a broken service account and stay errors.
function tokenRenewalOutage(e) {
  const status = e.cause?.status ?? e.cause?.code;
  return e.code === 'app/invalid-credential' && typeof status === 'number' && (status >= 500 || status === 429);
}

/** True for errors of Google's or the network's making, never for a bad, expired or revoked token. */
export function isTransientAuthError(e) {
  if (!e) return false;
  if (e.transient === true) return true;
  if (transientCodes.has(e.code) || transientCodes.has(e.cause?.code) || tokenRenewalOutage(e)) return true;
  return e.code === 'auth/argument-error' && keyFetchFailure.test(e.message ?? '');
}

const authError = (code, message) => Object.assign(new Error(message), { code });
const transient = cause => Object.assign(new Error('Die Anmeldung kann gerade nicht geprüft werden.'), { code: cause?.code ?? 'auth/unavailable', transient: true, cause });

/**
 * `verify(token, { fresh })` resolves like `auth.verifyIdToken(token, true)`; `fresh` skips the
 * cached revocation state (sign-in, sign-out, admin changes). `forget(uid)` drops it, e.g. around
 * deleting the Firebase user, so the next request asks Google again.
 */
export function createTokenVerifier(auth, { ttlMs = 300_000, staleMs = 3_600_000, staleWaitMs = 1500, now = Date.now, maxEntries = 5000 } = {}) {
  const entries = new Map(); // uid -> { checkedAt, disabled, validAfterMs }
  const lookups = new Map(); // uid -> running getUser promise

  const lookup = uid => {
    const running = lookups.get(uid);
    if (running) return running;
    const promise = auth.getUser(uid).then(user => {
      const entry = { checkedAt: now(), disabled: user.disabled === true, validAfterMs: user.tokensValidAfterTime ? new Date(user.tokensValidAfterTime).getTime() : 0 };
      // A `forget` during the lookup wins: the answer may predate the deletion.
      if (lookups.get(uid) === promise) {
        if (entry.disabled) entries.delete(uid);
        else remember(uid, entry);
      }
      return entry;
    }, e => {
      if (lookups.get(uid) === promise && e?.code === 'auth/user-not-found') entries.delete(uid);
      throw e;
    }).finally(() => { if (lookups.get(uid) === promise) lookups.delete(uid); });
    lookups.set(uid, promise);
    return promise;
  };

  // Re-inserted on every check, so the Map's first key is the longest unchecked one.
  const remember = (uid, entry) => {
    entries.delete(uid);
    entries.set(uid, entry);
    while (entries.size > maxEntries) entries.delete(entries.keys().next().value);
  };

  // `promise`, or `fallback` once it has not settled within `ms`; the promise keeps running.
  const within = (promise, ms, fallback) => {
    let timer;
    const late = new Promise(resolve => { timer = setTimeout(resolve, ms, fallback); timer.unref?.(); });
    return Promise.race([promise, late]).finally(() => clearTimeout(timer));
  };

  const state = async (uid, fresh) => {
    const cached = entries.get(uid);
    const age = cached ? now() - cached.checkedAt : Infinity;
    if (!fresh && age < ttlMs) return cached;
    try {
      // A hanging Google must not hold up requests that a recent entry can answer.
      if (!fresh && age < staleMs) return await within(lookup(uid), staleWaitMs, cached);
      return await lookup(uid);
    } catch (e) {
      if (!isTransientAuthError(e)) throw e;
      const stale = entries.get(uid);
      if (stale && now() - stale.checkedAt < staleMs) return stale;
      throw transient(e);
    }
  };

  return {
    async verify(token, { fresh = false } = {}) {
      let decoded;
      try { decoded = await auth.verifyIdToken(token, false); } catch (e) { throw isTransientAuthError(e) ? transient(e) : e; }
      const entry = await state(decoded.uid, fresh);
      if (entry.disabled) throw authError('auth/user-disabled', 'The user record is disabled.');
      if (entry.validAfterMs && decoded.auth_time * 1000 < entry.validAfterMs) throw authError('auth/id-token-revoked', 'The Firebase ID token has been revoked.');
      return decoded;
    },
    forget(uid) {
      entries.delete(uid);
      lookups.delete(uid);
    },
    get size() { return entries.size; },
  };
}
