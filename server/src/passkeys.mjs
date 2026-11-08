import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { generateRegistrationOptions, verifyRegistrationResponse, generateAuthenticationOptions, verifyAuthenticationResponse } from '@simplewebauthn/server';
import { AppError } from './theater.mjs';

const ttl = 5 * 60_000;
const maxKeys = 10;
const invalid = () => new AppError(401, 'Der Passkey konnte nicht bestätigt werden. Bitte erneut versuchen.', 'passkey_invalid');
const unavailable = () => new AppError(503, 'Passkeys sind gerade nicht verfügbar. Bitte melde dich mit Passwort oder Google an.', 'passkey_unavailable');
const recent = () => new AppError(401, 'Bitte bestätige deine Anmeldung erneut, um Passkeys zu verwalten.', 'recent_login_required');
const fromRow = row => row ? { ...JSON.parse(row.data), id: row.id, uid: row.uid, credentialId: row.credential_id } : null;
const publicKey = ({ id, name, createdAt, lastUsedAt, backedUp }) => ({ id, name, createdAt, lastUsedAt, backedUp });
const validId = id => typeof id === 'string' && /^[A-Za-z0-9_-]{1,1400}$/.test(id);
const assertClientData = response => {
  try {
    const encoded = response?.response?.clientDataJSON;
    if (typeof encoded !== 'string' || encoded.length > 8192) throw invalid();
    const data = JSON.parse(Buffer.from(encoded, 'base64url').toString('utf8'));
    // The app has no embedded sign-in flow. Never authorize one through an
    // arbitrary parent frame, including browsers without topOrigin support.
    if (data.crossOrigin === true || data.topOrigin) throw invalid();
  } catch { throw invalid(); }
};

/** WebAuthn verification belongs here, Firebase remains the session issuer.
 * Private keys, biometric data and Firebase custom tokens are never stored.
 */
export class Passkeys {
  constructor({ theater, auth, rpId, webOrigins, androidFingerprints = [], androidPackage = 'de.kolpingtheater.ramsen.theaterapp', appleAppId = '', clock = Date.now }) {
    this.theater = theater; this.store = theater.store; this.auth = auth; this.clock = clock;
    if (!rpId || /[/:\s]/.test(rpId) || !webOrigins?.length) throw new Error('Invalid passkey relying party');
    this.rpId = rpId;
    this.webOrigins = webOrigins.map(value => {
      const url = new URL(value);
      if (url.origin !== value || (url.protocol !== 'https:' && !(url.protocol === 'http:' && url.hostname === 'localhost' && rpId === 'localhost')) || !(url.hostname === rpId || url.hostname.endsWith(`.${rpId}`))) throw new Error('Invalid passkey web origin');
      return value;
    });
    this.androidFingerprints = androidFingerprints.map(value => {
      const hex = value.replaceAll(':', '').toUpperCase();
      if (!/^[0-9A-F]{64}$/.test(hex)) throw new Error('Invalid Android signing fingerprint');
      return hex.match(/../g).join(':');
    });
    this.androidPackage = androidPackage;
    if (appleAppId && !/^[A-Z0-9]{10}\.[A-Za-z0-9.-]+$/.test(appleAppId)) throw new Error('Invalid Apple app ID');
    this.appleAppId = appleAppId;
    this.origins = [...this.webOrigins, ...this.androidFingerprints.map(value => `android:apk-key-hash:${Buffer.from(value.replaceAll(':', ''), 'hex').toString('base64url')}`)];
    this.limits = new Map();
  }

  get configuration() { return { enabled: true, rpId: this.rpId, webOrigins: this.webOrigins, android: this.androidFingerprints.length > 0, apple: !!this.appleAppId }; }
  get assetLinks() { return this.androidFingerprints.length ? [...this.webOrigins.map(site => ({ relation: ['delegate_permission/common.get_login_creds'], target: { namespace: 'web', site } })), { relation: ['delegate_permission/common.get_login_creds'], target: { namespace: 'android_app', package_name: this.androidPackage, sha256_cert_fingerprints: this.androidFingerprints } }] : []; }
  get appleAssociation() { return { webcredentials: { apps: this.appleAppId ? [this.appleAppId] : [] } }; }

  _limit(key, maximum = 30) {
    const now = this.clock();
    for (const [id, value] of this.limits) if (value.until <= now) this.limits.delete(id);
    const id = createHash('sha256').update(key).digest('hex');
    if (!this.limits.has(id)) {
      if (this.limits.size >= 4096) throw unavailable();
      this.limits.set(id, { count: 0, until: now + 10 * 60_000 });
    }
    const bucket = this.limits.get(id);
    if (++bucket.count > maximum) throw Object.assign(new AppError(429, 'Zu viele Passkey-Anfragen. Bitte später erneut versuchen.', 'rate_limited'), { retryAfter: Math.ceil((bucket.until - now) / 1000) });
  }

  _rows(uid) { return this.store.db.prepare('SELECT * FROM passkeys WHERE uid=? ORDER BY id').all(uid).map(fromRow); }
  _key(id) { return fromRow(this.store.db.prepare('SELECT * FROM passkeys WHERE id=?').get(id)); }
  _account(uid) {
    const account = this.theater.account(uid);
    if (account.emailVerified !== true) throw new AppError(403, 'Bestätige zuerst deine E-Mail-Adresse, bevor du Passkeys verwendest.', 'email_unverified');
    return account;
  }
  _recent(identity) {
    const at = Number(identity.auth_time) * 1000, now = this.clock();
    if (!Number.isFinite(at) || at > now + 30_000 || now - at > ttl) throw recent();
  }
  async _firebase(uid, identity = null) {
    let user;
    try { user = await this.auth.getUser(uid); } catch (error) {
      if (error.code === 'auth/user-not-found') throw invalid();
      throw unavailable();
    }
    if (user.disabled || !user.emailVerified) throw invalid();
    if (identity && Date.parse(user.tokensValidAfterTime) > Number(identity.auth_time) * 1000) throw recent();
    return user;
  }
  _handle(uid) {
    let row = this.store.db.prepare('SELECT handle FROM passkey_users WHERE uid=?').get(uid);
    if (!row) {
      row = { handle: randomBytes(32).toString('base64url') };
      this.store.db.prepare('INSERT INTO passkey_users(uid,handle) VALUES(?,?)').run(uid, row.handle);
    }
    return row.handle;
  }
  _challenge(kind, data, uid = null) {
    const now = this.clock();
    this.store.db.prepare('DELETE FROM passkey_challenges WHERE expires_at <= ?').run(now);
    if (this.store.db.prepare('SELECT count(*) AS n FROM passkey_challenges').get().n >= 1000) throw unavailable();
    const id = randomBytes(32).toString('base64url');
    this.store.db.prepare('INSERT INTO passkey_challenges VALUES(?,?,?,?,?)').run(id, uid, kind, now + ttl, JSON.stringify(data));
    return id;
  }
  _consume(id, kind, uid = null) {
    if (!validId(id)) throw invalid();
    const row = this.store.transaction(() => {
      const row = this.store.db.prepare('SELECT * FROM passkey_challenges WHERE id=? AND kind=? AND uid IS ?').get(id, kind, uid);
      if (row) this.store.db.prepare('DELETE FROM passkey_challenges WHERE id=?').run(id);
      return row;
    });
    // Validate after commit: expired or invalid attempts must stay consumed.
    if (!row || row.expires_at <= this.clock()) throw invalid();
    return JSON.parse(row.data);
  }

  /** Check on every request: removing a passkey also ends sessions issued for it. */
  assertIdentity(identity) {
    if (identity.firebase?.sign_in_provider !== 'custom') return;
    const key = typeof identity.theater_passkey === 'string' && this._key(identity.theater_passkey);
    if (!key || key.uid !== identity.uid || identity.email_verified !== true) throw invalid();
  }

  list(uid) { this._account(uid); return { passkeys: this._rows(uid).map(publicKey) }; }

  async registrationOptions(identity, name) {
    this._limit(`manage:${identity.uid}`, 10);
    this._recent(identity); this._account(identity.uid);
    if (typeof name !== 'string' || !name.trim() || name.trim().length > 60 || /[\u0000-\u001f\u007f]/.test(name)) throw new AppError(400, 'Bitte einen Namen mit höchstens 60 Zeichen eingeben.');
    const user = await this._firebase(identity.uid, identity);
    if (!user.providerData?.length) throw new AppError(409, 'Verknüpfe zuerst Passwort oder Google als weitere Anmeldeart.', 'recovery_required');
    const account = this._account(identity.uid);
    const keys = this._rows(identity.uid);
    if (keys.length >= maxKeys) throw new AppError(409, 'Du kannst höchstens zehn Passkeys hinterlegen. Entferne zuerst einen alten Passkey.');
    const handle = this._handle(identity.uid);
    const options = await generateRegistrationOptions({ rpName: 'Kolpingtheater Ramsen', rpID: this.rpId, userID: Buffer.from(handle, 'base64url'), userName: user.email || account.email, userDisplayName: account.name,
      attestationType: 'none', supportedAlgorithmIDs: [-7, -257], timeout: ttl,
      excludeCredentials: keys.map(k => ({ id: k.credentialId, transports: k.transports })),
      authenticatorSelection: { residentKey: 'required', userVerification: 'required' },
    });
    this._recent(identity); this._account(identity.uid);
    return { challengeId: this._challenge('register', { challenge: options.challenge, name: name.trim(), handle }, identity.uid), options };
  }

  async register(identity, { challengeId, response }) {
    this._limit(`verify-register:${identity.uid}`, 20);
    this._recent(identity); this._account(identity.uid);
    const challenge = this._consume(challengeId, 'register', identity.uid);
    assertClientData(response);
    let result;
    try { result = await verifyRegistrationResponse({ response, expectedChallenge: challenge.challenge, expectedOrigin: this.origins, expectedRPID: this.rpId, requireUserVerification: true, supportedAlgorithmIDs: [-7, -257] }); } catch { throw invalid(); }
    if (!result.verified || !result.registrationInfo?.userVerified) throw invalid();
    const user = await this._firebase(identity.uid, identity);
    if (!user.providerData?.length) throw new AppError(409, 'Eine weitere Anmeldeart wird zur Wiederherstellung benötigt.', 'recovery_required');
    const info = result.registrationInfo, credential = info.credential;
    this.store.transaction(() => {
      this._recent(identity); this._account(identity.uid); this.assertIdentity(identity);
      if (this._rows(identity.uid).length >= maxKeys) throw new AppError(409, 'Du hast bereits zehn Passkeys.');
      if (this.store.db.prepare('SELECT id FROM passkeys WHERE credential_id=?').get(credential.id)) throw new AppError(409, 'Dieser Passkey ist bereits hinterlegt.', 'passkey_exists');
      const id = randomUUID();
      const data = { name: challenge.name, handle: challenge.handle, publicKey: Buffer.from(credential.publicKey).toString('base64url'), counter: credential.counter, transports: credential.transports, deviceType: info.credentialDeviceType, backedUp: info.credentialBackedUp, createdAt: new Date(this.clock()).toISOString(), lastUsedAt: null, version: 1 };
      this.store.db.prepare('INSERT INTO passkeys VALUES(?,?,?,?)').run(id, identity.uid, credential.id, JSON.stringify(data));
      this.store.audit(identity.uid, 'passkey.add', id);
    });
    return this.list(identity.uid);
  }

  async authenticationOptions(ip) {
    this._limit(`login:${ip}`);
    const options = await generateAuthenticationOptions({ rpID: this.rpId, userVerification: 'required', timeout: ttl });
    return { challengeId: this._challenge('login', { challenge: options.challenge }), options };
  }

  async authenticate({ challengeId, response }, ip) {
    this._limit(`verify-login:${ip}`);
    const challenge = this._consume(challengeId, 'login');
    assertClientData(response);
    if (!validId(response?.id)) throw invalid();
    const key = fromRow(this.store.db.prepare('SELECT * FROM passkeys WHERE credential_id=?').get(response.id));
    if (!key || response.response?.userHandle !== key.handle) throw invalid();
    // Use the same response for unknown, suspended, unverified and inactive accounts.
    try { this._account(key.uid); } catch { throw invalid(); }
    let result;
    try { result = await verifyAuthenticationResponse({ response, expectedChallenge: challenge.challenge, expectedOrigin: this.origins, expectedRPID: this.rpId, requireUserVerification: true,
      credential: { id: key.credentialId, publicKey: new Uint8Array(Buffer.from(key.publicKey, 'base64url')), counter: key.counter, transports: key.transports },
    }); } catch { throw invalid(); }
    if (!result.verified || !result.authenticationInfo.userVerified) throw invalid();
    await this._firebase(key.uid);
    const check = () => {
      const current = this._key(key.id);
      try { this._account(key.uid); } catch { throw invalid(); }
      if (!current || current.version !== key.version) throw invalid();
    };
    check();
    let token;
    try { token = await this.auth.createCustomToken(key.uid, { theater_passkey: key.id }); } catch { throw unavailable(); }
    // Signing a token can be asynchronous. Recheck deletion/suspension/concurrent
    // assertions before updating the counter or letting that token leave the server.
    this.store.transaction(() => {
      check();
      const { id, uid, credentialId, ...data } = key;
      data.counter = result.authenticationInfo.newCounter;
      data.backedUp = result.authenticationInfo.credentialBackedUp;
      data.lastUsedAt = new Date(this.clock()).toISOString(); data.version++;
      this.store.db.prepare('UPDATE passkeys SET data=? WHERE id=?').run(JSON.stringify(data), id);
    });
    return { token, uid: key.uid };
  }

  async remove(identity, id) {
    this._limit(`manage:${identity.uid}`, 10);
    this._recent(identity); this._account(identity.uid);
    const user = await this._firebase(identity.uid, identity);
    this.store.transaction(() => {
      this._recent(identity); this._account(identity.uid); this.assertIdentity(identity);
      const key = this._key(id);
      if (!key || key.uid !== identity.uid) throw new AppError(404, 'Passkey nicht gefunden.');
      if (!user.providerData?.length && this._rows(identity.uid).length <= 1) throw new AppError(409, 'Verknüpfe zuerst eine weitere Anmeldeart.', 'recovery_required');
      this.store.db.prepare('DELETE FROM passkeys WHERE id=?').run(id);
      this.store.audit(identity.uid, 'passkey.remove', id);
    });
    return this.list(identity.uid);
  }
}

export function passkeysFromEnvironment(theater, auth, env = process.env) {
  if (!env.PASSKEY_RP_ID) return null;
  return new Passkeys({ theater, auth, rpId: env.PASSKEY_RP_ID,
    webOrigins: (env.PASSKEY_WEB_ORIGINS ?? '').split(',').map(s => s.trim()).filter(Boolean),
    androidFingerprints: (env.PASSKEY_ANDROID_SHA256 ?? '').split(',').map(s => s.trim()).filter(Boolean),
    appleAppId: env.PASSKEY_APPLE_APP_ID ?? '',
  });
}
