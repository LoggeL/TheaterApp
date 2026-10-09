import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';

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
  assert.equal(store.all('pushJobs').filter(j => j.data?.slotPoolId === id).length, 1, 'edits do not notify again');
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
