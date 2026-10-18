import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { deliverPush } from '../src/push.mjs';

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { pushEnabled: true, bootstrapEmail: 'admin@example.invalid' });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let sequence = 0;
  const action = body => app.action('admin', body, `pending-push-${++sequence}`);
  const personId = action({ action: 'member.save', name: 'Sam im Ensemble' }).id;
  const identity = { uid: 'sam', name: 'Sam', email: 'sam@example.invalid', email_verified: true, firebase: { sign_in_provider: 'google.com' } };
  app.session(identity, 'Sam Beispiel');
  const approve = () => action({ action: 'account.approve', uid: identity.uid, version: store.account(identity.uid).version, personId, role: 'member' });
  return { app, store, identity, approve };
}

const sender = () => {
  const calls = [];
  return { calls, messaging: { sendEachForMulticast: async payload => { calls.push(payload); return { responses: payload.tokens.map(() => ({ success: true })) }; } } };
};

test('a waiting account registers a device and receives its approval push', async t => {
  const { app, store, approve } = setup(t);
  app.device('sam', 'sam-device-token-while-waiting', 'android');
  assert.equal(store.all('devices').filter(d => d.uid === 'sam').length, 1);
  app.enqueuePush({ title: 'Probe', body: 'Heute' });
  const { calls, messaging } = sender();
  await deliverPush(app, messaging);
  assert.ok(calls.every(c => !c.tokens.includes('sam-device-token-while-waiting')), 'nothing reaches a waiting account');
  approve();
  await deliverPush(app, messaging);
  const welcome = calls.find(c => c.tokens.includes('sam-device-token-while-waiting'));
  assert.equal(welcome?.notification.title, 'Zugang freigegeben');
  app.device('sam', 'sam-device-token-while-waiting', 'android', true);
  assert.equal(store.all('devices').filter(d => d.uid === 'sam').length, 0);
});

test('rejected and suspended accounts cannot register devices', t => {
  const { app, store } = setup(t);
  app.action('admin', { action: 'account.status', uid: 'sam', status: 'rejected', version: store.account('sam').version }, 'reject');
  assert.throws(() => app.device('sam', 'sam-device-token-after-reject', 'web'), { status: 403 });
  assert.throws(() => app.device('unknown', 'unknown-device-token-value', 'web'), { status: 403 });
});

test('waiting accounts reach the device route but not the snapshot', async t => {
  const { app, identity } = setup(t);
  const server = createHttpServer({ theater: app, verifyToken: async () => identity });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  const request = (path, method, body) => fetch(`${base}${path}`, { method, headers: { Authorization: 'Bearer sam-token', 'Content-Type': 'application/json' }, body: body && JSON.stringify(body) });
  const registered = await request('/devices', 'POST', { token: 'sam-web-device-token-value', platform: 'web' });
  assert.equal(registered.status, 200);
  assert.deepEqual(await registered.json(), { ok: true, pushEnabled: true });
  assert.equal((await request('/snapshot', 'GET')).status, 403);
});
