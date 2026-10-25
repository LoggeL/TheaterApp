import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { formTemplates, messageForm, formSubmissions } from '../src/forms.mjs';
import { purgeExpired } from '../src/retention.mjs';
import { createHttpServer } from '../src/http.mjs';

const now = new Date('2026-10-25T12:00:00Z');
function setup(t) {
  const store = new Store();
  t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.com', clock: () => now });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.com', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `forms-${++sequence}`);
  const person = (uid, name) => {
    const id = action({ action: 'member.save', name }).id;
    app.session({ uid, name, email: `${uid}@example.com`, email_verified: true });
    action({ action: 'account.approve', uid, personId: id, version: 1, role: 'member' });
    return id;
  };
  const sam = person('sam', 'Sam'), kim = person('kim', 'Kim');
  const create = (overrides = {}) => {
    const result = action(template(overrides));
    return formTemplates(app, 'admin').templates.find(x => x.id === result.id);
  };
  const publish = (form, overrides = {}) => action({ action: 'message.send', title: 'Anmeldung', body: 'Bitte ausfüllen.', audience: 'all', formId: form.id, formVersion: form.version, ...overrides }).id;
  return { store, app, action, sam, kim, create, publish };
}

const template = (overrides = {}) => ({
  action: 'form.save',
  title: 'Probenwochenende',
  description: 'Rückmeldung zur Teilnahme.',
  fields: [
    { id: 'name', type: 'text', label: 'Name', required: true },
    { id: 'comment', type: 'multiline', label: 'Anmerkung', required: false },
    { id: 'arrival', type: 'date', label: 'Anreise', required: true },
    { id: 'meal', type: 'choice', label: 'Essen', required: true, options: ['Vegetarisch', 'Standard'] },
    { id: 'agree', type: 'checkbox', label: 'Teilnahme bestätigen', required: true },
  ],
  signatureRequired: true,
  confirmationText: 'Ich bestätige meine Angaben.',
  ...overrides,
});

const response = (messageId, overrides = {}) => ({
  action: 'form.submit', messageId, formVersion: 1, submissionGeneration: 0,
  answers: { name: 'Sam', comment: 'Privater Formularinhalt', arrival: '2026-11-20', meal: 'Vegetarisch', agree: true },
  confirmed: true,
  signerName: 'Sam',
  signature: { strokes: [[[0.1, 0.2], [0.3, 0.8], [0.7, 0.3]]] },
  ...overrides,
});

test('only admins manage templates and template edits require the current version', t => {
  const { app, action, create } = setup(t);
  assert.throws(() => formTemplates(app, 'sam'), { status: 403 });
  assert.throws(() => action(template(), 'sam'), { status: 403 });
  const form = create();
  assert.equal(form.version, 1);
  assert.equal(form.archived, false);
  assert.throws(() => action(template({ id: form.id, title: 'Änderung' })), { status: 409, code: 'version_conflict' });
  assert.throws(() => action(template({ id: form.id, version: 0 })), { status: 409, code: 'version_conflict' });
  action(template({ id: form.id, version: form.version, title: 'Überarbeitete Anmeldung' }));
  const changed = formTemplates(app, 'admin').templates.find(x => x.id === form.id);
  assert.equal(changed.version, 2);
  assert.equal(changed.title, 'Überarbeitete Anmeldung');
  assert.equal(changed.createdAt, form.createdAt);
  assert.throws(() => action({ action: 'form.archive', id: form.id, version: 2, archived: true }, 'sam'), { status: 403 });
});

test('template definitions reject duplicate ids, invalid types and unusable choices', t => {
  const { action } = setup(t);
  for (const fields of [
    [{ id: 'same', type: 'text', label: 'A', required: true }, { id: 'same', type: 'text', label: 'B', required: false }],
    [{ id: 'unsupported', type: 'html', label: 'Inhalt', required: false }],
    [{ id: 'empty', type: 'choice', label: 'Auswahl', required: false, options: [] }],
    [{ id: 'duplicate', type: 'choice', label: 'Auswahl', required: false, options: ['Ja', 'Ja'] }],
    [{ id: 'blank', type: 'text', label: '  ', required: false }],
  ]) assert.throws(() => action(template({ fields })), { status: 400 });
  assert.equal(action(template()).ok, true, 'invalid definitions do not prevent later valid saves');
});

test('published messages keep the exact form version despite template edits or archiving', t => {
  const { app, action, create, publish } = setup(t);
  const form = create(), messageId = publish(form);
  action(template({ id: form.id, version: 1, title: 'Neue Vorlage', confirmationText: 'Ein anderer Bestätigungstext.' }));
  const frozen = messageForm(app, 'sam', messageId).form;
  assert.equal(frozen.title, form.title);
  assert.equal(frozen.version, 1);
  assert.equal(frozen.confirmationText, form.confirmationText);
  assert.throws(() => publish(form), { status: 409, code: 'version_conflict' });
  action({ action: 'form.archive', id: form.id, version: 2, archived: true });
  const archived = formTemplates(app, 'admin').templates.find(x => x.id === form.id);
  assert.equal(archived.archived, true);
  assert.throws(() => publish(archived), { status: 409 });
  assert.equal(action(response(messageId), 'sam').ok, true, 'existing published forms remain answerable');
  const submitted = messageForm(app, 'sam', messageId).mySubmission;
  assert.equal(submitted.form.title, form.title);
  assert.equal(submitted.form.confirmationText, form.confirmationText);
});

test('only addressed active members can submit, including admins without audience bypass', t => {
  const { app, store, action, sam, create, publish } = setup(t);
  const messageId = publish(create(), { audience: 'selected', recipientPersonIds: [sam] });
  assert.equal(messageForm(app, 'sam', messageId).addressedToMe, true);
  assert.equal(messageForm(app, 'admin', messageId).addressedToMe, false);
  assert.throws(() => messageForm(app, 'kim', messageId), { status: 404 });
  assert.throws(() => action(response(messageId), 'kim'), e => [403, 404].includes(e.status));
  assert.throws(() => action(response(messageId), 'admin'), e => [403, 404].includes(e.status));
  store.put('members', sam, { ...store.get('members', sam), active: false });
  assert.throws(() => action(response(messageId), 'sam'), { status: 403 });
  assert.equal(store.all('formSubmissions').length, 0);
});

test('submitted forms stay accessible to their owner after leaving the addressed role', t => {
  const { app, store, action, sam, create, publish } = setup(t);
  store.put('members', sam, { ...store.get('members', sam), roleIds: ['role-3'] });
  const messageId = publish(create(), { audience: 'selected', roleIds: ['role-3'] });
  action(response(messageId), 'sam');
  const receipt = messageForm(app, 'sam', messageId).mySubmission;
  store.put('members', sam, { ...store.get('members', sam), roleIds: [] });

  const own = messageForm(app, 'sam', messageId);
  assert.deepEqual(own.mySubmission, receipt);
  assert.equal(own.addressedToMe, false);
  const message = app.snapshot('sam').messages.find(m => m.id === messageId);
  assert.equal(message.myFormSubmittedAt, receipt.submittedAt);
  assert.equal(message.addressedToMe, false);
  assert.throws(() => action(response(messageId), 'sam'), { status: 403 }, 'receipt access does not grant submission eligibility');
  assert.throws(() => messageForm(app, 'kim', messageId), { status: 404 });
  assert.equal(app.snapshot('kim').messages.some(m => m.id === messageId), false);

  store.saveAccount({ ...store.account('sam'), status: 'blocked' });
  assert.throws(() => messageForm(app, 'sam', messageId), { status: 403 }, 'saved receipts do not bypass account approval');
  assert.throws(() => app.snapshot('sam'), { status: 403 });
});

test('required fields, true confirmation, valid dates and known choices are checked on the server', t => {
  const { action, create, publish } = setup(t), messageId = publish(create());
  const good = response(messageId);
  const badAnswers = [
    { ...good.answers, name: '' },
    { ...good.answers, agree: false },
    { ...good.answers, agree: 'true' },
    { ...good.answers, arrival: '2026-02-30' },
    { ...good.answers, arrival: '20.11.2026' },
    { ...good.answers, meal: 'Unbekannt' },
    { ...good.answers, unknown: 'Zusatz' },
    { ...good.answers, name: ['Sam'] },
  ];
  for (const answers of badAnswers) assert.throws(() => action(response(messageId, { answers }), 'sam'), { status: 400 });
  assert.throws(() => action(response(messageId, { confirmed: false }), 'sam'), { status: 400 });
  assert.throws(() => action(response(messageId, { confirmed: 'true' }), 'sam'), { status: 400 });
  assert.throws(() => action(response(messageId, { formVersion: 2 }), 'sam'), { status: 409, code: 'version_conflict' });
  assert.equal(action(good, 'sam').ok, true);
});

test('a required signature needs a name and an actual bounded drawing', t => {
  const { action, create, publish } = setup(t), messageId = publish(create());
  const invalid = [
    { signerName: '' },
    { signature: null },
    { signature: { strokes: [] } },
    { signature: { strokes: [[[0.2, 0.2], [0.2, 0.2]]] } },
    { signature: { strokes: [[[0, 0], [1.1, 0.5]]] } },
    { signature: { strokes: [[[0, 0], [-0.1, 0.5]]] } },
    { signature: { strokes: [[[0, 0], ['0.1', 0.5]]] } },
  ];
  for (const patch of invalid) assert.throws(() => action(response(messageId, patch), 'sam'), { status: 400 });
  assert.equal(action(response(messageId), 'sam').ok, true);
  const unsignedMessage = publish(create({ signatureRequired: false }));
  assert.equal(action(response(unsignedMessage, { signerName: '', signature: null }), 'kim').ok, true);
});

test('saved responses derive identity and time from the server and remain private', t => {
  const { app, store, action, sam, create, publish } = setup(t), messageId = publish(create());
  const reply = action(response(messageId, { personId: 999, accountUid: 'admin', personName: 'Forged', submittedAt: '1900-01-01T00:00:00Z' }), 'sam');
  assert.equal(reply.ok, true);
  assert.equal(reply.submission, undefined, 'mutation cache contains no full private response');
  const own = messageForm(app, 'sam', messageId).mySubmission;
  assert.equal(own.personId, sam);
  assert.equal(own.accountUid, 'sam');
  assert.equal(own.personName, 'Sam');
  assert.equal(own.submittedAt, now.toISOString());
  assert.equal(own.answers.comment, 'Privater Formularinhalt');
  assert.equal(messageForm(app, 'kim', messageId).mySubmission, null);
  assert.throws(() => formSubmissions(app, 'kim', messageId), { status: 403 });
  assert.equal(formSubmissions(app, 'admin', messageId).submissions[0].id, own.id);
  for (const uid of ['sam', 'kim', 'admin']) {
    const snapshot = JSON.stringify(app.snapshot(uid));
    assert.doesNotMatch(snapshot, /Privater Formularinhalt/);
    assert.doesNotMatch(snapshot, /"strokes"/);
    assert.doesNotMatch(snapshot, /"signerName"/);
  }
  const cached = JSON.stringify(store.db.prepare('SELECT result FROM requests').all());
  assert.doesNotMatch(cached, /Privater Formularinhalt|signerName|strokes/);
});

test('network retries do not duplicate or overwrite a submitted response', t => {
  const { app, store, action, create, publish } = setup(t), messageId = publish(create());
  const body = response(messageId);
  const first = app.action('sam', body, 'stable-submit-key');
  assert.deepEqual(app.action('sam', body, 'stable-submit-key'), first);
  assert.equal(action(body, 'sam').id, first.id, 'a fresh retry key also refers to the same immutable response');
  assert.throws(() => action(response(messageId, { answers: { ...body.answers, comment: 'Verändert' } }), 'sam'), { status: 409, code: 'already_submitted' });
  assert.throws(() => app.action('sam', response(messageId, { signerName: 'Anders' }), 'stable-submit-key'), { status: 409, code: 'request_reused' });
  assert.equal(store.all('formSubmissions').length, 1);
  assert.equal(messageForm(app, 'sam', messageId).mySubmission.answers.comment, body.answers.comment);
});

test('reusing a template in two messages keeps their responses independent', t => {
  const { app, action, create, publish } = setup(t), form = create();
  const first = publish(form), second = publish(form);
  action(response(first), 'sam');
  assert.equal(messageForm(app, 'sam', second).mySubmission, null);
  action(response(second, { answers: { ...response(second).answers, comment: 'Zweiter Termin' } }), 'sam');
  assert.notEqual(messageForm(app, 'sam', first).mySubmission.id, messageForm(app, 'sam', second).mySubmission.id);
  assert.equal(formSubmissions(app, 'admin', first).submissions.length, 1);
  assert.equal(formSubmissions(app, 'admin', second).submissions.length, 1);
});

test('deleting a message removes its responses and private detail becomes unavailable', t => {
  const { app, store, action, create, publish } = setup(t), form = create();
  const deleted = publish(form), kept = publish(form);
  action(response(deleted), 'sam');
  action(response(kept), 'kim');
  action({ action: 'message.delete', id: deleted });
  assert.deepEqual(store.all('formSubmissions').map(x => x.messageId), [kept]);
  assert.throws(() => messageForm(app, 'sam', deleted), { status: 404 });
  assert.throws(() => formSubmissions(app, 'admin', deleted), { status: 404 });
});

test('account and person cleanup remove their submissions without deleting other responses', async t => {
  const { app, store, action, sam, create, publish } = setup(t), messageId = publish(create());
  action(response(messageId), 'sam');
  action(response(messageId, { signerName: 'Kim' }), 'kim');
  await app.deleteAccount('admin', 'sam', store.account('sam').version);
  assert.equal(store.all('formSubmissions').some(x => x.personId === sam), false);
  assert.equal(store.db.prepare('SELECT count(*) AS n FROM requests WHERE uid=?').get('sam').n, 0);
  action({ action: 'member.delete', id: sam });
  assert.equal(store.all('formSubmissions').length, 1);
  assert.equal(store.all('formSubmissions')[0].accountUid, 'kim');
});

test('person cleanup also removes a submission whose login is already absent', t => {
  const { app, store, action, sam, create, publish } = setup(t), messageId = publish(create());
  const result = action(response(messageId), 'sam');
  // Isolate the person cleanup from account cleanup, as with imported orphaned data.
  store.deleteAccount('sam');
  action({ action: 'member.delete', id: sam });
  assert.equal(store.get('formSubmissions', result.id), null);
  assert.equal(store.db.prepare("SELECT count(*) AS n FROM requests WHERE json_extract(result, '$.id') = ?").get(result.id).n, 0);
  assert.equal(formSubmissions(app, 'admin', messageId).submissions.length, 0);
});

test('retention removes orphaned and year-old submissions while keeping recent responses', async t => {
  const { app, store, action, create, publish } = setup(t), form = create();
  const orphaned = publish(form), old = publish(form), recent = publish(form);
  action(response(orphaned), 'sam');
  const oldReply = action(response(old), 'sam');
  action(response(recent), 'kim');
  const oldRecord = store.all('formSubmissions').find(x => x.id === oldReply.id);
  store.put('formSubmissions', oldRecord.id, { ...oldRecord, submittedAt: '2025-10-24T12:00:00Z' });
  store.delete('messages', orphaned);
  await purgeExpired(app, { now });
  assert.deepEqual(store.all('formSubmissions').map(x => x.messageId), [recent]);
});

test('form HTTP routes require approved authentication and never cache private responses', async t => {
  const { app, action, sam, create, publish } = setup(t);
  app.session({ uid: 'pending', name: 'Neu', email: 'pending@example.com', email_verified: true });
  const messageId = publish(create(), { audience: 'selected', recipientPersonIds: [sam] });
  action(response(messageId), 'sam');
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  const get = async (uid, path) => fetch(`${base}${path}`, { headers: uid ? { Authorization: `Bearer ${uid}` } : {} });
  assert.equal((await get(null, '/forms/templates')).status, 401);
  assert.equal((await get('pending', `/forms/messages/${messageId}`)).status, 403);
  assert.equal((await get('sam', '/forms/templates')).status, 403);
  const templates = await get('admin', '/forms/templates');
  assert.equal(templates.status, 200);
  assert.equal((await templates.json()).templates.length, 1);
  const own = await get('sam', `/forms/messages/${messageId}`);
  assert.equal(own.status, 200);
  assert.match(own.headers.get('cache-control'), /no-store/);
  assert.equal((await own.json()).mySubmission.answers.comment, 'Privater Formularinhalt');
  assert.equal((await get('kim', `/forms/messages/${messageId}`)).status, 404);
  assert.equal((await get('sam', `/forms/messages/${messageId}/submissions`)).status, 403);
  const all = await get('admin', `/forms/messages/${messageId}/submissions`);
  assert.equal(all.status, 200);
  assert.match(all.headers.get('cache-control'), /no-store/);
  assert.equal((await all.json()).submissions.length, 1);
});

test('form deletion dates must be real future Berlin dates and stay frozen on publication', t => {
  const { app, action, create, publish } = setup(t);
  for (const deleteAfter of ['2026-02-30', '2026-10-25', '2026-10-24', '26.10.2026', '2026-10-26T12:00:00Z', 20261026]) {
    assert.throws(() => create({ deleteAfter }), { status: 400 });
  }
  for (const deleteAfter of [null, '']) assert.equal(create({ deleteAfter }).deleteAfter, null);
  const form = create({ deleteAfter: '2026-10-26' });
  const messageId = publish(form);
  action(template({ id: form.id, version: 1, deleteAfter: '2026-12-01' }));
  assert.equal(messageForm(app, 'sam', messageId).form.deleteAfter, '2026-10-26');
  assert.equal(formTemplates(app, 'admin').templates.find(x => x.id === form.id).deleteAfter, '2026-12-01');
  const expiring = create({ deleteAfter: '2026-10-26' });
  app.clock = () => new Date('2026-10-25T23:00:00Z');
  assert.throws(() => publish(expiring), { status: 409, code: 'closed' });
  assert.throws(() => create({ deleteAfter: '2026-10-26' }), { status: 400 }, 'Berlin is already on the selected deletion day');
});

test('a deletion date closes and hides responses at Berlin midnight before the purge runs', async t => {
  const { app, store, action, create, publish } = setup(t);
  const messageId = publish(create({ deleteAfter: '2026-10-26' }));
  const submitted = action(response(messageId), 'sam');
  app.clock = () => new Date('2026-10-25T22:59:59.999Z');
  assert.equal(messageForm(app, 'sam', messageId).closed, false);
  assert.equal(messageForm(app, 'sam', messageId).mySubmission.id, submitted.id);
  app.clock = () => new Date('2026-10-25T23:00:00Z');
  const expired = messageForm(app, 'sam', messageId);
  assert.equal(expired.closed, true);
  assert.equal(expired.mySubmission, null);
  assert.deepEqual(formSubmissions(app, 'admin', messageId).submissions, []);
  const memberSnapshot = app.snapshot('sam').messages.find(x => x.id === messageId);
  const adminSnapshot = app.snapshot('admin').messages.find(x => x.id === messageId);
  assert.equal(memberSnapshot.myFormSubmittedAt, null);
  assert.equal(memberSnapshot.formClosed, true);
  assert.equal(adminSnapshot.formSubmissionCount, 0);
  assert.equal(adminSnapshot.formClosed, true);
  assert.throws(() => action(response(messageId), 'kim'), { status: 409, code: 'closed' });
  assert.ok(store.get('formSubmissions', submitted.id), 'reads hide expired data even before physical deletion');
  await purgeExpired(app, { now: app.clock() });
  assert.equal(store.get('formSubmissions', submitted.id), null);
});

test('year-old responses stay hidden from detail and counts before physical deletion', t => {
  const { app, store, action, create, publish } = setup(t), messageId = publish(create());
  const submitted = action(response(messageId), 'sam');
  const stored = store.get('formSubmissions', submitted.id);
  store.put('formSubmissions', stored.id, { ...stored, submittedAt: '2025-10-24T12:00:00Z' });
  assert.equal(messageForm(app, 'sam', messageId).mySubmission, null);
  assert.deepEqual(formSubmissions(app, 'admin', messageId).submissions, []);
  assert.equal(app.snapshot('sam').messages.find(x => x.id === messageId).myFormSubmittedAt, null);
  assert.equal(app.snapshot('admin').messages.find(x => x.id === messageId).formSubmissionCount, 0);
  assert.ok(store.get('formSubmissions', submitted.id));
});

test('checkbox wording can be longer than a field name while remaining bounded', t => {
  const { create } = setup(t);
  const make = (type, label) => ({ fields: [{ id: 'field', type, label, required: true }] });
  assert.equal(create(make('checkbox', 'x'.repeat(2000))).fields[0].label.length, 2000);
  assert.throws(() => create(make('checkbox', 'x'.repeat(2001))), { status: 400 });
  assert.equal(create(make('text', 'x'.repeat(200))).fields[0].label.length, 200);
  assert.throws(() => create(make('text', 'x'.repeat(201))), { status: 400 });
});

test('withdrawal requires the exact receipt timestamp and only an owner or admin may perform it', t => {
  const { app, store, action, sam, create, publish } = setup(t), messageId = publish(create());
  const submitted = action(response(messageId), 'sam');
  const receiptId = messageForm(app, 'sam', messageId).mySubmission.receiptId;
  const withdraw = { action: 'form.withdraw', messageId, submittedAt: submitted.submittedAt, receiptId };
  for (const submittedAt of [undefined, '', 'not-a-time']) {
    assert.throws(() => action({ ...withdraw, submittedAt }, 'sam'), { status: 400 });
  }
  for (const receiptId of [undefined, '', 'not-a-receipt']) {
    assert.throws(() => action({ ...withdraw, receiptId }, 'sam'), { status: 400 });
  }
  assert.throws(() => action({ ...withdraw, submittedAt: '2026-10-25T11:59:59.999Z' }, 'sam'), { status: 409, code: 'version_conflict' });
  assert.throws(() => action({ ...withdraw, personId: sam }, 'kim'), { status: 403 });
  assert.ok(store.get('formSubmissions', submitted.id));
  assert.equal(action(withdraw, 'sam').withdrawn, true);
  assert.equal(messageForm(app, 'sam', messageId).mySubmission, null);
  assert.equal(action(withdraw, 'sam').withdrawn, false);
  const next = action(response(messageId, { submissionGeneration: messageForm(app, 'sam', messageId).submissionGeneration }), 'sam');
  const nextReceipt = messageForm(app, 'sam', messageId).mySubmission;
  assert.equal(action({ ...withdraw, personId: sam, submittedAt: next.submittedAt, receiptId: nextReceipt.receiptId }, 'admin').withdrawn, true);
  assert.equal(store.get('formSubmissions', next.id), null);
});

test('a member may withdraw their receipt after leaving the message audience', t => {
  const { app, store, action, sam, kim, create, publish } = setup(t);
  const messageId = publish(create(), { audience: 'selected', recipientPersonIds: [sam] });
  const submitted = action(response(messageId), 'sam');
  const receiptId = messageForm(app, 'sam', messageId).mySubmission.receiptId;
  const message = store.get('messages', messageId);
  store.put('messages', messageId, { ...message, recipientPersonIds: [kim] });
  assert.equal(messageForm(app, 'sam', messageId).addressedToMe, false);
  assert.equal(messageForm(app, 'sam', messageId).mySubmission.id, submitted.id);
  assert.equal(action({ action: 'form.withdraw', messageId, submittedAt: submitted.submittedAt, receiptId }, 'sam').withdrawn, true);
  assert.equal(store.get('formSubmissions', submitted.id), null);
  assert.throws(() => messageForm(app, 'sam', messageId), { status: 404 });
});

test('retrying an old withdrawal cannot delete a fresh submission, even within the same millisecond', t => {
  const { app, store, action, create, publish } = setup(t), messageId = publish(create());
  const original = action(response(messageId), 'sam');
  const receiptId = messageForm(app, 'sam', messageId).mySubmission.receiptId;
  const withdraw = { action: 'form.withdraw', messageId, submittedAt: original.submittedAt, receiptId };
  const firstWithdrawal = app.action('sam', withdraw, 'stable-withdrawal-key');
  assert.equal(firstWithdrawal.withdrawn, true);
  const fresh = action(response(messageId, { submissionGeneration: messageForm(app, 'sam', messageId).submissionGeneration }), 'sam');
  const freshReceipt = messageForm(app, 'sam', messageId).mySubmission;
  assert.equal(fresh.submittedAt, original.submittedAt, 'the test deliberately keeps the server clock unchanged');
  assert.notEqual(freshReceipt.receiptId, receiptId, 'each receipt has a unique token even at the same time');
  assert.deepEqual(app.action('sam', withdraw, 'stable-withdrawal-key'), firstWithdrawal);
  assert.equal(store.get('formSubmissions', fresh.id).submittedAt, fresh.submittedAt);
  assert.throws(() => action(withdraw, 'sam'), { status: 409, code: 'version_conflict' });
  assert.equal(store.get('formSubmissions', fresh.id).submittedAt, fresh.submittedAt);
});

test('a delayed retry of a withdrawn submission cannot restore the deleted answers', t => {
  const { app, store, action, create, publish } = setup(t), messageId = publish(create());
  const body = response(messageId);
  const original = app.action('sam', body, 'original-submit-key');
  const receipt = messageForm(app, 'sam', messageId).mySubmission;
  action({ action: 'form.withdraw', messageId, submittedAt: receipt.submittedAt, receiptId: receipt.receiptId }, 'sam');
  assert.equal(store.get('formSubmissions', original.id), null);
  assert.throws(() => app.action('sam', body, 'original-submit-key'), { status: 409, code: 'version_conflict' });
  assert.equal(store.get('formSubmissions', original.id), null);
  assert.doesNotMatch(JSON.stringify(store.db.prepare('SELECT result FROM requests').all()), /Privater Formularinhalt|signerName|strokes/);
  const fresh = action({ ...body, submissionGeneration: messageForm(app, 'sam', messageId).submissionGeneration }, 'sam');
  assert.equal(messageForm(app, 'sam', messageId).mySubmission.id, fresh.id);
  assert.notEqual(messageForm(app, 'sam', messageId).mySubmission.receiptId, receipt.receiptId);
  assert.throws(() => app.action('sam', body, 'original-submit-key'), { status: 409, code: 'version_conflict' });
  assert.ok(store.get('formSubmissions', fresh.id), 'the old retry does not alter a fresh submission');
});

test('submissions require the exact integer generation supplied by the current form response', t => {
  const { app, action, create, publish } = setup(t), messageId = publish(create());
  assert.equal(messageForm(app, 'sam', messageId).submissionGeneration, 0);
  for (const submissionGeneration of [undefined, null, '0', 0.5, -1]) {
    assert.throws(() => action(response(messageId, { submissionGeneration }), 'sam'), { status: 400 });
  }
  assert.throws(() => action(response(messageId, { submissionGeneration: 1 }), 'sam'), { status: 409, code: 'version_conflict' });
  const original = action(response(messageId), 'sam');
  const receipt = messageForm(app, 'sam', messageId).mySubmission;
  action({ action: 'form.withdraw', messageId, submittedAt: receipt.submittedAt, receiptId: receipt.receiptId }, 'sam');
  const reopened = messageForm(app, 'sam', messageId);
  assert.equal(reopened.submissionGeneration, 1);
  assert.equal(reopened.mySubmission, null);
  assert.equal(action(response(messageId, { submissionGeneration: reopened.submissionGeneration }), 'sam').id, original.id);
});

test('withdrawn submissions cannot return after the idempotency cache has expired', async t => {
  const { app, store, action, create, publish } = setup(t), messageId = publish(create());
  const originalBody = response(messageId);
  const original = app.action('sam', originalBody, 'long-delayed-submit');
  const receipt = messageForm(app, 'sam', messageId).mySubmission;
  action({ action: 'form.withdraw', messageId, submittedAt: receipt.submittedAt, receiptId: receipt.receiptId }, 'sam');
  // Request timestamps use the wall clock; fix the test's cache age explicitly.
  store.db.prepare('UPDATE requests SET created_at = ?').run(now.toISOString());
  app.clock = () => new Date('2026-11-10T12:00:00Z');
  await purgeExpired(app, { now: app.clock() });
  assert.equal(store.db.prepare('SELECT count(*) AS n FROM requests').get().n, 0);
  assert.ok(store.get('formGenerations', original.id), 'the minimal generation survives request-cache retention');
  assert.equal(messageForm(app, 'sam', messageId).submissionGeneration, 1);
  assert.throws(() => app.action('sam', originalBody, 'long-delayed-submit'), { status: 409, code: 'version_conflict' });
  assert.equal(store.get('formSubmissions', original.id), null);
  const freshGeneration = messageForm(app, 'sam', messageId).submissionGeneration;
  assert.equal(action(response(messageId, { submissionGeneration: freshGeneration }), 'sam').ok, true);
  assert.ok(store.get('formSubmissions', original.id));
});

test('account deletion preserves the generation when its person gets a new login', async t => {
  const { app, store, action, sam, create, publish } = setup(t), messageId = publish(create());
  const originalBody = response(messageId);
  const original = app.action('sam', originalBody, 'before-account-deletion');
  await app.deleteAccount('admin', 'sam', store.account('sam').version);
  assert.ok(store.get('formGenerations', original.id));
  app.session({ uid: 'sam', name: 'Sam', email: 'sam@example.com', email_verified: true });
  action({ action: 'account.approve', uid: 'sam', personId: sam, version: 1, role: 'member' });
  const reopened = messageForm(app, 'sam', messageId);
  assert.equal(reopened.submissionGeneration, 1);
  assert.equal(reopened.mySubmission, null);
  assert.throws(() => app.action('sam', originalBody, 'before-account-deletion'), { status: 409, code: 'version_conflict' });
  assert.equal(action(response(messageId, { submissionGeneration: reopened.submissionGeneration }), 'sam').ok, true);
});

test('message and person deletion remove their durable submission generations', async t => {
  const { app, store, action, sam, create, publish } = setup(t), form = create();
  const messageId = publish(form), otherMessageId = publish(form);
  const first = action(response(messageId), 'sam');
  const firstReceipt = messageForm(app, 'sam', messageId).mySubmission;
  action({ action: 'form.withdraw', messageId, submittedAt: firstReceipt.submittedAt, receiptId: firstReceipt.receiptId }, 'sam');
  assert.ok(store.get('formGenerations', first.id));
  action({ action: 'message.delete', id: messageId });
  assert.equal(store.get('formGenerations', first.id), null);
  const second = action(response(otherMessageId), 'sam');
  await app.deleteAccount('admin', 'sam', store.account('sam').version);
  assert.ok(store.get('formGenerations', second.id));
  action({ action: 'member.delete', id: sam });
  assert.equal(store.get('formGenerations', second.id), null);
});

test('an expired receipt exposes the next generation before purge and fresh submission advances it once', async t => {
  const { app, store, action, create, publish } = setup(t), messageId = publish(create());
  const originalBody = response(messageId);
  const original = app.action('sam', originalBody, 'expired-receipt-submit');
  const oldReceipt = store.get('formSubmissions', original.id);
  store.put('formSubmissions', oldReceipt.id, { ...oldReceipt, submittedAt: '2025-10-24T12:00:00Z' });
  const reopened = messageForm(app, 'sam', messageId);
  assert.equal(reopened.mySubmission, null);
  assert.equal(reopened.submissionGeneration, 1, 'the GET anticipates the pending retention deletion');
  assert.throws(() => app.action('sam', originalBody, 'expired-receipt-submit'), { status: 409, code: 'version_conflict' });
  const fresh = action(response(messageId, { submissionGeneration: reopened.submissionGeneration }), 'sam');
  const freshReceipt = store.get('formSubmissions', fresh.id);
  assert.notEqual(freshReceipt.receiptId, oldReceipt.receiptId);
  assert.equal(freshReceipt.submittedAt, now.toISOString());
  assert.equal(messageForm(app, 'sam', messageId).submissionGeneration, 1);
  await purgeExpired(app, { now });
  assert.equal(messageForm(app, 'sam', messageId).submissionGeneration, 1, 'the daily purge cannot advance an already replaced receipt');
  assert.equal(store.get('formSubmissions', fresh.id).receiptId, freshReceipt.receiptId);
});
