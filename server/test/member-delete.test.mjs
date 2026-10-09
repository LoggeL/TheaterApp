import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';

const now = new Date('2026-09-12T12:00:00Z');
function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.com', pushEnabled: true, clock: () => now });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.com', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `test-${++sequence}`);
  const person = (uid, name) => {
    const id = action({ action: 'member.save', name }).id;
    app.session({ uid, name, email: `${uid}@example.com`, email_verified: true });
    action({ action: 'account.approve', uid, personId: id, version: 1, role: 'member' });
    return id;
  };
  return { store, app, action, sam: person('sam', 'Sam'), kim: person('kim', 'Kim') };
}
const at = (day, hour) => `2026-09-${day}T${String(hour).padStart(2, '0')}:00:00Z`;
const event = (extra = {}) => ({ action: 'event.save', title: 'Probe', startsAt: at(20, 17), endsAt: at(20, 19), ...extra });
const poll = (extra = {}) => ({ action: 'poll.save', title: 'Sommerfest?', options: [{ label: 'Ja' }, { label: 'Nein' }], ...extra });

/** Gives Sam a bit of everything a person can leave behind. */
function populate({ store, app, action, sam, kim }) {
  const shared = action(event({ personIds: [sam, kim] })).id;
  const samOnly = action(event({ title: 'Kostümanprobe', personIds: [sam] })).id;
  const everyone = action(event({ title: 'Hauptprobe' })).id;
  action({ action: 'attendance', eventId: shared, status: 'yes' }, 'sam');
  action({ action: 'checkin.save', eventId: everyone, members: [{ id: sam, present: true }, { id: kim, present: false }] });
  action({ action: 'absence.create', from: '2026-09-25', to: '2026-09-26', reason: 'Urlaub' }, 'sam');
  action({ action: 'settings.reminders', value: { dayBefore: true, twoHours: false, changes: true } }, 'sam');
  store.put('reminderSent', `${everyone}:${at(20, 17)}:${sam}:dayBefore`, { at: now.toISOString() });
  store.put('reminderSent', `${everyone}:${at(20, 17)}:${kim}:dayBefore`, { at: now.toISOString() });
  const message = action({ action: 'message.send', audience: 'selected', recipientPersonIds: [sam, kim], title: 'Hallo', body: 'Text' }).id;
  const samMessage = action({ action: 'message.send', audience: 'selected', recipientPersonIds: [sam], title: 'Nur Sam', body: 'Text' }).id;
  action({ action: 'message.read', id: message }, 'sam');
  store.put('messages', 'by-sam', { id: 'by-sam', title: 'Von Sam', body: 'Text', audience: 'all', roleIds: [], productionIds: [], recipientPersonIds: [], authorId: sam, authorName: 'Sam', createdAt: now.toISOString() });
  const anonymous = action(poll({ personIds: [sam, kim] })).id, named = action(poll({ anonymous: false })).id, samPoll = action(poll({ personIds: [sam] })).id;
  for (const id of [anonymous, named]) {
    const [yes, no] = store.get('polls', id).options;
    action({ action: 'poll.vote', pollId: id, optionId: yes.id }, 'sam');
    action({ action: 'poll.vote', pollId: id, optionId: no.id }, 'kim');
  }
  action({ action: 'poll.vote', pollId: samPoll, optionId: store.get('polls', samPoll).options[0].id }, 'sam');
  const slots = [{ startsAt: at(22, 10), endsAt: at(22, 11), capacity: 2 }];
  const pool = action({ action: 'slotPool.save', title: 'Fotos', slots }).id, samPool = action({ action: 'slotPool.save', title: 'Einzelgespräch', slots, personIds: [sam] }).id;
  const slotId = store.get('slotPools', pool).slots[0].id;
  action({ action: 'slot.book', poolId: pool, slotId }, 'sam');
  action({ action: 'slot.book', poolId: pool, slotId }, 'kim');
  action({ action: 'slot.book', poolId: samPool, slotId: store.get('slotPools', samPool).slots[0].id }, 'sam');
  app.importScript('admin', { id: 'stueck', title: 'Stück' }, { revision: 'r1', cues: [{ id: 'c1', sceneId: 's1', ordinal: 1 }], scenes: [{ id: 's1' }], roles: [{ id: 'romeo' }, { id: 'julia' }] });
  action({ action: 'production.save', id: 'stueck', version: store.get('productions', 'stueck').version, title: 'Stück', casting: { romeo: sam, julia: kim }, directorMemberIds: [sam, kim], memberIds: [sam] });
  action({ action: 'comment.save', productionId: 'stueck', cueId: 'c1', revision: 'r1', text: 'Hier lauter' }, 'sam');
  store.put('media', 'avatar', { id: 'avatar', kind: 'profile', ownerPersonId: sam, createdAt: now.toISOString() });
  store.put('members', sam, { ...store.get('members', sam), avatarId: 'avatar' });
  return { shared, samOnly, everyone, message, samMessage, anonymous, named, samPoll, pool, samPool, slotId };
}

test('deleting a person is admin-only and protects the own person and linked accounts', async t => {
  const { store, app, action, sam, kim } = setup(t);
  const version = store.get('members', sam).version;
  assert.throws(() => action({ action: 'member.delete', id: sam, version }, 'kim'), { status: 403 });
  assert.throws(() => action({ action: 'member.delete', id: store.account('admin').personId }), { status: 409, message: /eigene Person/ });
  assert.throws(() => action({ action: 'member.delete', id: 999 }), { status: 404 });
  assert.throws(() => action({ action: 'member.delete', id: sam, version }), { status: 409, message: /App-Konto/ });
  await app.deleteAccount('admin', 'sam', store.account('sam').version);
  assert.throws(() => action({ action: 'member.delete', id: sam, version: version - 1 }), { status: 409, message: /geändert/ });
  assert.ok(store.get('members', sam), 'rejected attempts change nothing');
  action({ action: 'member.delete', id: sam, version });
  assert.equal(store.get('members', sam), null);
  assert.ok(store.get('members', kim));
  // A rejected (not reconsidered) account still links the person.
  action({ action: 'account.status', uid: 'kim', status: 'rejected', version: store.account('kim').version });
  assert.throws(() => action({ action: 'member.delete', id: kim }), { status: 409 });
});

test('deleting a person removes every reference and keeps the rest consistent', async t => {
  const ctx = setup(t), { store, app, action, sam, kim } = ctx;
  const ids = populate(ctx);
  await app.deleteAccount('admin', 'sam', store.account('sam').version);
  action({ action: 'member.delete', id: sam });

  assert.equal(store.get('members', sam), null);
  for (const kind of ['responses', 'checkins', 'receipts', 'absences', 'slotBookings', 'comments']) {
    assert.deepEqual(store.all(kind).filter(x => x.personId === sam || x.authorId === sam), [], kind);
  }
  assert.equal(store.get('checkins', `${ids.everyone}:${kim}`).present, false, 'other people keep their data');
  assert.equal(store.get('reminders', sam), null);
  const reminderKeys = store.db.prepare("SELECT id FROM entities WHERE kind = 'reminderSent'").all().map(r => r.id);
  assert.deepEqual(reminderKeys, [`${ids.everyone}:${at(20, 17)}:${kim}:dayBefore`]);
  assert.equal(store.get('media', 'avatar').ownerPersonId, null, 'the orphaned profile image is left to retention');

  // Audiences: Sam leaves shared lists; things addressed to Sam alone are gone instead of opening up to everyone.
  assert.deepEqual(store.get('events', ids.shared).personIds, [kim]);
  assert.equal(store.get('events', ids.samOnly), null);
  assert.ok(store.get('events', ids.everyone));
  assert.deepEqual(store.get('polls', ids.anonymous).personIds, [kim]);
  assert.equal(store.get('polls', ids.samPoll), null);
  assert.deepEqual(store.all('pollVotes').filter(v => v.pollId === ids.samPoll), []);
  assert.deepEqual(store.get('messages', ids.message).recipientPersonIds, [kim]);
  assert.equal(store.get('messages', ids.samMessage), null);
  assert.deepEqual(store.all('receipts').filter(r => r.messageId === ids.samMessage), []);
  assert.equal(store.get('messages', 'by-sam').authorId, null);
  assert.equal(store.get('messages', 'by-sam').authorName, 'Ehemaliges Mitglied');
  assert.equal(store.get('slotPools', ids.samPool), null);
  assert.equal(store.all('events').some(e => e.slotPoolId === ids.samPool), false);
  const slotEvent = store.get('events', `slot-${ids.pool}-${ids.slotId}`);
  assert.deepEqual(slotEvent.personIds, [kim]);
  const production = store.get('productions', 'stueck');
  assert.deepEqual(production.casting, { julia: kim });
  assert.deepEqual(production.directorMemberIds, [kim]);
  assert.deepEqual(production.memberIds, []);
  for (const kind of ['events', 'polls', 'slotPools', 'messages', 'productions']) {
    const text = JSON.stringify(store.all(kind));
    assert.doesNotMatch(text, new RegExp(`"(personIds|recipientPersonIds|directorMemberIds|memberIds)":\\[[^\\]]*\\b${sam}\\b`), kind);
  }

  // Poll results: anonymous counts stay, named votes go with the name.
  const kimView = app.snapshot('kim');
  const anonymous = kimView.polls.find(p => p.id === ids.anonymous), named = kimView.polls.find(p => p.id === ids.named);
  assert.equal(anonymous.totalVotes, 2);
  assert.deepEqual(anonymous.options.map(o => o.votes), [1, 1]);
  assert.equal(named.totalVotes, 1);
  assert.deepEqual(named.options.flatMap(o => o.voters.map(v => v.personId)), [kim]);

  // Snapshots, participation, push delivery input and new people still work.
  const adminView = app.snapshot('admin');
  assert.equal(adminView.members.some(m => m.id === sam), false);
  assert.equal(Object.values(adminView.memberAttendanceByEvent).some(x => String(sam) in x), false);
  assert.equal(adminView.messages.find(m => m.id === ids.message).recipientIds.includes(sam), false);
  assert.deepEqual(app.participation('admin').people.map(p => p.personId).sort(), [store.account('admin').personId, kim].sort());
  assert.ok(app.participation('kim').own);
  const next = action({ action: 'member.save', name: 'Neu' }).id;
  assert.ok(next > sam, 'the id of a deleted person is never handed out again');
  action({ action: 'member.delete', id: next });
  assert.ok(action({ action: 'member.save', name: 'Noch neuer' }).id > next);
});
