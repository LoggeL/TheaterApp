import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures, feedbackPerHour } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';

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
  return { store, app, action, samId, tick, feedbackPushes };
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

test('servers announce feedback support', t => {
  const { app } = setup(t);
  assert.ok(apiFeatures.includes('feedback'));
  assert.ok(app.snapshot('sam').capabilities.features.includes('feedback'));
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
  assert.deepEqual(feedback[1], { id: first.id, message: 'Die Terminliste lädt langsam.', category: 'bug', status: 'new', createdAt: '2026-10-18T10:00:00.000Z', updatedAt: '2026-10-18T10:00:00.000Z', version: 1, appVersion: '0.7.0+12', platform: 'android', author: { uid: 'sam', personId: samId, name: 'Sam Beispiel' } });
  assert.equal(feedback[0].category, 'other');
  assert.equal(feedback[0].appVersion, null);
  assert.equal(feedback[0].platform, null);
  const jobs = feedbackPushes();
  assert.equal(jobs.length, 2);
  assert.equal(jobs[0].adminsOnly, true);
  assert.deepEqual(jobs[0].data, { feedback: '1' });
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

test('admins mark feedback as done with version checks', t => {
  const { app, store, tick } = setup(t);
  const { id } = app.submitFeedback('sam', { message: 'Bitte größere Schrift.' });
  tick();
  const { feedback } = app.feedbackStatus('admin', id, { status: 'done', version: 1 });
  assert.equal(feedback.status, 'done');
  assert.equal(feedback.version, 2);
  assert.equal(feedback.updatedAt, '2026-10-18T10:01:00.000Z');
  assert.equal(feedback.createdAt, '2026-10-18T10:00:00.000Z');
  assert.equal(feedback.author.uid, 'sam');
  const before = store.get('feedback', id);
  assert.throws(() => app.feedbackStatus('admin', id, { status: 'new', version: 1 }), { status: 409, code: 'version_conflict' });
  assert.throws(() => app.feedbackStatus('admin', id, { status: 'archived', version: 2 }), { status: 400 });
  assert.throws(() => app.feedbackStatus('admin', 'missing', { status: 'new', version: 2 }), { status: 404 });
  assert.throws(() => app.feedbackStatus('sam', id, { status: 'new', version: 2 }), { status: 403 });
  assert.deepEqual(store.get('feedback', id), before);
  assert.equal(app.feedbackStatus('admin', id, { status: 'new', version: 2 }).feedback.status, 'new');
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
  const updated = await call('admin', 'PUT', `/admin/feedback/${id}`, { status: 'done', version: 1 });
  assert.equal(updated.status, 200);
  assert.equal(updated.body.feedback.status, 'done');
  assert.equal(updated.body.feedback.version, 2);
  const stale = await call('admin', 'PUT', `/admin/feedback/${id}`, { status: 'new', version: 1 });
  assert.equal(stale.status, 409);
  assert.equal(stale.body.code, 'version_conflict');
  assert.equal((await call('sam', 'PUT', `/admin/feedback/${id}`, { status: 'new', version: 2 })).status, 403);
  for (let i = 1; i < feedbackPerHour; i++) assert.equal((await call('sam', 'POST', '/feedback', { message: `Nr. ${i}` })).status, 200);
  const limited = await call('sam', 'POST', '/feedback', { message: 'Zu viel' });
  assert.equal(limited.status, 429);
  assert.equal(limited.body.code, 'rate_limited');
  assert.match(limited.body.error, /Stunde/);
});
