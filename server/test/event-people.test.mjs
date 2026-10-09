import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { deliverPush, scheduleReminders } from '../src/push.mjs';

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

test('messages, polls and notes reach roles and single people together', t => {
  const { app, store, action, sam } = setup(t);
  action({ action: 'message.send', title: 'Kabel', body: 'Bitte mitbringen', audience: 'selected', roleIds: ['role-3'], recipientPersonIds: [sam], push: true });
  const reads = uid => app.snapshot(uid).messages.some(m => m.title === 'Kabel');
  assert.deepEqual(['sam', 'tech', 'kim'].map(reads), [true, true, false]);
  assert.equal(store.all('pushJobs').find(j => j.data?.messageId).recipientPersonIds.length, 2);
  assert.throws(() => action({ action: 'message.send', title: 'Leer', body: 'Niemand', audience: 'selected', roleIds: [], recipientPersonIds: [] }), { status: 400 });

  action({ action: 'poll.save', title: 'Pizza?', options: [{ label: 'Ja' }, { label: 'Nein' }], roleIds: ['role-3'], personIds: [sam] });
  assert.deepEqual(['sam', 'tech', 'kim'].map(uid => app.snapshot(uid).polls.length), [1, 1, 0]);

  action({ action: 'note.save', title: 'Lichtplan', body: 'Seite 3', roleIds: ['role-3'], personIds: [sam], published: true });
  assert.deepEqual(['sam', 'tech', 'kim'].map(uid => app.snapshot(uid).notes.length), [1, 1, 0]);
  assert.throws(() => action({ action: 'note.save', title: 'X', personIds: [999] }), { status: 400 });
});

test('saving an event can push the invited people once', async t => {
  const { store, action, sam } = setup(t);
  for (const uid of ['admin', 'sam', 'tech', 'kim']) store.put('devices', uid, { id: uid, uid, token: `token-${uid}`, platform: 'web' });
  for (const j of store.all('pushJobs')) store.delete('pushJobs', j.id); // registration notices from setup
  const eventJobs = id => store.all('pushJobs').filter(j => j.data?.eventId === id);
  const deliver = async () => {
    const calls = [];
    await deliverPush({ pushEnabled: true, store }, { sendEachForMulticast: async p => { calls.push(p); return { responses: p.tokens.map(() => ({ success: true })) }; } });
    return calls;
  };

  const silent = action(event());
  assert.equal(silent.pushQueued, false);
  assert.equal(eventJobs(silent.id).length, 0, 'no push without the switch');

  const created = action(event({ roleIds: ['role-3'], personIds: [sam], push: true }));
  assert.equal(created.pushQueued, true);
  const [job] = eventJobs(created.id);
  assert.equal(eventJobs(created.id).length, 1);
  assert.deepEqual([job.title, job.roleIds, job.personIds, job.data], ['Neuer Termin: Lichtprobe', ['role-3'], [sam], { eventId: created.id }]);
  let calls = await deliver();
  assert.deepEqual(calls.flatMap(p => p.tokens).sort(), ['token-sam', 'token-tech']);
  assert.equal(calls[0].notification.title, 'Neuer Termin: Lichtprobe');
  assert.equal(calls[0].data.eventId, created.id);

  // Sam opted out of automatic change notifications; the explicit push still reaches the invitation.
  action({ action: 'settings.reminders', value: { changes: false } }, 'sam');
  for (const j of store.all('pushJobs')) store.delete('pushJobs', j.id);
  action(event({ id: created.id, version: 1, title: 'Lichtprobe neu', push: true }));
  assert.equal(eventJobs(created.id).length, 1, 'explicit push replaces the automatic change notification');
  assert.equal(eventJobs(created.id)[0].title, 'Termin geändert: Lichtprobe neu');
  calls = await deliver();
  assert.deepEqual(calls.flatMap(p => p.tokens).sort(), ['token-sam', 'token-tech']);
  assert.equal(calls[0].notification.title, 'Termin geändert: Lichtprobe neu');

  // Without the switch an edit keeps the automatic change notification.
  action(event({ id: created.id, version: 2, title: 'Lichtprobe alt' }));
  assert.deepEqual(eventJobs(created.id).filter(j => j.status === 'pending').map(j => [j.title, j.change, j.announce]), [['Termin aktualisiert: Lichtprobe alt', true, undefined]]);
});

test('a production ensemble is an audience that follows casting and crew', t => {
  const { app, store, action, sam, tech, kim } = setup(t);
  store.put('productions', 'winter', { id: 'winter', title: 'Winterstück', roles: [{ id: 'A' }, { id: 'B' }], casting: { A: sam }, directorMemberIds: [], version: 1 });
  const id = action(event({ productionIds: ['winter'], startsAt: '2026-09-12T13:30:00Z', endsAt: '2026-09-12T15:30:00Z' })).id;
  const sees = uid => app.snapshot(uid).events.some(e => e.id === id);
  assert.deepEqual(['sam', 'tech', 'kim'].map(sees), [true, false, false]);
  assert.deepEqual(app.snapshot('admin').productions.find(p => p.id === 'winter').ensemble, [sam]);
  assert.throws(() => action(event({ productionIds: ['unknown'] })), { status: 400 });

  // Crew joins by hand, casting changes apply immediately.
  action({ action: 'production.save', id: 'winter', version: 1, title: 'Winterstück', casting: { B: kim }, memberIds: [tech] });
  assert.deepEqual(['sam', 'tech', 'kim'].map(sees), [false, true, true]);
  scheduleReminders(app, now);
  assert.deepEqual(store.all('pushJobs').filter(j => j.data?.eventId === id).map(j => j.recipientPersonIds[0]).sort(), [tech, kim].sort());

  action({ action: 'message.send', title: 'Winter', body: 'Textprobe', audience: 'selected', productionIds: ['winter'] });
  assert.deepEqual(['sam', 'tech', 'kim'].map(uid => app.snapshot(uid).messages.some(m => m.title === 'Winter')), [false, true, true]);
  action({ action: 'poll.save', title: 'Kostüme?', options: [{ label: 'Ja' }, { label: 'Nein' }], productionIds: ['winter'] });
  assert.deepEqual(['sam', 'tech', 'kim'].map(uid => app.snapshot(uid).polls.length), [0, 1, 1]);
});
