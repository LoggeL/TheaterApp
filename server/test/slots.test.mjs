import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { deliverPush } from '../src/push.mjs';

const now = new Date('2026-10-01T12:00:00Z');
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
  const people = { sam: person('sam', 'Sam', ['role-1']), kim: person('kim', 'Kim', ['role-1']), toni: person('toni', 'Toni') };
  const slot = (start, capacity = 1, id) => ({ id, startsAt: `2026-10-18T${start}:00Z`, endsAt: `2026-10-18T${start.slice(0, 3)}${String(+start.slice(3) + 15).padStart(2, '0')}:00Z`, capacity });
  const pool = (extra = {}) => action({ action: 'slotPool.save', title: 'Fototermin', place: 'Kolpingheim', roleIds: ['role-1'], slots: [slot('10:00'), slot('10:15', 2)], ...extra }).id;
  const view = (uid, id) => app.snapshot(uid).slotPools.find(p => p.id === id);
  return { store, app, action, ...people, pool, slot, view };
}

test('invited people book one slot each and the booking becomes their event', t => {
  const { store, app, action, sam, kim, pool, view } = setup(t);
  const id = pool();
  assert.equal(store.all('pushJobs').filter(j => j.data?.slotPoolId === id).length, 1, 'invitees are notified once');
  assert.equal(view('toni', id), undefined, 'not invited');
  const [first, second] = view('sam', id).slots;
  action({ action: 'slot.book', poolId: id, slotId: first.id }, 'sam');
  assert.throws(() => action({ action: 'slot.book', poolId: id, slotId: first.id }, 'kim'), { status: 409 });
  assert.throws(() => action({ action: 'slot.book', poolId: id, slotId: first.id }, 'toni'), { status: 404 });
  action({ action: 'slot.book', poolId: id, slotId: second.id }, 'kim');
  const own = view('sam', id);
  assert.equal(own.myBooking, first.id);
  assert.deepEqual(own.slots.map(x => [x.booked, x.people.map(p => p.name)]), [[1, ['Sam']], [1, ['Kim']]]);
  const event = store.get('events', `slot-${id}-${first.id}`);
  assert.deepEqual(event.personIds, [sam]);
  assert.equal(store.get('responses', `${event.id}:${sam}`).status, 'yes');
  assert.equal(app.snapshot('sam').events.some(e => e.id === event.id), true);
  assert.equal(app.snapshot('kim').events.some(e => e.id === event.id), false, 'only the booked people see the slot');
  assert.throws(() => action({ action: 'attendance', eventId: event.id, status: 'no' }, 'sam'), { status: 409 });
  assert.throws(() => action({ action: 'event.delete', id: event.id, version: event.version }), { status: 409 });
  // Rebooking moves the event; cancelling removes it.
  action({ action: 'slot.book', poolId: id, slotId: second.id }, 'sam');
  assert.equal(store.get('events', event.id), null);
  assert.equal(store.get('responses', `${event.id}:${sam}`), null);
  assert.deepEqual(store.get('events', `slot-${id}-${second.id}`).personIds, [sam, kim].sort((x, y) => x - y));
  action({ action: 'slot.cancel', poolId: id }, 'sam');
  assert.deepEqual(store.get('events', `slot-${id}-${second.id}`).personIds, [kim]);
});

test('admins assign people, protect booked slots and close or delete pools', t => {
  const { store, action, toni, pool, slot, view } = setup(t);
  const id = pool({ personIds: [toni] });
  const [first, second] = view('admin', id).slots;
  assert.equal(view('toni', id).myBooking, null, 'invited by name');
  action({ action: 'slot.assign', poolId: id, personId: toni, slotId: first.id });
  assert.equal(view('toni', id).myBooking, first.id);
  let version = view('admin', id).version;
  assert.throws(() => action({ action: 'slotPool.save', id, version, title: 'Fototermin', slots: [slot('10:15', 2, second.id)] }), { status: 409 });
  action({ action: 'slotPool.save', id, version, title: 'Porträts', slots: [slot('10:00', 1, first.id), slot('10:30', 3)] });
  assert.equal(store.get('events', `slot-${id}-${first.id}`).title, 'Porträts');
  assert.equal(store.all('pushJobs').filter(j => j.data?.slotPoolId === id && j.body === 'Bitte wähle dein Zeitfenster.').length, 1, 'edits do not notify again');
  version = view('admin', id).version;
  action({ action: 'slotPool.close', id, version, closed: true });
  assert.throws(() => action({ action: 'slot.cancel', poolId: id }, 'toni'), { status: 409 });
  action({ action: 'slotPool.delete', id, version: version + 1 });
  assert.equal(store.all('slotBookings').length, 0);
  assert.equal(store.all('events').filter(e => e.slotPoolId).length, 0);
});

test('slots that already started cannot be booked or left', t => {
  const { action, pool, view } = setup(t);
  const id = action({ action: 'slotPool.save', title: 'Fotos', slots: [{ startsAt: '2026-10-01T11:00:00Z', endsAt: '2026-10-01T13:00:00Z', capacity: 5 }] }).id;
  assert.throws(() => action({ action: 'slot.book', poolId: id, slotId: view('sam', id).slots[0].id }, 'sam'), { status: 409 });
  assert.throws(() => action({ action: 'slotPool.save', title: 'Leer', slots: [] }), { status: 400 });
  assert.throws(() => action({ action: 'slotPool.save', title: 'Zu viel', slots: [{ startsAt: '2026-10-18T10:00:00Z', endsAt: '2026-10-18T10:15:00Z', capacity: 51 }] }), { status: 400 });
  assert.ok(pool());
});

const notices = (store, id) => store.all('pushJobs').filter(j => j.data?.slotPoolId === id && j.body !== 'Bitte wähle dein Zeitfenster.');

test('admin assignments and releases notify exactly that person', t => {
  const { store, action, sam, toni, pool, view } = setup(t);
  const id = pool({ personIds: [toni] });
  const [first, second] = view('admin', id).slots;
  assert.deepEqual(action({ action: 'slot.assign', poolId: id, personId: toni, slotId: first.id }), { ok: true, pushQueued: true });
  const [job] = notices(store, id);
  assert.deepEqual([job.title, job.body, job.recipientPersonIds, job.data], ['Terminfinder: Fototermin', 'Du bist eingeteilt: So., 18.10.2026, 12:00 Uhr · Kolpingheim', [toni], { slotPoolId: id }]);
  assert.equal(action({ action: 'slot.assign', poolId: id, personId: toni, slotId: first.id }).pushQueued, false, 'unchanged');
  action({ action: 'slot.assign', poolId: id, personId: toni, slotId: second.id });
  action({ action: 'slot.assign', poolId: id, personId: toni, slotId: null });
  assert.deepEqual(notices(store, id).map(j => j.body).sort(), ['Dein Zeitfenster wurde freigegeben.', 'Du bist eingeteilt: So., 18.10.2026, 12:00 Uhr · Kolpingheim', 'Du bist eingeteilt: So., 18.10.2026, 12:15 Uhr · Kolpingheim']);
  assert.ok(notices(store, id).every(j => JSON.stringify(j.recipientPersonIds) === JSON.stringify([toni])));
  assert.equal(notices(store, id).length, 3);
  assert.equal(action({ action: 'slot.assign', poolId: id, personId: toni, slotId: null }).pushQueued, false, 'nothing to release');
  // Own bookings and an admin assigning themselves stay quiet.
  action({ action: 'slot.book', poolId: id, slotId: second.id }, 'sam');
  action({ action: 'slot.assign', poolId: id, personId: store.account('admin').personId, slotId: second.id });
  assert.equal(notices(store, id).length, 3);
  assert.equal(store.all('emailJobs').length, 0);
  assert.ok(sam);
});

test('moving a booked slot notifies its people, deleting the pool notifies future bookings', t => {
  const { store, action, sam, kim, toni, pool, slot, view } = setup(t);
  const id = pool({ personIds: [toni] });
  const [first, second] = view('admin', id).slots;
  action({ action: 'slot.book', poolId: id, slotId: first.id }, 'sam');
  action({ action: 'slot.book', poolId: id, slotId: second.id }, 'kim');
  const version = view('admin', id).version;
  action({ action: 'slotPool.save', id, version, title: 'Fototermin', place: 'Kolpingheim', roleIds: ['role-1'], personIds: [toni], slots: [slot('10:00', 1, first.id), slot('11:00', 2, second.id)] });
  let jobs = notices(store, id);
  assert.equal(jobs.length, 1);
  assert.deepEqual([jobs[0].body, jobs[0].recipientPersonIds], ['Zeitfenster verschoben: So., 18.10.2026, 13:00 Uhr · Kolpingheim', [kim]]);
  assert.equal(store.get('events', `slot-${id}-${second.id}`).startsAt, '2026-10-18T11:00:00.000Z');

  action({ action: 'slotPool.delete', id, version: version + 1 });
  jobs = store.all('pushJobs').filter(j => j.title === 'Terminfinder entfällt: Fototermin');
  assert.deepEqual(jobs.map(j => j.recipientPersonIds).sort((x, y) => x[0] - y[0]), [[sam], [kim]].sort((x, y) => x[0] - y[0]));
  assert.ok(jobs.every(j => JSON.stringify(j.data) === '{}' && /^Dein Zeitfenster entfällt: /.test(j.body)));
  assert.equal(store.all('emailJobs').length, 0);
});

test('open slot reminders reach invitees without a booking and respect bookings, closing and the cooldown', async t => {
  const { store, app, action, sam, kim, pool, view } = setup(t);
  for (const uid of ['sam', 'kim', 'toni']) store.put('devices', uid, { id: uid, uid, token: `token-${uid}`, platform: 'web' });
  const id = pool();
  for (const j of store.all('pushJobs')) store.delete('pushJobs', j.id);
  const [first, second] = view('admin', id).slots;
  action({ action: 'slot.book', poolId: id, slotId: first.id }, 'sam');
  assert.throws(() => action({ action: 'slotPool.remindOpen', id }, 'sam'), { status: 403 });
  const result = action({ action: 'slotPool.remindOpen', id });
  assert.deepEqual([result.queued, result.recipients, result.lastRemindedAt], [true, 1, '2026-10-01T12:00:00.000Z']);
  const [job] = store.all('pushJobs');
  assert.deepEqual([job.recipientPersonIds, job.remindSlot, job.data], [[kim], true, { slotPoolId: id }]);
  assert.ok(!job.recipientPersonIds.includes(sam));
  assert.deepEqual([view('admin', id).lastRemindedAt, view('admin', id).remindCount], ['2026-10-01T12:00:00.000Z', 1]);
  assert.equal('lastRemindedAt' in view('sam', id), false);
  assert.throws(() => action({ action: 'slotPool.remindOpen', id }), { status: 409, code: 'cooldown' });
  // Kim books before delivery and is skipped.
  action({ action: 'slot.book', poolId: id, slotId: second.id }, 'kim');
  const sent = [];
  await deliverPush(app, { sendEachForMulticast: async p => { sent.push(p); return { responses: p.tokens.map(() => ({ success: true })) }; } });
  assert.deepEqual(sent, []);
  app.clock = () => new Date('2026-10-01T13:00:00Z');
  assert.throws(() => action({ action: 'slotPool.remindOpen', id }), { status: 409, code: 'nothing_open' });
  action({ action: 'slotPool.close', id, version: view('admin', id).version, closed: true });
  assert.throws(() => action({ action: 'slotPool.remindOpen', id }), { status: 409, code: 'closed' });
  action({ action: 'slotPool.delete', id, version: view('admin', id).version });
  assert.equal(store.get('nudges', `slotPool:${id}`), null);
});
