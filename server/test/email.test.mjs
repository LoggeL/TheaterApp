import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { ResendEmail, deliverEmail, eventEmail } from '../src/email.mjs';
import { scheduleReminders } from '../src/push.mjs';

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const theater = new Theater(store, { emailEnabled: true, bootstrapEmail: 'admin@example.com' });
  const account = theater.session({ uid: 'admin', email: 'admin@example.com', email_verified: true });
  const now = new Date();
  store.put('events', 'e', { id: 'e', title: '<Probe>', place: 'Kolpingheim', startsAt: new Date(+now + 3600000).toISOString(), endsAt: new Date(+now + 7200000).toISOString() });
  const sent = [], email = { configured: true, send: async value => { sent.push(value); return 'provider-id'; } };
  return { store, theater, account, now, sent, email };
}

test('Resend sends one recipient with idempotency, TLS and escaped event content', async () => {
  let request;
  const transport = new ResendEmail({ apiKey: 'test-key', from: 'Theater <app@example.com>', fetchImpl: async (url, options) => { request = { url, ...options }; return new Response('{"id":"email-id"}', { status: 200 }); } });
  const content = eventEmail({ change: true }, { id: 'e 1', title: '<Probe>', startsAt: '2026-12-14T18:00:00Z', place: 'A&B' }, 'https://app.example.com');
  assert.equal(await transport.send({ to: 'one@example.com', ...content, idempotencyKey: 'stable-key' }), 'email-id');
  assert.equal(request.url, 'https://api.resend.com/emails'); assert.equal(request.redirect, 'error');
  assert.equal(request.headers['Idempotency-Key'], 'stable-key');
  assert.deepEqual(JSON.parse(request.body).to, ['one@example.com']);
  assert.match(content.html, /&lt;Probe&gt;/); assert.match(content.html, /A&amp;B/);
  assert.match(content.text, /19:00 Uhr/); assert.match(content.text, /theaterapp%3A%2F%2Fapp%2Fevents%2Fe%25201/);
});

test('event emails default off, work without push and preserve opt-in from old clients', async t => {
  const { store, theater, account, email, sent } = setup(t);
  assert.equal(theater.snapshot('admin').reminders.emailEnabled, false);
  theater.enqueuePush({ data: { eventId: 'e' }, change: true });
  await deliverEmail(theater, email, 'https://app.example.com'); assert.equal(sent.length, 0);
  theater.action('admin', { action: 'settings.reminders', value: { emailEnabled: true, twoHours: true, changes: true } }, 'opt-in');
  theater.action('admin', { action: 'settings.reminders', value: { twoHours: true, changes: true } }, 'old-client');
  assert.equal(store.get('reminders', account.personId).emailEnabled, true);
  scheduleReminders(theater); scheduleReminders(theater);
  assert.equal(store.all('pushJobs').length, 0);
  await deliverEmail(theater, email, 'https://app.example.com'); await deliverEmail(theater, email, 'https://app.example.com');
  assert.equal(sent.length, 1); assert.equal(store.all('emailJobs').filter(x => x.status === 'accepted_by_provider').length, 1);
});

test('email recipients require opt-in, approved account, verified email and current invitation', async t => {
  const { store, theater, account, email, sent } = setup(t);
  store.put('reminders', account.personId, { emailEnabled: true, changes: true });
  for (const edit of [
    () => store.saveAccount({ ...store.account('admin'), emailVerified: false }),
    () => store.saveAccount({ ...store.account('admin'), emailVerified: true, status: 'suspended' }),
    () => { store.saveAccount({ ...store.account('admin'), status: 'approved' }); store.put('events', 'e', { ...store.get('events', 'e'), personIds: [999] }); },
  ]) { edit(); theater.enqueuePush({ data: { eventId: 'e' }, change: true }); await deliverEmail(theater, email, 'https://app.example.com'); }
  assert.equal(sent.length, 0);
});

test('retries keep stable idempotency and skip already accepted recipients', async t => {
  const { store, theater, account, now } = setup(t);
  store.put('reminders', account.personId, { emailEnabled: true, changes: true });
  theater.enqueuePush({ data: { eventId: 'e' }, change: true });
  const keys = []; let attempt = 0;
  const email = { configured: true, send: async value => { keys.push(value.idempotencyKey); if (attempt++ === 0) throw Object.assign(new Error('temporary'), { retryable: true }); return 'id'; } };
  await deliverEmail(theater, email, 'https://app.example.com');
  const job = store.all('emailJobs')[0]; store.put('emailJobs', job.id, { ...job, nextAttemptAt: now.toISOString() });
  await deliverEmail(theater, email, 'https://app.example.com'); await deliverEmail(theater, email, 'https://app.example.com');
  assert.equal(keys.length, 2); assert.equal(keys[0], keys[1]); assert.equal(store.get('emailJobs', job.id).status, 'accepted_by_provider');
});

test('declined reminders, deleted events and jobs past the idempotency window are not sent', async t => {
  const { store, theater, account, email, sent, now } = setup(t);
  store.put('reminders', account.personId, { emailEnabled: true });
  store.put('responses', `e:${account.personId}`, { status: 'no' });
  theater.enqueuePush({ data: { eventId: 'e' } }); await deliverEmail(theater, email, 'https://app.example.com');
  store.delete('events', 'e'); theater.enqueuePush({ data: { eventId: 'e' } }); await deliverEmail(theater, email, 'https://app.example.com');
  theater.enqueueEmail({ test: true, recipientPersonIds: [account.personId] });
  const job = store.all('emailJobs').find(x => x.test); store.put('emailJobs', job.id, { ...job, createdAt: new Date(+now - 24 * 3600000).toISOString() });
  await deliverEmail(theater, email, 'https://app.example.com'); assert.equal(sent.length, 0); assert.equal(store.get('emailJobs', job.id).status, 'expired');
});

test('event creation, change and cancellation queue mail; test only targets the requester', async t => {
  const { store, theater, account, now, email, sent } = setup(t);
  store.put('reminders', account.personId, { emailEnabled: true, changes: true });
  const payload = { action: 'event.save', title: 'Probe', startsAt: new Date(+now + 3600000).toISOString(), endsAt: new Date(+now + 7200000).toISOString() };
  const { id } = theater.action('admin', payload, 'new');
  await deliverEmail(theater, email, 'https://app.example.com');
  theater.action('admin', { ...payload, id, version: 1 }, 'change');
  await deliverEmail(theater, email, 'https://app.example.com');
  assert.equal(sent.length, 2);
  theater.action('admin', { action: 'event.delete', id, version: 2 }, 'delete');
  theater.action('admin', { action: 'email.test' }, 'self-test');
  await deliverEmail(theater, email, 'https://app.example.com');
  assert.equal(sent.length, 4); assert.ok(sent.some(x => x.subject === 'Termin abgesagt: Probe'));
  assert.deepEqual(store.all('emailJobs').find(x => x.test).recipientPersonIds, [account.personId]);
});

test('a replaced schedule suppresses pending emails for the old event version', async t => {
  const { store, theater, account, email, sent } = setup(t);
  store.put('reminders', account.personId, { emailEnabled: true, changes: true });
  store.put('events', 'e', { ...store.get('events', 'e'), version: 1 });
  theater.enqueuePush({ data: { eventId: 'e' }, change: true });
  store.put('events', 'e', { ...store.get('events', 'e'), version: 2 });
  await deliverEmail(theater, email, 'https://app.example.com');
  assert.equal(sent.length, 0); assert.equal(store.all('emailJobs')[0].status, 'obsolete');
});

test('permanent provider errors terminate retries and never retain provider response bodies', async t => {
  const { store, theater, account } = setup(t);
  const email = new ResendEmail({ apiKey: 'test-key', from: 'Theater <app@example.com>', fetchImpl: async () => new Response('{"message":"private provider data"}', { status: 403 }) });
  theater.enqueueEmail({ test: true, recipientPersonIds: [account.personId] });
  await deliverEmail(theater, email, 'https://app.example.com');
  const job = store.all('emailJobs')[0]; assert.equal(job.status, 'failed'); assert.equal(job.lastError, 'resend_403'); assert.doesNotMatch(JSON.stringify(job), /private provider data/);
});

test('large recipient lists continue after each batch without consuming failure retries', async t => {
  const { store, theater, now, email, sent } = setup(t);
  for (let id = 10; id < 35; id++) {
    store.put('members', id, { id, name: 'Test', active: true });
    store.saveAccount({ uid: `user-${id}`, personId: id, status: 'approved', role: 'member', email: `user-${id}@example.com`, emailVerified: true });
    store.put('reminders', id, { emailEnabled: true, changes: true });
  }
  theater.enqueuePush({ data: { eventId: 'e' }, change: true });
  await deliverEmail(theater, email, 'https://app.example.com');
  const first = store.all('emailJobs')[0]; assert.equal(first.status, 'pending'); assert.equal(first.attempts, 0); assert.equal(sent.length, 20);
  store.put('emailJobs', first.id, { ...first, nextAttemptAt: now.toISOString() });
  await deliverEmail(theater, email, 'https://app.example.com');
  assert.equal(sent.length, 25); assert.equal(new Set(sent.map(x => x.to)).size, 25); assert.equal(store.get('emailJobs', first.id).status, 'accepted_by_provider');
});

test('opting out during a batch stops the pending recipient before their send', async t => {
  const { store, theater, account, sent } = setup(t);
  store.put('reminders', account.personId, { emailEnabled: true, changes: true });
  store.put('members', 50, { id: 50, name: 'Second', active: true });
  store.saveAccount({ uid: 'second', personId: 50, status: 'approved', role: 'member', email: 'second@example.com', emailVerified: true });
  store.put('reminders', 50, { emailEnabled: true, changes: true });
  theater.enqueuePush({ data: { eventId: 'e' }, change: true });
  await deliverEmail(theater, { configured: true, send: async value => { sent.push(value); store.put('reminders', account.personId, { emailEnabled: false }); return 'id'; } }, 'https://app.example.com');
  assert.deepEqual(sent.map(x => x.to), ['second@example.com']);
});
