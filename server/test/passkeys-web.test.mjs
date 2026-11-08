import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { runInNewContext } from 'node:vm';

// Uses the shipped bridge, not a second implementation of its binary conversion.
test('the local passkey bridge loads before Flutter, matches its integrity and preserves WebAuthn bytes', async () => {
  const index = await readFile(new URL('../../web/index.html', import.meta.url), 'utf8');
  const [, path, integrity] = index.match(/src="(vendor\/passkeys-[^"]+\.js)" integrity="([^"]+)"/);
  assert(index.indexOf(path) < index.indexOf('src="flutter_bootstrap.js"'));
  const source = await readFile(new URL('../../web/' + path, import.meta.url), 'utf8');
  assert.equal(integrity, 'sha256-' + createHash('sha256').update(source).digest('base64'));
  const bytes = new Uint8Array([0, 255, 254, 128, 17]);
  const encoded = Buffer.from(bytes).toString('base64url');
  const requests = [];
  const credentials = {
    async create(request) {
      requests.push(request);
      return { type: 'public-key', id: encoded, rawId: bytes.buffer, response: { clientDataJSON: bytes.buffer, attestationObject: bytes.buffer, getTransports: () => ['internal'] }, getClientExtensionResults: () => ({}) };
    },
    async get(request) {
      requests.push(request);
      return { type: 'public-key', id: encoded, rawId: bytes.buffer, response: { clientDataJSON: bytes.buffer, authenticatorData: bytes.buffer, signature: bytes.buffer, userHandle: bytes.buffer }, getClientExtensionResults: () => ({}) };
    },
  };
  const context = { navigator: { credentials }, window: { PublicKeyCredential: {} }, AbortController, DOMException, console, atob, btoa };
  runInNewContext(source, context);
  const bridge = context.PasskeyAuthenticator;
  bridge.init(); assert.equal(bridge.hasPasskeySupport(), true);
  const registered = JSON.parse(await bridge.register(JSON.stringify({ publicKey: { rp: { id: 'localhost', name: 'Theater' }, user: { id: encoded, name: 'test', displayName: 'Test' }, challenge: encoded, pubKeyCredParams: [{ type: 'public-key', alg: -7 }], authenticatorSelection: { residentKey: 'required', userVerification: 'required' } } })));
  assert.equal(registered.response.clientDataJSON, encoded);
  assert.equal(registered.response.attestationObject, encoded);
  assert.equal(requests[0].publicKey.authenticatorSelection.residentKey, 'required');
  assert.equal(Buffer.from(requests[0].publicKey.challenge).toString('base64url'), encoded);
  const signed = JSON.parse(await bridge.login(JSON.stringify({ publicKey: { rpId: 'localhost', challenge: encoded, userVerification: 'required' } })));
  assert.equal(signed.response.userHandle, encoded);
  assert.equal(signed.response.signature, encoded);
  assert.equal(requests[1].publicKey.userVerification, 'required');
  assert.equal(requests[1].publicKey.allowCredentials, undefined);
});
