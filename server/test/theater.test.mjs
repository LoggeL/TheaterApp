import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.com', clock: () => new Date('2026-09-12T12:00:00Z') });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.com', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin', key = `test-${++sequence}`) => app.action(uid, body, key);
  const memberId = action({ action: 'member.save', name: 'Sam', group: 'Ensemble' }).id;
  app.session({ uid: 'sam', name: 'Sam', email: 'sam@example.com', email_verified: true });
  const approve = () => action({ action: 'account.approve', uid: 'sam', personId: memberId, version: 1, role: 'member' });
  const event = () => action({ action: 'event.save', title: 'Szenenprobe', startsAt: '2026-09-17T17:00:00Z', endsAt: '2026-09-17T19:00:00Z', place: 'Kolpingheim' }).id;
  return { store, app, action, memberId, approve, event };
}

test('pending accounts cannot read data or approve themselves', t => {
  const { app, action, memberId } = setup(t);
  assert.throws(() => app.snapshot('sam'), { status: 403 });
  assert.throws(() => action({ action: 'account.approve', uid: 'sam', personId: memberId, version: 1, role: 'admin' }, 'sam'), { status: 403 });
});
test('unverified email cannot bootstrap admin or receive approval', t => {
  const { app, action, memberId, store } = setup(t);
  app.session({ uid: 'unverified', email: 'admin@example.com', email_verified: false });
  assert.equal(store.account('unverified').status, 'pending');
  assert.throws(() => action({ action: 'account.approve', uid: 'unverified', personId: memberId, version: 1, role: 'member' }), { status: 409 });
});
test('approval preserves person identity and prevents duplicate linking', t => {
  const { app, action, approve, memberId, store } = setup(t); approve();
  assert.equal(app.snapshot('sam').user.personId, memberId);
  app.session({ uid: 'duplicate', email: 'different@example.com', email_verified: true });
  assert.throws(() => action({ action: 'account.approve', uid: 'duplicate', personId: memberId, version: 1, role: 'member' }), { status: 409 });
  assert.equal(store.account('duplicate').status, 'pending');
  assert.equal(store.account('duplicate').personId, null);
  assert.throws(approve, { status: 409 });
});
test('suspended accounts stay suspended when logging in again', t => {
  const { app, action, approve } = setup(t); approve();
  action({ action: 'account.status', uid: 'sam', status: 'suspended', version: 2 });
  assert.throws(() => app.snapshot('sam'), { status: 403 });
  assert.equal(app.session({ uid: 'sam', email: 'sam@example.com', email_verified: true }).status, 'suspended');
});
test('late arrival is persisted and cleared when changing response', t => {
  const { app, action, approve, event } = setup(t); approve(); const eventId = event();
  action({ action: 'attendance', eventId, status: 'late', expectedArrivalAt: '2026-09-17T17:30:00Z' }, 'sam');
  let snapshot = app.snapshot('sam');
  assert.equal(snapshot.attendanceByEvent[eventId], 'late');
  assert.equal(snapshot.expectedArrivals[eventId], '2026-09-17T17:30:00.000Z');
  assert.deepEqual(app.snapshot('admin').checkinsByEvent, {});
  action({ action: 'attendance', eventId, status: 'yes', expectedArrivalAt: '2026-09-17T17:30:00Z' }, 'sam');
  snapshot = app.snapshot('sam'); assert.equal(snapshot.expectedArrivals[eventId], null);
});
test('late arrival validates both schedule bounds, including unknown time', t => {
  const { app, action, approve, event } = setup(t); approve(); const eventId = event();
  for (const time of ['2026-09-17T16:30:00Z', '2026-09-17T19:30:00Z', 'invalid']) assert.throws(() => action({ action: 'attendance', eventId, status: 'late', expectedArrivalAt: time }, 'sam'), { status: 400 });
  action({ action: 'attendance', eventId, status: 'late' }, 'sam');
  assert.equal(app.snapshot('sam').expectedArrivals[eventId], null);
});
test('idempotent retries do not create duplicate messages and keys cannot change payload', t => {
  const { store, action } = setup(t);
  const body = { action: 'message.send', title: 'Probe', body: 'Bitte Text mitbringen.', audience: 'all' };
  const one = action(body, 'admin', 'same-key'), two = action(body, 'admin', 'same-key');
  assert.deepEqual(one, two); assert.equal(store.all('messages').length, 1);
  assert.throws(() => action({ ...body, title: 'Changed' }, 'admin', 'same-key'), { status: 409 });
});
test('check-in edits are per person, preserve unknown state and reject stale batches atomically', t => {
  const { app, store, action, event, memberId } = setup(t); const eventId = event();
  action({ action: 'checkin.save', eventId, members: [{ id: memberId, present: null, version: 0 }] });
  assert.equal(app.snapshot('admin').checkinsByEvent[eventId][memberId], null);
  assert.throws(() => action({ action: 'checkin.save', eventId, members: [{ id: 1, present: true, version: 0 }, { id: memberId, present: false, version: 0 }] }), { status: 409 });
  assert.equal(store.get('checkins', `${eventId}:1`), null);
  action({ action: 'checkin.save', eventId, members: [{ id: memberId, present: true, version: 1 }] });
  assert.equal(app.snapshot('admin').checkinsByEvent[eventId][memberId], true);
});
test('member cannot send notices or edit schedules and sees only addressed notices', t => {
  const { app, action, approve } = setup(t); approve();
  assert.throws(() => action({ action: 'message.send', title: 'X', body: 'X' }, 'sam'), { status: 403 });
  action({ action: 'message.send', title: 'Privat', body: 'Nur Leitung', audience: 'selected', recipientPersonIds: [1] });
  assert.equal(app.snapshot('sam').messages.length, 0);
  assert.equal(app.snapshot('admin').messages.length, 1);
});
test('changing a schedule clears invalid expected arrivals', t => {
  const { app, action, event, approve } = setup(t); approve(); const eventId = event();
  action({ action: 'attendance', eventId, status: 'late', expectedArrivalAt: '2026-09-17T17:30:00Z' }, 'sam');
  action({ action: 'event.save', id: eventId, version: 1, title: 'Spätere Probe', startsAt: '2026-09-17T18:00:00Z', endsAt: '2026-09-17T20:00:00Z' });
  assert.equal(app.snapshot('sam').attendanceByEvent[eventId], 'late');
  assert.equal(app.snapshot('sam').expectedArrivals[eventId], null);
});
test('HTTP rejects missing and invalid tokens; pending user can only read their own access state', async t => {
  const { app } = setup(t);
  const server = createHttpServer({ theater: app, verifyToken: async token => { if (token !== 'sam-token') throw Error('invalid'); return { uid: 'sam', email: 'sam@example.com', email_verified: true }; } });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  t.after(() => new Promise(r => server.close(r)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  assert.equal((await fetch(`${base}/snapshot/`)).status, 401);
  assert.equal((await fetch(`${base}/snapshot/`, { headers: { Authorization: 'Bearer wrong' } })).status, 401);
  assert.equal((await fetch(`${base}/snapshot/`, { headers: { Authorization: 'Bearer sam-token' } })).status, 403);
  const status = await fetch(`${base}/auth/session/`, { headers: { Authorization: 'Bearer sam-token' } });
  assert.equal(status.status, 200); assert.equal((await status.json()).user.status, 'pending');
});
