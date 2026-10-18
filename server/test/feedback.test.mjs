import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures, feedbackPerHour } from '../src/theater.mjs';
import { closeOwnFeedback, feedbackMaxMessages, feedbackRepliesPerHour, feedbackTicketsMigrationId, markFeedbackRead, migrateFeedbackTickets, ownFeedback, ownTicketView, replyAsAdmin, replyAsMember } from '../src/feedback-tickets.mjs';
import { createHttpServer } from '../src/http.mjs';
import { deliverPush } from '../src/push.mjs';

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const clock = { now: new Date('2026-10-18T10:00:00Z') };
  const tick = (ms = 60000) => { clock.now = new Date(+clock.now + ms); };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', pushEnabled: true, clock: () => clock.now });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `feedback-${++sequence}`);
  const samId = action({ action: 'member.save', name: 'Sam Beispiel' }).id;
  app.session({ uid: 'sam', name: 'Sam', email: 'sam@example.invalid', email_verified: true });
  action({ action: 'account.approve', uid: 'sam', personId: samId, version: 1, role: 'member' });
  app.session({ uid: 'pending', name: 'Neu', email: 'pending@example.invalid', email_verified: true });
  const feedbackPushes = () => store.all('pushJobs').filter(j => j.title === 'Neues Feedback');
  const pushes = () => store.all('pushJobs').map(j => ({ title: j.title, body: j.body, data: j.data, adminsOnly: j.adminsOnly ?? false, recipientPersonIds: j.recipientPersonIds ?? null }));
  return { store, app, action, samId, tick, clock, feedbackPushes, pushes };
}

async function serve(t, app) {
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  return async (uid, method, path, body) => {
    const response = await fetch(`${base}${path}`, { method, headers: { Authorization: `Bearer ${uid}`, 'Content-Type': 'application/json' }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    return { status: response.status, body: await response.json() };
  };
}

test('servers announce feedback and ticket support', t => {
  const { app } = setup(t);
  for (const feature of ['feedback', 'feedbackTickets']) {
    assert.ok(apiFeatures.includes(feature));
    assert.ok(app.snapshot('sam').capabilities.features.includes(feature));
  }
});

test('members submit feedback; admins list it newest first and are notified', t => {
  const { app, store, samId, tick, feedbackPushes } = setup(t);
  const first = app.submitFeedback('sam', { message: '  Die Terminliste lädt langsam.  ', category: 'bug', appVersion: ' 0.7.0+12 ', platform: 'android' });
  assert.equal(first.ok, true);
  assert.equal(typeof first.id, 'string');
  tick();
  const second = app.submitFeedback('sam', { message: 'Dunkles Design wäre schön.' });
  const { feedback } = app.feedbackList('admin');
  assert.deepEqual(feedback.map(f => f.id), [second.id, first.id]);
  assert.deepEqual(feedback[1], { id: first.id, message: 'Die Terminliste lädt langsam.', category: 'bug', status: 'open', createdAt: '2026-10-18T10:00:00.000Z', updatedAt: '2026-10-18T10:00:00.000Z', version: 1, appVersion: '0.7.0+12', platform: 'android', messages: [{ id: `${first.id}-0`, from: 'member', text: 'Die Terminliste lädt langsam.', at: '2026-10-18T10:00:00.000Z', author: { personId: samId, name: 'Sam Beispiel' } }], answered: false, lastActivityAt: '2026-10-18T10:00:00.000Z', closedAt: null, closedBy: null, author: { uid: 'sam', personId: samId, name: 'Sam Beispiel' } });
  assert.equal(feedback[0].category, 'other');
  assert.equal(feedback[0].appVersion, null);
  assert.equal(feedback[0].platform, null);
  const jobs = feedbackPushes();
  assert.equal(jobs.length, 2);
  assert.ok(jobs.every(j => j.adminsOnly === true));
  assert.deepEqual(jobs.map(j => j.data.adminFeedbackId).sort(), [first.id, second.id].sort());
  assert.ok(jobs.some(j => j.body === 'Sam Beispiel: Die Terminliste lädt langsam.'));
  assert.equal(store.all('emailJobs').length, 0);
  assert.throws(() => app.feedbackList('sam'), { status: 403 });
});

test('long feedback is shortened in the push only', t => {
  const { app, feedbackPushes } = setup(t);
  const message = `Zeile eins\n\n${'ä'.repeat(300)}`;
  const { id } = app.submitFeedback('sam', { message });
  const [job] = feedbackPushes();
  assert.ok(job.body.startsWith('Sam Beispiel: Zeile eins ä'));
  assert.ok(job.body.endsWith('…'));
  assert.ok(job.body.length <= 'Sam Beispiel: '.length + 120);
  assert.equal(app.feedbackList('admin').feedback.find(f => f.id === id).message, message);
});

test('invalid feedback is rejected without storing anything', t => {
  const { app, store } = setup(t);
  for (const body of [{}, { message: '' }, { message: '   ' }, { message: 42 }, { message: 'x'.repeat(4001) }, { message: 'Hallo', category: 'praise' }, { message: 'Hallo', platform: 'windows' }, { message: 'Hallo', appVersion: 'x'.repeat(41) }, { message: 'Hallo', appVersion: 7 }]) {
    assert.throws(() => app.submitFeedback('sam', body), { status: 400 }, JSON.stringify(body).slice(0, 60));
  }
  assert.equal(app.submitFeedback('sam', { message: ` ${'x'.repeat(4000)} `, category: null, platform: null, appVersion: null }).ok, true);
  assert.equal(store.all('feedback').length, 1);
  assert.throws(() => app.submitFeedback('pending', { message: 'Hallo' }), { status: 403 });
  assert.throws(() => app.submitFeedback('unknown', { message: 'Hallo' }), { status: 403 });
});

test('feedback is rate-limited per account and hour', t => {
  const { app, store, tick } = setup(t);
  for (let i = 0; i < feedbackPerHour; i++) { app.submitFeedback('sam', { message: `Idee ${i}` }); tick(); }
  assert.throws(() => app.submitFeedback('sam', { message: 'Noch eine' }), { status: 429, code: 'rate_limited', message: /später/ });
  assert.equal(store.all('feedback').length, feedbackPerHour);
  assert.equal(app.submitFeedback('admin', { message: 'Andere Person' }).ok, true);
  tick(3600000 - (feedbackPerHour - 1) * 60000);
  assert.equal(app.submitFeedback('sam', { message: 'Eine Stunde später' }).ok, true);
});

test('admins close feedback only after an answer, with version checks', t => {
  const { app, store, tick } = setup(t);
  const { id } = app.submitFeedback('sam', { message: 'Bitte größere Schrift.' });
  tick();
  // Older admin apps send `done`; without an answer it is refused like `closed`.
  for (const status of ['done', 'closed']) assert.throws(() => app.feedbackStatus('admin', id, { status, version: 1 }), { status: 409, code: 'not_answered', message: /geantwortet/ });
  assert.equal(replyAsAdmin(app, 'admin', id, { text: 'Kommt mit dem nächsten Update.' }).feedback.version, 2);
  tick();
  const { feedback } = app.feedbackStatus('admin', id, { status: 'done', version: 2 });
  assert.equal(feedback.status, 'closed');
  assert.equal(feedback.version, 3);
  assert.equal(feedback.updatedAt, '2026-10-18T10:02:00.000Z');
  assert.equal(feedback.closedAt, '2026-10-18T10:02:00.000Z');
  assert.deepEqual(feedback.closedBy, { role: 'admin', name: 'Admin' });
  assert.equal(feedback.createdAt, '2026-10-18T10:00:00.000Z');
  assert.equal(feedback.author.uid, 'sam');
  const before = store.get('feedback', id);
  assert.throws(() => app.feedbackStatus('admin', id, { status: 'open', version: 2 }), { status: 409, code: 'version_conflict' });
  assert.throws(() => app.feedbackStatus('admin', id, { status: 'answered', version: 3 }), { status: 400 });
  assert.throws(() => app.feedbackStatus('admin', id, { status: 'archived', version: 3 }), { status: 400 });
  assert.throws(() => app.feedbackStatus('admin', 'missing', { status: 'open', version: 3 }), { status: 404 });
  assert.throws(() => app.feedbackStatus('sam', id, { status: 'open', version: 3 }), { status: 403 });
  assert.deepEqual(store.get('feedback', id), before);
  const reopened = app.feedbackStatus('admin', id, { status: 'new', version: 3 }).feedback;
  assert.equal(reopened.status, 'open');
  assert.equal(reopened.closedBy, null);
});

test('deleting the login keeps the feedback; deleting the person deletes it', async t => {
  const { app, store, action, samId } = setup(t);
  const { id } = app.submitFeedback('sam', { message: 'Danke für die App!' });
  const other = app.submitFeedback('admin', { message: 'Feedback der Leitung' });
  action({ action: 'member.save', id: samId, name: 'Sam Neu', version: 1 });
  assert.equal(app.feedbackList('admin').feedback.find(f => f.id === id).author.name, 'Sam Neu');
  await app.deleteAccount('admin', 'sam', store.account('sam').version);
  const kept = app.feedbackList('admin').feedback.find(f => f.id === id);
  assert.equal(kept.message, 'Danke für die App!');
  assert.deepEqual(kept.author, { uid: null, personId: samId, name: 'Sam Neu' });
  action({ action: 'member.delete', id: samId });
  assert.equal(store.get('feedback', id), null);
  assert.deepEqual(app.feedbackList('admin').feedback.map(f => f.id), [other.id]);
  assert.ok(!store.all('feedback').some(f => JSON.stringify(f).includes('Sam')));
});

test('HTTP feedback routes follow the mobile API contract', async t => {
  const { app } = setup(t);
  const call = await serve(t, app);
  const created = await call('sam', 'POST', '/feedback', { message: 'Über HTTP', category: 'idea', appVersion: '0.7.0', platform: 'ios' });
  assert.equal(created.status, 200);
  assert.deepEqual(Object.keys(created.body).sort(), ['id', 'ok']);
  const invalid = await call('sam', 'POST', '/feedback', { message: ' ' });
  assert.equal(invalid.status, 400);
  assert.match(invalid.body.error, /Nachricht/);
  assert.equal((await call('pending', 'POST', '/feedback', { message: 'Hallo' })).status, 403);
  assert.equal((await call('sam', 'GET', '/admin/feedback')).status, 403);
  const listed = await call('admin', 'GET', '/admin/feedback');
  assert.equal(listed.status, 200);
  assert.equal(listed.body.feedback.length, 1);
  assert.deepEqual(listed.body.feedback[0].author.uid, 'sam');
  const { id } = created.body;
  const early = await call('admin', 'PUT', `/admin/feedback/${id}`, { status: 'closed', version: 1 });
  assert.equal(early.status, 409);
  assert.equal(early.body.code, 'not_answered');
  const answered = await call('admin', 'POST', `/admin/feedback/${id}/messages`, { text: 'Danke, schauen wir uns an.' });
  assert.equal(answered.status, 200);
  assert.equal(answered.body.feedback.status, 'answered');
  const updated = await call('admin', 'PUT', `/admin/feedback/${id}`, { status: 'closed', version: 2 });
  assert.equal(updated.status, 200);
  assert.equal(updated.body.feedback.status, 'closed');
  assert.equal(updated.body.feedback.version, 3);
  const stale = await call('admin', 'PUT', `/admin/feedback/${id}`, { status: 'open', version: 1 });
  assert.equal(stale.status, 409);
  assert.equal(stale.body.code, 'version_conflict');
  assert.equal((await call('sam', 'PUT', `/admin/feedback/${id}`, { status: 'open', version: 3 })).status, 403);
  assert.equal((await call('sam', 'GET', `/admin/feedback/${id}`)).status, 403);
  assert.equal((await call('sam', 'POST', `/admin/feedback/${id}/messages`, { text: 'Ich bin kein Admin' })).status, 403);
  assert.equal((await call('admin', 'GET', `/admin/feedback/${id}`)).body.feedback.messages.length, 2);
  // The member's side: own list, read marker, follow-up and close.
  const own = await call('sam', 'GET', '/feedback');
  assert.equal(own.status, 200);
  assert.equal(own.body.unread, 1);
  assert.equal(own.body.tickets[0].unread, 1);
  assert.equal(own.body.tickets[0].author, undefined);
  assert.equal((await call('admin', 'GET', '/feedback')).body.tickets.length, 0);
  assert.equal((await call('admin', 'GET', `/feedback/${id}`)).status, 404);
  assert.equal((await call('sam', 'PUT', `/feedback/${id}/read`)).body.ticket.unread, 0);
  const followUp = await call('sam', 'POST', `/feedback/${id}/messages`, { text: 'Doch noch eine Frage.' });
  assert.equal(followUp.status, 200);
  assert.equal(followUp.body.ticket.status, 'open');
  assert.equal((await call('sam', 'GET', `/feedback/${id}`)).body.ticket.messages.length, 3);
  const closed = await call('sam', 'PUT', `/feedback/${id}`, { status: 'closed', version: followUp.body.ticket.version });
  assert.equal(closed.status, 200);
  assert.equal(closed.body.ticket.status, 'closed');
  for (let i = 1; i < feedbackPerHour; i++) assert.equal((await call('sam', 'POST', '/feedback', { message: `Nr. ${i}` })).status, 200);
  const limited = await call('sam', 'POST', '/feedback', { message: 'Zu viel' });
  assert.equal(limited.status, 429);
  assert.equal(limited.body.code, 'rate_limited');
  assert.match(limited.body.error, /Stunde/);
});

test('a ticket becomes a conversation between the author and the admins', t => {
  const { app, store, action, samId, tick, pushes } = setup(t);
  const otherId = action({ action: 'member.save', name: 'Kim Zweit' }).id;
  app.session({ uid: 'kim', name: 'Kim', email: 'kim@example.invalid', email_verified: true });
  action({ action: 'account.approve', uid: 'kim', personId: otherId, version: 1, role: 'member' });
  const { id } = app.submitFeedback('sam', { message: 'Die Probe am Montag fehlt.', category: 'bug' });
  let own = ownFeedback(app, 'sam');
  assert.equal(own.unread, 0);
  assert.equal(own.tickets[0].status, 'open');
  assert.equal(own.tickets[0].answered, false);
  // Closing is refused while no admin has answered, also for the author.
  assert.throws(() => closeOwnFeedback(app, 'sam', id, { status: 'closed', version: 1 }), { status: 409, code: 'not_answered' });

  tick();
  const answer = replyAsAdmin(app, 'admin', id, { text: '  Danke! Ist korrigiert.  ' }).feedback;
  assert.equal(answer.status, 'answered');
  assert.equal(answer.answered, true);
  assert.deepEqual(answer.messages.map(m => [m.from, m.text, m.author.name]), [['member', 'Die Probe am Montag fehlt.', 'Sam Beispiel'], ['admin', 'Danke! Ist korrigiert.', 'Admin']]);
  own = ownFeedback(app, 'sam');
  assert.equal(own.unread, 1);
  assert.equal(own.tickets[0].unread, 1);
  // Others never see the ticket; an unknown id and a foreign id look the same.
  assert.equal(ownFeedback(app, 'kim').tickets.length, 0);
  for (const call of [() => ownTicketView(app, 'kim', id), () => replyAsMember(app, 'kim', id, { text: 'Hallo' }), () => markFeedbackRead(app, 'kim', id), () => closeOwnFeedback(app, 'kim', id, { status: 'closed', version: 2 }), () => ownTicketView(app, 'sam', 'missing')]) assert.throws(call, { status: 404 });
  assert.throws(() => replyAsAdmin(app, 'kim', id, { text: 'Ich bin kein Admin' }), { status: 403 });
  assert.throws(() => replyAsAdmin(app, 'admin', id, { text: '   ' }), { status: 400 });
  assert.throws(() => replyAsMember(app, 'sam', id, { text: 'x'.repeat(4001) }), { status: 400 });

  // A second answer while the first is unread does not push again.
  tick();
  replyAsAdmin(app, 'admin', id, { text: 'Nachtrag: gilt ab sofort.' });
  const read = markFeedbackRead(app, 'sam', id).ticket;
  assert.equal(read.unread, 0);
  assert.equal(read.version, 3, 'reading changes no version');

  tick();
  const followUp = replyAsMember(app, 'sam', id, { text: 'Super, danke!' }).ticket;
  assert.equal(followUp.status, 'open');
  assert.equal(followUp.messages.length, 4);
  tick();
  replyAsMember(app, 'sam', id, { text: 'Und noch was: die Uhrzeit.' });
  tick();
  replyAsAdmin(app, 'admin', id, { text: 'Auch erledigt.' });
  const latest = ownTicketView(app, 'sam', id).ticket;
  assert.throws(() => closeOwnFeedback(app, 'sam', id, { status: 'closed', version: latest.version - 1 }), { status: 409, code: 'version_conflict' });
  assert.throws(() => closeOwnFeedback(app, 'sam', id, { status: 'open', version: latest.version }), { status: 400 });
  const closed = closeOwnFeedback(app, 'sam', id, { status: 'closed', version: latest.version }).ticket;
  assert.equal(closed.status, 'closed');
  assert.deepEqual(closed.closedBy, { role: 'member', name: 'Sam Beispiel' });

  // Writing again reopens the same ticket instead of starting a new one.
  tick();
  const reopened = replyAsMember(app, 'sam', id, { text: 'Leider wieder kaputt.' }).ticket;
  assert.equal(reopened.status, 'open');
  assert.equal(reopened.closedBy, null);
  assert.equal(ownFeedback(app, 'sam').tickets.length, 1);
  assert.equal(app.feedbackList('admin').counts.open, 1);

  const sorted = items => items.map(x => JSON.stringify(x)).sort();
  assert.deepEqual(sorted(pushes().filter(p => p.data?.feedbackId || p.data?.adminFeedbackId)), sorted([
    { title: 'Neues Feedback', body: 'Sam Beispiel: Die Probe am Montag fehlt.', data: { adminFeedbackId: id }, adminsOnly: true, recipientPersonIds: null },
    { title: 'Antwort auf dein Feedback', body: 'Admin: Danke! Ist korrigiert.', data: { feedbackId: id }, adminsOnly: false, recipientPersonIds: [samId] },
    { title: 'Rückmeldung zum Feedback', body: 'Sam Beispiel: Super, danke!', data: { adminFeedbackId: id }, adminsOnly: true, recipientPersonIds: null },
    { title: 'Antwort auf dein Feedback', body: 'Admin: Auch erledigt.', data: { feedbackId: id }, adminsOnly: false, recipientPersonIds: [samId] },
    { title: 'Feedback wieder geöffnet', body: 'Sam Beispiel: Leider wieder kaputt.', data: { adminFeedbackId: id }, adminsOnly: true, recipientPersonIds: null },
  ]));
  assert.equal(store.all('emailJobs').length, 0);
});

test('admins see all tickets with counters, newest activity first', t => {
  const { app, tick } = setup(t);
  const first = app.submitFeedback('sam', { message: 'Erstes' }).id;
  tick();
  const second = app.submitFeedback('sam', { message: 'Zweites', category: 'idea' }).id;
  tick();
  const third = app.submitFeedback('admin', { message: 'Von der Leitung' }).id;
  tick();
  replyAsAdmin(app, 'admin', first, { text: 'Antwort' });
  tick();
  replyAsAdmin(app, 'admin', third, { text: 'Notiz' });
  app.feedbackStatus('admin', third, { status: 'closed', version: 2 });
  const { feedback, counts } = app.feedbackList('admin');
  assert.deepEqual(feedback.map(f => f.id), [third, first, second]);
  assert.deepEqual(counts, { open: 1, answered: 1, closed: 1 });
  assert.deepEqual(feedback.map(f => f.status), ['closed', 'answered', 'open']);
  // An admin answering their own ticket gets no push about it.
  assert.ok(!app.store.all('pushJobs').some(j => j.data?.feedbackId === third));
});

test('replies are rate-limited per account and conversations are bounded', t => {
  const { app, store, tick } = setup(t);
  const { id } = app.submitFeedback('sam', { message: 'Start' });
  for (let i = 0; i < feedbackRepliesPerHour; i++) replyAsMember(app, 'sam', id, { text: `Nachtrag ${i}` });
  assert.throws(() => replyAsMember(app, 'sam', id, { text: 'Zu viel' }), { status: 429, code: 'rate_limited' });
  tick(3600000);
  const f = store.get('feedback', id);
  store.put('feedback', id, { ...f, messages: Array.from({ length: feedbackMaxMessages }, (_, i) => ({ ...f.messages[0], id: `m${i}` })) });
  assert.throws(() => replyAsMember(app, 'sam', id, { text: 'Noch eine' }), { status: 409, code: 'too_many_messages' });
  assert.throws(() => replyAsAdmin(app, 'admin', id, { text: 'Noch eine' }), { status: 409, code: 'too_many_messages' });
});

test('migrated done feedback shows as closed by the admins and the author can reopen it', t => {
  const { app, store, samId } = setup(t);
  store.put('feedback', 'old-done', { id: 'old-done', message: 'Mehr Kontrast bitte.', category: 'idea', status: 'done', createdAt: '2026-10-17T08:00:00.000Z', updatedAt: '2026-10-17T12:00:00.000Z', version: 2, appVersion: '0.7.1', platform: 'web', authorUid: 'sam', authorPersonId: samId, authorName: 'Sam' });
  store.delete('migrations', feedbackTicketsMigrationId);
  assert.deepEqual(migrateFeedbackTickets(store), { converted: 1, closed: 1 });
  const ticket = ownTicketView(app, 'sam', 'old-done').ticket;
  assert.equal(ticket.status, 'closed');
  assert.equal(ticket.answered, false);
  assert.equal(ticket.closedAt, '2026-10-17T12:00:00.000Z');
  assert.deepEqual(ticket.closedBy, { role: 'admin', name: '' });
  const reopened = replyAsMember(app, 'sam', 'old-done', { text: 'Noch nicht ganz.' }).ticket;
  assert.equal(reopened.status, 'open');
  assert.equal(reopened.closedBy, null);
  assert.equal(store.get('feedback', 'old-done').legacyStatus, 'done');
});

test('existing feedback becomes tickets once, at server start; done feedback is closed', t => {
  const store = new Store(); t.after(() => store.close());
  const legacy = [
    { id: 'old-1', message: 'Dunkler Modus?', category: 'idea', status: 'done', createdAt: '2026-10-18T08:00:00.000Z', updatedAt: '2026-10-18T09:00:00.000Z', version: 2, appVersion: '0.7.0', platform: 'android', authorUid: 'sam', authorPersonId: 7, authorName: 'Sam' },
    { id: 'old-2', message: 'Fehler im Kalender', category: 'bug', status: 'new', createdAt: '2026-10-18T07:00:00.000Z', updatedAt: '2026-10-18T07:00:00.000Z', version: 1, appVersion: null, platform: null, authorUid: null, authorPersonId: 8, authorName: 'Kim' },
  ];
  for (const f of legacy) store.put('feedback', f.id, f);
  new Theater(store, { clock: () => new Date('2026-10-18T10:00:00Z') });
  const migrated = store.get('feedback', 'old-1');
  assert.deepEqual(migrated, { ...legacy[0], status: 'closed', legacyStatus: 'done', closedAt: legacy[0].updatedAt, closedBy: { role: 'admin', uid: null, personId: null, name: '' }, version: 3, lastActivityAt: legacy[0].createdAt, messages: [{ id: 'old-1-0', from: 'member', text: 'Dunkler Modus?', at: legacy[0].createdAt, byUid: 'sam', byPersonId: 7, byName: 'Sam' }] });
  assert.equal(store.get('feedback', 'old-2').status, 'open');
  assert.equal(store.get('feedback', 'old-2').legacyStatus, undefined);
  assert.equal(store.get('feedback', 'old-2').closedBy, undefined);
  assert.deepEqual(store.get('migrations', feedbackTicketsMigrationId).report, { converted: 2, closed: 1 });
  // Running again changes nothing, with or without the marker.
  const snapshot = JSON.stringify(store.all('feedback'));
  assert.equal(migrateFeedbackTickets(store).alreadyApplied, true);
  store.delete('migrations', feedbackTicketsMigrationId);
  assert.deepEqual(migrateFeedbackTickets(store), { converted: 0, closed: 0 });
  new Theater(store);
  assert.equal(JSON.stringify(store.all('feedback')), snapshot);
});

test('deleting an admin keeps their answers without their name', async t => {
  const { app, store, action } = setup(t);
  const helperId = action({ action: 'member.save', name: 'Robin Leitung' }).id;
  app.session({ uid: 'robin', name: 'Robin', email: 'robin@example.invalid', email_verified: true });
  action({ action: 'account.approve', uid: 'robin', personId: helperId, version: 1, role: 'admin' });
  const { id } = app.submitFeedback('sam', { message: 'Frage zur Probe' });
  replyAsAdmin(app, 'robin', id, { text: 'Antwort von Robin' });
  app.feedbackStatus('robin', id, { status: 'closed', version: 2 });
  await app.deleteAccount('admin', 'robin', store.account('robin').version);
  assert.ok(!JSON.stringify(store.get('feedback', id)).includes('"robin"'));
  action({ action: 'member.delete', id: helperId });
  const ticket = ownTicketView(app, 'sam', id).ticket;
  assert.equal(ticket.messages[1].text, 'Antwort von Robin');
  assert.deepEqual(ticket.messages[1].author, { personId: null, name: '' });
  assert.deepEqual(ticket.closedBy, { role: 'admin', name: '' });
  assert.ok(!JSON.stringify(store.get('feedback', id)).includes('Robin Leitung'));
});

test('feedback pushes open the ticket: admins their view, the author their own', async t => {
  const { app, store } = setup(t);
  store.put('devices', 'admin-web', { id: 'admin-web', uid: 'admin', token: 'token-admin', platform: 'web' });
  store.put('devices', 'sam-web', { id: 'sam-web', uid: 'sam', token: 'token-sam', platform: 'web' });
  const { id } = app.submitFeedback('sam', { message: 'Hallo Leitung' });
  replyAsAdmin(app, 'admin', id, { text: 'Hallo Sam' });
  const sent = [];
  await deliverPush(app, { sendEachForMulticast: async p => { sent.push(p); return { responses: p.tokens.map(() => ({ success: true })) }; } }, 'https://theater.example');
  const feedbackSent = sent.filter(p => /feedback/i.test(p.notification.title));
  const target = token => new URL(feedbackSent.find(p => p.tokens.includes(token)).webpush.fcmOptions.link).searchParams.get('target');
  assert.equal(feedbackSent.length, 2);
  assert.equal(target('token-admin'), `theaterapp://app/admin-feedback/${id}`);
  assert.equal(target('token-sam'), `theaterapp://app/feedback/${id}`);
});
