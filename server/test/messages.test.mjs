import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';

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
    return id;
  };
  return { store, app, action, sam: person('sam', 'Sam'), tech: person('tech', 'Toni', ['role-3']), kim: person('kim', 'Kim') };
}

test('admins see who read a message and can remind only the others', t => {
  const { app, store, action, sam, tech } = setup(t);
  const id = action({ action: 'message.send', title: 'Kabel', body: 'Bitte mitbringen', audience: 'selected', roleIds: ['role-3'], recipientPersonIds: [sam] }).id;
  action({ action: 'message.read', id }, 'sam');
  const seen = app.snapshot('admin').messages.find(m => m.id === id);
  assert.deepEqual(seen.recipientIds.sort(), [sam, tech].sort());
  assert.deepEqual(seen.readerIds, [sam]);
  assert.equal(app.snapshot('sam').messages[0].recipientIds, undefined, 'members do not see read receipts');
  assert.equal(action({ action: 'message.remind', id }).recipients, 1);
  const job = store.all('pushJobs').find(j => j.title.startsWith('Erinnerung'));
  assert.deepEqual(job.recipientPersonIds, [tech]);
  assert.match(job.title, /^Erinnerung: Kabel/);
  action({ action: 'message.read', id }, 'tech');
  assert.throws(() => action({ action: 'message.remind', id }), { status: 409 });
  assert.throws(() => action({ action: 'message.remind', id }, 'kim'), { status: 403 });
  assert.equal(app.snapshot('kim').messages.length, 0, 'not addressed to Kim');
});

test('admins delete messages with their receipts and members mark all read', t => {
  const { app, store, action } = setup(t);
  const first = action({ action: 'message.send', title: 'Eins', body: 'A', audience: 'all' }).id;
  action({ action: 'message.send', title: 'Zwei', body: 'B', audience: 'all' });
  action({ action: 'message.read', id: first }, 'sam');
  action({ action: 'message.readAll' }, 'sam');
  assert.equal(app.snapshot('sam').messages.every(m => m.read), true);
  assert.equal(app.snapshot('kim').messages.some(m => m.read), false);
  assert.throws(() => action({ action: 'message.delete', id: first }, 'sam'), { status: 403 });
  action({ action: 'message.delete', id: first });
  assert.equal(store.get('messages', first), null);
  assert.equal(store.all('receipts').some(r => r.messageId === first), false);
  assert.deepEqual(app.snapshot('sam').messages.map(m => m.title), ['Zwei']);
});

test('custom pushes reach the chosen audience without storing a message', t => {
  const { store, action, sam, tech } = setup(t);
  const result = action({ action: 'push.send', title: 'Probe fällt aus', body: 'Details folgen.', audience: 'selected', roleIds: ['role-3'], recipientPersonIds: [sam] });
  assert.equal(result.recipients, 2);
  const job = store.all('pushJobs').find(j => j.manual);
  assert.deepEqual(job.recipientPersonIds.sort(), [sam, tech].sort());
  assert.equal(job.manual, true);
  assert.equal(job.title, 'Probe fällt aus');
  assert.equal(store.all('messages').length, 0);
  assert.throws(() => action({ action: 'push.send', title: '', body: 'x', audience: 'all' }), { status: 400 });
  assert.throws(() => action({ action: 'push.send', title: 'x', body: 'x', audience: 'selected' }), { status: 400 });
  assert.throws(() => action({ action: 'push.send', title: 'x', body: 'x', audience: 'all' }, 'sam'), { status: 403 });
  const everyone = action({ action: 'push.send', title: 'Hallo', body: 'Alle', audience: 'all' });
  assert.equal(everyone.recipients, 4);
});

test('custom pushes need a configured push service', t => {
  const { action } = setup(t, false);
  assert.throws(() => action({ action: 'push.send', title: 'x', body: 'x', audience: 'all' }), { status: 409 });
});

test('messages carry an optional web link', t => {
  const { app, action } = setup(t);
  action({ action: 'message.send', title: 'Anmeldung', body: 'Bitte eintragen', audience: 'all', link: ' https://example.com/form ', linkLabel: 'Zum Formular' });
  const m = app.snapshot('sam').messages[0];
  assert.equal(m.link, 'https://example.com/form');
  assert.equal(m.linkLabel, 'Zum Formular');
  assert.throws(() => action({ action: 'message.send', title: 'X', body: 'Y', audience: 'all', link: 'javascript:alert(1)' }), { status: 400 });
  action({ action: 'message.send', title: 'Ohne', body: 'Link', audience: 'all', link: '' });
  assert.equal(app.snapshot('sam').messages.find(x => x.title === 'Ohne').link, undefined);
});
