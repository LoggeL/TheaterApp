import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { deliverPush, scheduleReminders } from '../src/push.mjs';
import { pushKind } from '../src/push-kinds.mjs';

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
  action({ action: 'attendance', eventId: id, status: 'late' }, 'tech');
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

test('messages and polls reach roles and single people together', t => {
  const { app, store, action, sam } = setup(t);
  action({ action: 'message.send', title: 'Kabel', body: 'Bitte mitbringen', audience: 'selected', roleIds: ['role-3'], recipientPersonIds: [sam], push: true });
  const reads = uid => app.snapshot(uid).messages.some(m => m.title === 'Kabel');
  assert.deepEqual(['sam', 'tech', 'kim'].map(reads), [true, true, false]);
  assert.equal(store.all('pushJobs').find(j => j.data?.messageId).recipientPersonIds.length, 2);
  assert.throws(() => action({ action: 'message.send', title: 'Leer', body: 'Niemand', audience: 'selected', roleIds: [], recipientPersonIds: [] }), { status: 400 });

  action({ action: 'poll.save', title: 'Pizza?', options: [{ label: 'Ja' }, { label: 'Nein' }], roleIds: ['role-3'], personIds: [sam] });
  assert.deepEqual(['sam', 'tech', 'kim'].map(uid => app.snapshot(uid).polls.length), [1, 1, 0]);
  assert.throws(() => action({ action: 'poll.save', title: 'X', options: [{ label: 'Ja' }, { label: 'Nein' }], personIds: [999] }), { status: 400 });
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

  // Typo fixes stay quiet even with the switch on; the server says why.
  action({ action: 'attendance', eventId: created.id, status: 'yes' }, 'sam');
  for (const j of store.all('pushJobs')) store.delete('pushJobs', j.id);
  const typo = action(event({ id: created.id, version: 1, title: 'Lichtprobe neu', description: 'Mit Nebel', locked: true, push: true }));
  assert.deepEqual([typo.pushQueued, typo.pushSkipped, eventJobs(created.id).length], [false, 'unchanged', 0]);

  // A new place is pushed, but only to people who plan to attend: Sam accepted, Toni never answered.
  const moved = action(event({ id: created.id, version: 2, title: 'Lichtprobe neu', place: 'Saal', push: true }));
  assert.deepEqual([moved.pushQueued, moved.pushSkipped], [true, null]);
  assert.deepEqual(eventJobs(created.id).map(j => [j.title, j.change, j.announce, pushKind(j)]), [['Termin geändert: Lichtprobe neu', true, 'changed', 'changes']]);
  calls = await deliver();
  assert.deepEqual(calls.flatMap(p => p.tokens), ['token-sam']);
  assert.equal(calls[0].notification.title, 'Termin geändert: Lichtprobe neu');

  // With the switch off nothing is pushed, not even a new time.
  action({ action: 'attendance', eventId: created.id, status: 'yes' }, 'tech');
  for (const j of store.all('pushJobs')) store.delete('pushJobs', j.id);
  const quiet = action(event({ id: created.id, version: 3, title: 'Lichtprobe neu', place: 'Saal', startsAt: '2026-09-13T10:00:00Z', endsAt: '2026-09-13T12:00:00Z' }));
  assert.deepEqual([quiet.pushQueued, quiet.pushSkipped, eventJobs(created.id).length], [false, null, 0]);

  // A person who switched off "Bei Änderungen" does not get the change pushed.
  action({ action: 'settings.reminders', value: { changes: false } }, 'sam');
  action(event({ id: created.id, version: 4, title: 'Lichtprobe neu', place: 'Saal', startsAt: '2026-09-13T11:00:00Z', endsAt: '2026-09-13T13:00:00Z', push: true }));
  calls = await deliver();
  assert.deepEqual(calls.flatMap(p => p.tokens), ['token-tech'], 'Sam opted out, Toni answered meanwhile');
});

test('a production ensemble is an audience that follows casting and crew', t => {
  const { app, store, action, sam, tech, kim } = setup(t);
  store.put('productions', 'winter', { id: 'winter', title: 'Winterstück', roles: [{ id: 'A' }, { id: 'B' }], casting: { A: sam }, directorMemberIds: [], version: 1 });
  const id = action(event({ productionIds: ['winter'], startsAt: '2026-09-12T13:30:00Z', endsAt: '2026-09-12T15:30:00Z' })).id;
  const sees = uid => app.snapshot(uid).events.some(e => e.id === id);
  assert.deepEqual(['sam', 'tech', 'kim'].map(sees), [true, false, false]);
  assert.deepEqual(app.snapshot('admin').productions.find(p => p.id === 'winter').ensemble, [sam]);
  assert.throws(() => action(event({ productionIds: ['unknown'] })), { status: 400 });
  action({ action: 'attendance', eventId: id, status: 'yes' }, 'sam');

  // Crew joins by hand, casting changes apply immediately.
  action({ action: 'production.save', id: 'winter', version: 1, title: 'Winterstück', casting: { B: kim }, memberIds: [tech] });
  assert.deepEqual(['sam', 'tech', 'kim'].map(sees), [false, true, true]);
  action({ action: 'attendance', eventId: id, status: 'yes' }, 'tech');
  action({ action: 'attendance', eventId: id, status: 'late' }, 'kim');
  scheduleReminders(app, now);
  assert.deepEqual(store.all('pushJobs').filter(j => j.data?.eventId === id).map(j => j.recipientPersonIds[0]).sort(), [tech, kim].sort());

  action({ action: 'message.send', title: 'Winter', body: 'Textprobe', audience: 'selected', productionIds: ['winter'] });
  assert.deepEqual(['sam', 'tech', 'kim'].map(uid => app.snapshot(uid).messages.some(m => m.title === 'Winter')), [false, true, true]);
  action({ action: 'poll.save', title: 'Kostüme?', options: [{ label: 'Ja' }, { label: 'Nein' }], productionIds: ['winter'] });
  assert.deepEqual(['sam', 'tech', 'kim'].map(uid => app.snapshot(uid).polls.length), [0, 1, 1]);
});

test('changes to events more than two weeks ahead are not pushed', async t => {
  const { store, action, sam } = setup(t);
  for (const uid of ['sam']) store.put('devices', uid, { id: uid, uid, token: `token-${uid}`, platform: 'web' });
  const deliver = async () => {
    const calls = [];
    await deliverPush({ pushEnabled: true, store }, { sendEachForMulticast: async p => { calls.push(p); return { responses: p.tokens.map(() => ({ success: true })) }; } });
    return calls.flatMap(p => p.tokens);
  };
  const far = { startsAt: '2026-10-20T17:00:00Z', endsAt: '2026-10-20T19:00:00Z' };
  const id = action(event({ ...far, personIds: [sam] })).id;
  action({ action: 'attendance', eventId: id, status: 'yes' }, 'sam');
  for (const j of store.all('pushJobs')) store.delete('pushJobs', j.id);

  assert.equal(action(event({ id, version: 1, ...far, personIds: [sam], title: 'Später', push: true })).pushQueued, false);
  assert.deepEqual(await deliver(), [], 'far away: neither the explicit nor the automatic change is pushed');
  action(event({ id, version: 2, ...far, personIds: [sam], title: 'Noch später' }));
  assert.deepEqual(await deliver(), []);

  // Moving it into the next two weeks is pushed, and so is moving a near event far away.
  action(event({ id, version: 3, personIds: [sam], title: 'Vorgezogen', push: true }));
  assert.deepEqual(await deliver(), ['token-sam']);
  action(event({ id, version: 4, ...far, personIds: [sam], title: 'Wieder verschoben', push: true }));
  assert.deepEqual(await deliver(), ['token-sam']);
});

test('a deleted event is pushed as cancelled to everyone invited who has not declined', async t => {
  const { store, action, sam, tech, kim } = setup(t);
  for (const uid of ['admin', 'sam', 'tech', 'kim']) store.put('devices', uid, { id: uid, uid, token: `token-${uid}`, platform: 'web' });
  const deliver = async () => {
    const calls = [];
    await deliverPush({ pushEnabled: true, store }, { sendEachForMulticast: async p => { calls.push(p); return { responses: p.tokens.map(() => ({ success: true })) }; } });
    return calls;
  };
  const adminId = store.account('admin').personId;
  const id = action(event({ place: 'Saal', personIds: [sam, tech, kim, adminId] })).id;
  action({ action: 'attendance', eventId: id, status: 'no', reason: 'Krank' }, 'kim');
  for (const j of store.all('pushJobs')) store.delete('pushJobs', j.id);
  action({ action: 'event.delete', id, version: 1 });
  const [job] = store.all('pushJobs');
  assert.equal(store.all('pushJobs').length, 1);
  // Open invitations count, too; the deleting admin and Kim, who declined, are left out.
  assert.deepEqual([job.title, job.body, job.data, pushKind(job), job.recipientPersonIds.sort()], ['Termin abgesagt: Lichtprobe', 'So., 13.09.2026, 11:00 Uhr · Saal', {}, 'changes', [sam, tech].sort()]);
  // "Bei Änderungen" also switches off cancellations.
  action({ action: 'settings.reminders', value: { changes: false } }, 'tech');
  const calls = await deliver();
  assert.deepEqual(calls.flatMap(p => p.tokens), ['token-sam']);
  assert.deepEqual([calls[0].notification.title, calls[0].webpush], ['Termin abgesagt: Lichtprobe', undefined]);

  // Past events are not pushed when deleted.
  for (const j of store.all('pushJobs')) store.delete('pushJobs', j.id);
  const past = action(event({ startsAt: '2026-09-11T09:00:00Z', endsAt: '2026-09-11T11:00:00Z' })).id;
  action({ action: 'event.delete', id: past, version: 1 });
  assert.equal(store.all('pushJobs').length, 0);
});

test('absences report the declined events by Berlin date and can reopen them', t => {
  const { app, store, action, sam } = setup(t);
  // 23:30 UTC on the 14th is already the 15th in Berlin.
  const night = action(event({ title: 'Nachtprobe', startsAt: '2026-09-14T23:30:00Z', endsAt: '2026-09-15T01:00:00Z' })).id;
  const day14 = action(event({ title: 'Tagprobe', startsAt: '2026-09-14T10:00:00Z', endsAt: '2026-09-14T12:00:00Z' })).id;
  const own = action(event({ title: 'Eigene Absage', startsAt: '2026-09-15T10:00:00Z', endsAt: '2026-09-15T12:00:00Z' })).id;
  const changed = action(event({ title: 'Doch dabei', startsAt: '2026-09-15T14:00:00Z', endsAt: '2026-09-15T16:00:00Z' })).id;
  const again = action(event({ title: 'Neu begründet', startsAt: '2026-09-15T17:00:00Z', endsAt: '2026-09-15T19:00:00Z' })).id;
  const soon = action(event({ title: 'Gleich', startsAt: '2026-09-14T22:30:00Z', endsAt: '2026-09-14T23:00:00Z' })).id;
  const tech = action(event({ title: 'Lichtprobe', startsAt: '2026-09-15T08:00:00Z', endsAt: '2026-09-15T09:00:00Z', roleIds: ['role-3'] })).id;
  action({ action: 'attendance', eventId: own, status: 'no', reason: 'Arzttermin' }, 'sam');

  const result = action({ action: 'absence.create', from: '2026-09-15', to: '2026-09-15', reason: 'Urlaub' }, 'sam');
  assert.deepEqual(result.declinedEventIds.sort(), [night, changed, again, soon].sort());
  assert.ok(!result.declinedEventIds.includes(day14) && !result.declinedEventIds.includes(tech));
  assert.equal(store.get('responses', `${night}:${sam}`).absenceId, result.id);
  assert.deepEqual([store.get('responses', `${own}:${sam}`).reason, store.get('responses', `${own}:${sam}`).absenceId], ['Arzttermin', undefined], 'an own decline stays untouched');

  action({ action: 'attendance', eventId: changed, status: 'yes' }, 'sam');
  action({ action: 'attendance', eventId: again, status: 'no', reason: 'Familienfeier' }, 'sam');
  app.clock = () => new Date('2026-09-14T22:00:00Z'); // `soon` is now inside the decline cutoff, `night` not yet
  assert.deepEqual(action({ action: 'absence.delete', id: result.id, reopen: true }, 'sam').reopenedEventIds, [night]);
  assert.equal(store.get('responses', `${night}:${sam}`), null);
  assert.deepEqual([own, changed, again, soon].map(id => store.get('responses', `${id}:${sam}`).status), ['no', 'yes', 'no', 'no']);
  assert.equal(store.get('absences', result.id), null);
});

test('deleting an absence without reopen keeps its declines; new events get tagged declines', t => {
  const { store, action, sam } = setup(t);
  const { id } = action({ action: 'absence.create', from: '2026-09-13', to: '2026-09-13' }, 'sam');
  const eventId = action(event()).id;
  assert.equal(store.get('responses', `${eventId}:${sam}`).absenceId, id);
  assert.deepEqual(action({ action: 'absence.delete', id }, 'sam'), { ok: true });
  assert.equal(store.get('responses', `${eventId}:${sam}`).status, 'no');
});

test('reopening keeps a decline that another absence still covers', t => {
  const { store, action, sam } = setup(t);
  const eventId = action(event({ startsAt: '2026-09-16T10:00:00Z', endsAt: '2026-09-16T12:00:00Z' })).id;
  const first = action({ action: 'absence.create', from: '2026-09-15', to: '2026-09-16', reason: 'Urlaub' }, 'sam');
  const second = action({ action: 'absence.create', from: '2026-09-16', to: '2026-09-17', reason: 'Dienstreise' }, 'sam');
  assert.deepEqual([first.declinedEventIds, second.declinedEventIds], [[eventId], []]);
  assert.deepEqual(action({ action: 'absence.delete', id: first.id, reopen: true }, 'sam').reopenedEventIds, []);
  assert.deepEqual([store.get('responses', `${eventId}:${sam}`).status, store.get('responses', `${eventId}:${sam}`).absenceId, store.get('responses', `${eventId}:${sam}`).reason], ['no', second.id, 'Dienstreise']);
  assert.deepEqual(action({ action: 'absence.delete', id: second.id, reopen: true }, 'sam').reopenedEventIds, [eventId]);
  assert.equal(store.get('responses', `${eventId}:${sam}`), null);
});
