import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';

const now = new Date('2026-09-12T12:00:00Z');
function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.com', clock: () => now });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.com', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `test-${++sequence}`);
  const person = (uid, name, roleIds = []) => {
    const id = action({ action: 'member.save', name, roleIds }).id;
    app.session({ uid, name, email: `${uid}@example.com`, email_verified: true });
    action({ action: 'account.approve', uid, personId: id, version: 1, role: 'member' });
    return id;
  };
  return { store, app, action, sam: person('sam', 'Sam'), tech: person('tech', 'Toni', ['role-3']) };
}

test('admins see whether events, polls and slot pools are addressed to them', t => {
  const { app, action } = setup(t);
  const roleEvent = action({ action: 'event.save', title: 'Lichtprobe', startsAt: '2026-09-14T17:00:00Z', endsAt: '2026-09-14T19:00:00Z', roleIds: ['role-3'] }).id;
  const allEvent = action({ action: 'event.save', title: 'Vollversammlung', startsAt: '2026-09-15T17:00:00Z', endsAt: '2026-09-15T19:00:00Z' }).id;
  const poll = action({ action: 'poll.save', title: 'Farbe?', options: [{ label: 'Rot' }, { label: 'Blau' }], roleIds: ['role-3'] }).id;
  const pool = action({ action: 'slotPool.save', title: 'Fotos', roleIds: ['role-3'], personIds: [app.store.account('sam').personId], slots: [{ startsAt: '2026-09-20T10:00:00Z', endsAt: '2026-09-20T10:15:00Z', capacity: 2 }] }).id;
  action({ action: 'slot.book', poolId: pool, slotId: app.snapshot('sam').slotPools[0].slots[0].id }, 'sam');
  const slotEvent = app.snapshot('admin').events.find(e => e.slotPoolId === pool).id;

  const admin = app.snapshot('admin');
  const flag = (items, id) => items.find(x => x.id === id).addressedToMe;
  assert.deepEqual([flag(admin.events, roleEvent), flag(admin.events, slotEvent), flag(admin.events, allEvent)], [false, false, true]);
  assert.equal(flag(admin.polls, poll), false);
  assert.equal(flag(admin.slotPools, pool), false);

  for (const uid of ['sam', 'tech']) {
    const own = app.snapshot(uid);
    assert.ok([...own.events, ...own.polls, ...own.slotPools].every(x => x.addressedToMe === true), `${uid} only receives what is addressed to them`);
  }
  assert.deepEqual(app.snapshot('tech').events.map(e => e.id).sort(), [roleEvent, allEvent].sort());
});

test('admin RSVPs and votes outside their audience stay possible for older clients', t => {
  const { app, action } = setup(t);
  const eventId = action({ action: 'event.save', title: 'Lichtprobe', startsAt: '2026-09-14T17:00:00Z', endsAt: '2026-09-14T19:00:00Z', roleIds: ['role-3'] }).id;
  const pollId = action({ action: 'poll.save', title: 'Farbe?', options: [{ label: 'Rot' }, { label: 'Blau' }], roleIds: ['role-3'] }).id;
  action({ action: 'attendance', eventId, status: 'yes' });
  action({ action: 'poll.vote', pollId, optionId: app.store.get('polls', pollId).options[0].id });
  assert.equal(app.snapshot('admin').attendanceByEvent[eventId], 'yes');
});
