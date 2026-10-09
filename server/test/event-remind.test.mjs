import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { deliverPush } from '../src/push.mjs';

const now = new Date('2026-09-12T12:00:00Z');
function setup(t, pushEnabled = true) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.com', pushEnabled, clock: () => now });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.com', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `test-${++sequence}`);
  const person = (uid, name, roleIds = []) => {
    const id = action({ action: 'member.save', name, roleIds }).id;
    app.session({ uid, name, email: `${uid}@example.com`, email_verified: true });
    action({ action: 'account.approve', uid, personId: id, version: 1, role: 'member' });
    store.put('devices', uid, { id: uid, uid, token: `token-${uid}`, platform: 'web' });
    return id;
  };
  const people = { sam: person('sam', 'Sam'), tech: person('tech', 'Toni', ['role-3']), kim: person('kim', 'Kim', ['role-3']), lou: person('lou', 'Lou') };
  store.put('events', 'probe', { id: 'probe', title: 'Szenenprobe', startsAt: '2026-09-14T17:00:00Z', endsAt: '2026-09-14T19:00:00Z', roleIds: ['role-3'], personIds: [people.sam], productionIds: [], version: 1 });
  return { store, app, action, ...people };
}

test('reminding open invitations reaches only invited people without an answer', async t => {
  const { store, app, action, sam, tech, kim } = setup(t);
  action({ action: 'attendance', eventId: 'probe', status: 'yes' }, 'kim');
  const result = action({ action: 'event.remindOpen', eventId: 'probe' });
  assert.equal(result.recipients, 2);
  const job = store.all('pushJobs').find(j => j.remindOpen);
  assert.deepEqual(job.recipientPersonIds.sort(), [sam, tech].sort());
  assert.equal(job.data.eventId, 'probe');
  assert.ok(!job.recipientPersonIds.includes(kim));
  // Sam answers before delivery and is skipped; Toni still gets the nudge.
  action({ action: 'attendance', eventId: 'probe', status: 'no', reason: 'Krank' }, 'sam');
  const sent = [];
  await deliverPush(app, { sendEachForMulticast: async p => { sent.push(p); return { responses: p.tokens.map(() => ({ success: true })) }; } });
  assert.deepEqual(sent.flatMap(p => p.tokens), ['token-tech']);
  assert.equal(sent[0].notification.title, 'Rückmeldung fehlt: Szenenprobe');
});

test('open reminders need an admin, push, open people and an answerable event', t => {
  const { store, action } = setup(t);
  assert.throws(() => action({ action: 'event.remindOpen', eventId: 'probe' }, 'sam'), { status: 403 });
  assert.throws(() => action({ action: 'event.remindOpen', eventId: 'missing' }), { status: 404 });
  for (const uid of ['sam', 'tech', 'kim']) action({ action: 'attendance', eventId: 'probe', status: 'late' }, uid);
  assert.throws(() => action({ action: 'event.remindOpen', eventId: 'probe' }), { status: 409 });
  store.put('events', 'past', { id: 'past', title: 'Alt', startsAt: '2026-09-10T17:00:00Z', endsAt: '2026-09-10T19:00:00Z', version: 1 });
  assert.throws(() => action({ action: 'event.remindOpen', eventId: 'past' }), { status: 409 });
  assert.equal(store.all('pushJobs').some(j => j.remindOpen), false);
});

test('open reminders fail clearly without push', t => {
  const { action } = setup(t, false);
  assert.throws(() => action({ action: 'event.remindOpen', eventId: 'probe' }), { status: 409 });
});
