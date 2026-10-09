import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { purgeExpired } from '../src/retention.mjs';
import { scheduleReminders } from '../src/push.mjs';

const now = new Date('2026-09-12T12:00:00Z');
function setup(t, options = {}) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.com', clock: () => now, ...options });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.com', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `test-${++sequence}`);
  const memberId = action({ action: 'member.save', name: 'Sam' }).id;
  app.session({ uid: 'sam', name: 'Sam', email: 'sam@example.com', email_verified: true });
  action({ action: 'account.approve', uid: 'sam', personId: memberId, version: 1, role: 'member' });
  store.saveAccount({ ...store.account('sam'), approvedAt: '2026-01-01T00:00:00Z' });
  const event = (id, startsAt, extra = {}) => store.put('events', id, { id, title: id, startsAt, endsAt: new Date(Date.parse(startsAt) + 2 * 3600000).toISOString(), type: 'rehearsal', roleIds: [], ...extra });
  const respond = (eventId, status, reason = '') => store.put('responses', `${eventId}:${memberId}`, { eventId, personId: memberId, status, reason, expectedArrivalAt: null, updatedAt: now.toISOString() });
  const check = (eventId, present) => store.put('checkins', `${eventId}:${memberId}`, { eventId, personId: memberId, present, version: 1 });
  return { store, app, action, memberId, event, respond, check };
}

test('participation counts responses and attendance without penalising declines', t => {
  const { app, memberId, event, respond, check } = setup(t);
  event('kept', '2026-09-01T17:00:00Z'); respond('kept', 'yes'); check('kept', true);
  event('missed', '2026-09-03T17:00:00Z'); respond('missed', 'yes'); check('missed', false);
  event('declined', '2026-09-05T17:00:00Z'); respond('declined', 'no', 'Krank'); check('declined', false);
  event('silent', '2026-09-07T17:00:00Z'); check('silent', false);
  event('open', '2026-09-08T17:00:00Z');
  event('party', '2026-09-09T17:00:00Z', { type: 'social' }); check('party', false);
  event('old', '2025-09-01T17:00:00Z'); check('old', false);
  event('future', '2026-09-20T17:00:00Z');
  event('crew', '2026-09-10T17:00:00Z', { roleIds: ['role-3'] }); check('crew', false);
  const expected = { events: 5, answerable: 5, answered: 3, recorded: 4, attended: 1, missedAfterCommitment: 1, missedUnannounced: 1 };
  const own = app.participation('sam');
  assert.deepEqual(own.own, expected);
  assert.equal(own.people, undefined, 'members only see their own summary');
  const all = app.participation('admin');
  assert.deepEqual(all.people.map(p => p.name), ['Admin', 'Sam']);
  assert.deepEqual(all.people.find(p => p.name === 'Sam'), { personId: memberId, name: 'Sam', ...expected });
});

test('absence before an app account exists is not counted as unannounced', t => {
  const { app, store, event, check } = setup(t);
  store.saveAccount({ ...store.account('sam'), approvedAt: '2026-09-06T00:00:00Z' });
  event('before', '2026-09-01T17:00:00Z'); check('before', false);
  assert.deepEqual(app.participation('sam').own, { events: 1, answerable: 0, answered: 0, recorded: 1, attended: 0, missedAfterCommitment: 0, missedUnannounced: 0 });
});

test('admins delete accounts but keep the person; own and stale accounts are protected', async t => {
  const { app, store, memberId } = setup(t);
  store.put('devices', 'd', { id: 'd', uid: 'sam', token: 'x'.repeat(30), platform: 'web' });
  const deleted = [];
  const version = store.account('sam').version;
  await assert.rejects(app.deleteAccount('sam', 'admin', store.account('admin').version), { status: 403 });
  await assert.rejects(app.deleteAccount('admin', 'admin', store.account('admin').version), { status: 409 });
  await assert.rejects(app.deleteAccount('admin', 'sam', version - 1), { status: 409 });
  await app.deleteAccount('admin', 'sam', version, async uid => deleted.push(uid));
  assert.deepEqual(deleted, ['sam']);
  assert.equal(store.account('sam'), null);
  assert.equal(store.get('devices', 'd'), null);
  assert.equal(store.get('members', memberId).name, 'Sam');
  app.session({ uid: 'sam', name: 'Sam', email: 'sam@example.com', email_verified: true });
  assert.equal(store.account('sam').status, 'pending', 'a new registration needs a new approval');
});

test('retention removes expired data and keeps recent data', async t => {
  const { app, store, action, memberId, event, respond } = setup(t);
  const directory = await mkdtemp(join(tmpdir(), 'theater-retention-')); t.after(() => rm(directory, { recursive: true, force: true }));
  store.db.prepare('INSERT INTO requests VALUES(?,?,?,?,?)').run('sam', 'old', 'h', '{}', '2026-08-01T00:00:00Z');
  store.db.prepare('INSERT INTO requests VALUES(?,?,?,?,?)').run('sam', 'recent', 'h', '{}', '2026-09-10T00:00:00Z');
  event('past', '2026-08-01T17:00:00Z'); respond('past', 'no', 'Arzttermin');
  event('recent', '2026-09-05T17:00:00Z');
  store.put('responses', `recent:${memberId}`, { eventId: 'recent', personId: memberId, status: 'no', reason: 'Urlaub' });
  store.put('absences', 'a-old', { id: 'a-old', personId: memberId, from: '2026-07-01', to: '2026-08-01', reason: 'Reise' });
  store.put('absences', 'a-now', { id: 'a-now', personId: memberId, from: '2026-09-01', to: '2026-09-30', reason: '' });
  store.put('pushJobs', 'j-old', { id: 'j-old', createdAt: '2026-07-01T00:00:00Z' });
  store.put('pushJobs', 'j-new', { id: 'j-new', createdAt: '2026-09-11T00:00:00Z' });
  store.put('media', 'orphan', { id: 'orphan', kind: 'profile', ownerPersonId: memberId, createdAt: '2026-09-01T00:00:00Z' });
  store.put('media', 'avatar', { id: 'avatar', kind: 'profile', ownerPersonId: memberId, createdAt: '2026-09-01T00:00:00Z' });
  store.put('members', memberId, { ...store.get('members', memberId), avatarId: 'avatar' });
  for (const id of ['orphan', 'avatar']) await writeFile(join(directory, `${id}.webp`), 'x');
  app.session({ uid: 'old-reject', name: 'Alt', email: 'alt@example.com', email_verified: true });
  app.session({ uid: 'new-reject', name: 'Neu', email: 'neu@example.com', email_verified: true });
  for (const uid of ['old-reject', 'new-reject']) action({ action: 'account.status', uid, status: 'rejected', version: store.account(uid).version });
  store.saveAccount({ ...store.account('old-reject'), statusChangedAt: '2026-01-01T00:00:00Z' });
  const deleted = [];
  const counts = await purgeExpired(app, { now, mediaDirectory: directory, deleteIdentity: async uid => deleted.push(uid) });
  assert.deepEqual(store.db.prepare('SELECT request_id FROM requests WHERE uid = ?').all('sam').map(r => r.request_id), ['recent']);
  assert.equal(store.get('responses', `past:${memberId}`).reason, '');
  assert.equal(store.get('responses', `past:${memberId}`).status, 'no', 'the decline itself stays');
  assert.equal(store.get('responses', `recent:${memberId}`).reason, 'Urlaub');
  assert.deepEqual(store.all('absences').map(x => x.id), ['a-now']);
  assert.deepEqual(store.all('pushJobs').map(x => x.id), ['j-new']);
  assert.deepEqual(store.all('media').map(x => x.id), ['avatar']);
  await assert.rejects(access(join(directory, 'orphan.webp')));
  await access(join(directory, 'avatar.webp'));
  assert.deepEqual(deleted, ['old-reject']);
  assert.equal(store.account('old-reject'), null);
  assert.equal(store.account('new-reject').status, 'rejected');
  assert.equal(counts.rejectedAccounts, 1);
});

test('a personal reminder lead time is validated and sent once instead of an equal fixed reminder', t => {
  const { app, store, action, memberId, event } = setup(t, { pushEnabled: true });
  assert.throws(() => action({ action: 'settings.reminders', value: { twoHours: true, customMinutes: 5 } }, 'sam'), { status: 400 });
  action({ action: 'settings.reminders', value: { twoHours: true, customMinutes: 120 } }, 'sam');
  assert.equal(app.snapshot('sam').reminders.customMinutes, 120);
  event('soon', new Date(+now + 90 * 60000).toISOString());
  scheduleReminders(app, now); scheduleReminders(app, now);
  const jobs = () => store.all('pushJobs').filter(j => j.recipientPersonIds?.includes(memberId));
  assert.equal(jobs().length, 1);
  assert.ok(store.all('reminderSent').length >= 1);
  action({ action: 'settings.reminders', value: { twoHours: false, customMinutes: 3 * 24 * 60 } }, 'sam');
  event('later', new Date(+now + 2 * 24 * 3600000).toISOString());
  scheduleReminders(app, now);
  assert.equal(jobs().length, 2, 'a long lead time reaches beyond the one-day window');
});
