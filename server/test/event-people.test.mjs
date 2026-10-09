import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { scheduleReminders } from '../src/push.mjs';

const now = new Date('2026-09-12T12:00:00Z');
function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.com', pushEnabled: true, clock: () => now });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.com', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `test-${++sequence}`);
  const person = (uid, name, roleIds = []) => {
    const id = action({ action: 'member.save', name, roleIds }).id;
    app.session({ uid, name, email: `${uid}@example.com`, email_verified: true });
    action({ action: 'account.approve', uid, personId: id, version: 1, role: 'member' });
    return id;
  };
  return { store, app, action, sam: person('sam', 'Sam'), tech: person('tech', 'Toni', ['role-3']), kim: person('kim', 'Kim') };
}
const event = (extra = {}) => ({ action: 'event.save', title: 'Lichtprobe', startsAt: '2026-09-13T09:00:00Z', endsAt: '2026-09-13T11:00:00Z', ...extra });

test('events invite roles and single people together', t => {
  const { app, store, action, sam, tech } = setup(t);
  const id = action(event({ roleIds: ['role-3'], personIds: [sam, sam], startsAt: '2026-09-12T13:30:00Z', endsAt: '2026-09-12T15:30:00Z' })).id;
  assert.deepEqual(store.get('events', id).personIds, [sam]);
  const sees = uid => app.snapshot(uid).events.some(e => e.id === id);
  assert.equal(sees('sam'), true, 'invited by name');
  assert.equal(sees('tech'), true, 'invited by role');
  assert.equal(sees('kim'), false, 'neither role nor name');
  assert.throws(() => action({ action: 'attendance', eventId: id, status: 'yes' }, 'kim'), { status: 404 });
  action({ action: 'attendance', eventId: id, status: 'yes' }, 'sam');
  scheduleReminders(app, now);
  assert.deepEqual(store.all('pushJobs').filter(j => j.data?.eventId === id).map(j => j.recipientPersonIds[0]).sort(), [sam, tech].sort());
});

test('people alone narrow an event and unknown people are rejected', t => {
  const { app, store, action, sam, kim } = setup(t);
  assert.throws(() => action(event({ personIds: [999] })), { status: 400 });
  const id = action(event({ personIds: [kim] })).id;
  assert.equal(app.snapshot('kim').events.some(e => e.id === id), true);
  assert.equal(app.snapshot('sam').events.some(e => e.id === id), false);
  // Editing without personIds keeps the invitation; an empty list opens it to everyone.
  action(event({ id, version: 1, title: 'Lichtprobe neu' }));
  assert.deepEqual(store.get('events', id).personIds, [kim]);
  action(event({ id, version: 2, personIds: [] }));
  assert.equal(app.snapshot('sam').events.some(e => e.id === id), true);
});

test('absences decline only events the person is invited to', t => {
  const { store, action, sam, kim } = setup(t);
  action({ action: 'absence.create', from: '2026-09-13', to: '2026-09-13', reason: '' }, 'sam');
  const id = action(event({ personIds: [sam, kim] })).id;
  assert.equal(store.get('responses', `${id}:${sam}`)?.status, 'no');
  assert.equal(store.get('responses', `${id}:${kim}`), null);
});
