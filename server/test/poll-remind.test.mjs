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
  const people = { sam: person('sam', 'Sam Beispiel', ['role-3']), tech: person('tech', 'Toni Beispiel', ['role-3']), kim: person('kim', 'Kim Beispiel', ['role-3']), lou: person('lou', 'Lou') };
  for (const j of store.all('pushJobs')) store.delete('pushJobs', j.id);
  const pollId = action({ action: 'poll.save', title: 'Probenzeit', options: [{ label: 'Früh' }, { label: 'Spät' }], roleIds: ['role-3'], closesAt: '2026-09-20T18:00:00Z' }).id;
  const vote = (uid, i = 0) => action({ action: 'poll.vote', pollId, optionId: store.get('polls', pollId).options[i].id }, uid);
  return { store, app, action, ...people, pollId, vote };
}

test('poll reminders reach only addressed people who have not voted yet', async t => {
  const { store, app, action, sam, tech, kim, pollId, vote } = setup(t);
  vote('kim');
  const result = action({ action: 'poll.remindOpen', id: pollId });
  assert.deepEqual([result.queued, result.recipients, result.lastRemindedAt], [true, 2, now.toISOString()]);
  const [job] = store.all('pushJobs');
  assert.deepEqual(job.recipientPersonIds.sort(), [sam, tech].sort());
  assert.ok(!job.recipientPersonIds.includes(kim));
  assert.deepEqual([job.title, job.body, job.data, job.remindPoll], ['Abstimmung offen: Probenzeit', 'Abstimmen bis So., 20.09.2026, 20:00 Uhr', { pollId }, true]);
  // Sam votes before delivery and is skipped.
  vote('sam', 1);
  const sent = [];
  await deliverPush(app, { sendEachForMulticast: async p => { sent.push(p); return { responses: p.tokens.map(() => ({ success: true })) }; } });
  assert.deepEqual(sent.flatMap(p => p.tokens), ['token-tech']);
  const admin = app.snapshot('admin').polls[0];
  assert.deepEqual([admin.eligibleCount, admin.eligibleVotes, admin.totalVotes, admin.remindCount, admin.lastRemindedAt], [3, 2, 2, 1, now.toISOString()]);
  const member = app.snapshot('sam').polls[0];
  assert.equal('eligibleCount' in member, false);
  assert.equal('lastRemindedAt' in member, false);
  // Anonymous polls name nobody, not even through the reminder fields.
  assert.ok(!/Beispiel/.test(JSON.stringify(app.snapshot('admin').polls)));
});

test('poll reminders need an admin, push, an open poll, open people and respect the cooldown', t => {
  const { store, app, action, pollId, vote } = setup(t);
  assert.throws(() => action({ action: 'poll.remindOpen', id: pollId }, 'sam'), { status: 403 });
  assert.throws(() => action({ action: 'poll.remindOpen', id: 'missing' }), { status: 404 });
  action({ action: 'poll.remindOpen', id: pollId });
  assert.throws(() => action({ action: 'poll.remindOpen', id: pollId }), { status: 409, code: 'cooldown' });
  app.clock = () => new Date(+now + 15 * 60000);
  for (const uid of ['sam', 'tech', 'kim']) vote(uid);
  assert.throws(() => action({ action: 'poll.remindOpen', id: pollId }), e => e.status === 409 && e.code === 'nothing_open' && e.message === 'Alle haben schon abgestimmt.');
  action({ action: 'poll.close', id: pollId, version: 1 });
  assert.throws(() => action({ action: 'poll.remindOpen', id: pollId }), { status: 409, code: 'closed' });
  assert.equal(store.all('pushJobs').length, 1);
});

test('poll reminders fail clearly without push', t => {
  const { action, pollId } = setup(t, false);
  assert.throws(() => action({ action: 'poll.remindOpen', id: pollId }), { status: 409, code: 'push_unavailable' });
});

test('admin votes outside the audience do not count as participation', t => {
  const { app, vote } = setup(t);
  vote('admin');
  vote('kim');
  const admin = app.snapshot('admin').polls[0];
  assert.deepEqual([admin.eligibleCount, admin.eligibleVotes, admin.totalVotes], [3, 1, 2]);
});
