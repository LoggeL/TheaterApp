// Local WebAuthn authenticator for protocol tests. Private keys exist only in memory.
import { createHash, generateKeyPairSync, randomBytes, sign } from 'node:crypto';
import { isoCBOR } from '@simplewebauthn/server/helpers';
const hash = value => createHash('sha256').update(value).digest();
const encode = value => Buffer.from(isoCBOR.encode(value));
const counterBytes = value => { const b = Buffer.alloc(4); b.writeUInt32BE(value); return b; };
const clientData = (type, options, origin, extra = {}) => Buffer.from(JSON.stringify({ type, challenge: options.challenge, origin, crossOrigin: false, ...extra }));

export function authenticator() {
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const jwk = publicKey.export({ format: 'jwk' });
  const credential = randomBytes(32), id = credential.toString('base64url');
  const cose = encode(new Map([[1, 2], [3, -7], [-1, 1], [-2, new Uint8Array(Buffer.from(jwk.x, 'base64url'))], [-3, new Uint8Array(Buffer.from(jwk.y, 'base64url'))]]));
  let handle;
  return {
    id,
    register(options, { origin = 'https://app.example.com', rpId = options.rp.id, flags = 0x5d, extra = {} } = {}) {
      handle = options.user.id;
      const len = Buffer.alloc(2); len.writeUInt16BE(credential.length);
      const authData = Buffer.concat([hash(rpId), Buffer.from([flags]), counterBytes(0), Buffer.alloc(16), len, credential, cose]);
      return { id, rawId: id, type: 'public-key', response: {
        clientDataJSON: clientData('webauthn.create', options, origin, extra).toString('base64url'),
        attestationObject: encode(new Map([['fmt', 'none'], ['attStmt', new Map()], ['authData', new Uint8Array(authData)]])).toString('base64url'), transports: ['internal'],
      }, clientExtensionResults: {} };
    },
    authenticate(options, { origin = 'https://app.example.com', rpId = options.rpId, flags = 0x1d, counter = 1, userHandle = handle, extra = {} } = {}) {
      const data = clientData('webauthn.get', options, origin, extra);
      const authData = Buffer.concat([hash(rpId), Buffer.from([flags]), counterBytes(counter)]);
      return { id, rawId: id, type: 'public-key', response: { clientDataJSON: data.toString('base64url'), authenticatorData: authData.toString('base64url'), signature: sign('sha256', Buffer.concat([authData, hash(data)]), privateKey).toString('base64url'), userHandle }, clientExtensionResults: {} };
    },
  };
}
