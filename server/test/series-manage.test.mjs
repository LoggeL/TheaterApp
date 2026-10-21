import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures } from '../src/theater.mjs';
import { seriesRhythm } from '../src/event-series.mjs';
import { eventEmail } from '../src/email.mjs';

// "Ganze Serie" (`event.save` with `series: 'all'`): edit, extend and end a series as a whole.
const now = new Date('2026-09-12T12:00:00Z');
function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.com', pushEnabled: true, clock: () => now });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.com', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `manage-${++sequence}`);
  const person = (uid, name, roleIds = []) => {
    const id = action({ action: 'member.save', name, roleIds }).id;
    app.session({ uid, name, email: `${uid}@example.com`, email_verified: true });
    action({ action: 'account.approve', uid, personId: id, version: 1, role: 'member' });
    return id;
  };
  const people = { sam: person('sam', 'Sam'), kim: person('kim', 'Kim'), leo: person('leo', 'Leo') };
  const clear = () => { for (const kind of ['pushJobs', 'emailJobs']) for (const j of store.all(kind)) store.delete(kind, j.id); };
  clear(); // registration notices
  return { store, app, action, clear, ...people };
}
// Tuesdays 19:00–21:30 in Berlin (CEST until 25 October).
const series = (startsAt, until, extra = {}) => ({ action: 'event.save', title: 'Probe', startsAt, endsAt: new Date(Date.parse(startsAt) + 150 * 60000).toISOString(), repeat: { every: 'week', until }, ...extra });
const berlin = iso => new Intl.DateTimeFormat('de-DE', { timeZone: 'Europe/Berlin', weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(iso));
const occurrences = (store, seriesId) => store.all('events').filter(e => e.seriesId === seriesId).sort((x, y) => x.startsAt.localeCompare(y.startsAt));
const edit = (store, id, extra) => { const e = store.get('events', id); return { action: 'event.save', id, version: e.version, title: e.title, description: e.description, startsAt: e.startsAt, endsAt: e.endsAt, place: e.place, type: e.type, roleIds: e.roleIds, personIds: e.personIds, productionIds: e.productionIds, ...extra }; };
const reject = (fn, status, message) => assert.throws(fn, e => e.status === status && (!message || message.test(e.message)));

test('new series keep their rhythm; managers see it, also inferred for older series', t => {
  const { store, app, action } = setup(t);
  assert.ok(apiFeatures.includes('seriesManage'));
  const { ids } = action(series('2026-09-15T17:00:00Z', '2026-10-13'));
  assert.ok(ids.every(id => JSON.stringify(store.get('events', id).seriesRepeat) === '{"every":"week","until":"2026-10-13"}'));
  // Older series lack the field: weekly with a deleted occurrence, fortnightly and monthly are recognised.
  const legacy = (seriesId, days) => days.forEach((d, i) => store.put('events', `${seriesId}-${i}`, { id: `${seriesId}-${i}`, title: seriesId, startsAt: `${d}T17:00:00.000Z`, endsAt: `${d}T19:00:00.000Z`, place: '', type: 'rehearsal', roleIds: [], personIds: [], productionIds: [], seriesId, version: 1 }));
  legacy('weekly', ['2026-09-15', '2026-09-22', '2026-10-06']);
  legacy('fortnight', ['2026-09-15', '2026-09-29', '2026-10-27']);
  legacy('monthly', ['2026-08-31', '2026-09-30', '2026-11-30', '2026-12-31']);
  legacy('irregular', ['2026-09-15', '2026-09-17', '2026-09-29']);
  legacy('single', ['2026-09-15']);
  const rhythm = (snapshot, seriesId) => snapshot.events.find(e => e.seriesId === seriesId).seriesRepeat;
  const admin = app.snapshot('admin');
  assert.deepEqual(['weekly', 'fortnight', 'monthly', 'irregular', 'single'].map(x => rhythm(admin, x)?.every ?? null), ['week', '2weeks', 'month', null, null]);
  assert.deepEqual(rhythm(admin, store.get('events', ids[0]).seriesId), { every: 'week', until: '2026-10-13' });
  assert.equal(rhythm(app.snapshot('sam'), 'weekly'), undefined, 'members get no inferred rhythm');
  assert.equal(seriesRhythm([{ startsAt: '2026-01-01T10:00:00Z' }, { startsAt: '2026-02-01T10:00:00Z', seriesRepeat: { every: '2weeks' } }]), '2weeks', 'a stored rhythm wins');
});

test('editing the whole series changes the upcoming occurrences only, each on its own day', t => {
  const { store, action } = setup(t);
  // 1 and 8 September have passed; 25 October switches to winter time.
  const { ids } = action(series('2026-09-01T17:00:00Z', '2026-10-27'));
  assert.equal(ids.length, 9);
  action(edit(store, ids[4], { title: 'Sonderprobe' }));
  action(edit(store, ids[5], { startsAt: '2026-10-07T16:00:00Z', endsAt: '2026-10-07T18:30:00Z' })); // Wednesday 18:00
  const before = ids.map(id => store.get('events', id));

  // Edited from a past occurrence, which stays as it is.
  const result = action(edit(store, ids[0], { place: 'Saal', startsAt: '2026-09-01T17:30:00Z', endsAt: '2026-09-01T20:00:00Z', series: 'all' }));
  assert.deepEqual(result.ids, ids.slice(2));
  assert.deepEqual([result.added, result.removed], [[], []]);
  const after = ids.map(id => store.get('events', id));
  assert.deepEqual(after.slice(0, 2), before.slice(0, 2), 'past occurrences are never changed');
  assert.ok(after.slice(2).every(e => e.place === 'Saal' && e.updatedBy != null));
  assert.equal(after[4].title, 'Sonderprobe', 'an own title survives a change of place and time');
  assert.deepEqual(after.slice(2).map(e => berlin(e.startsAt)), ['Di., 19:30', 'Di., 19:30', 'Di., 19:30', 'Mi., 19:30', 'Di., 19:30', 'Di., 19:30', 'Di., 19:30']);
  assert.ok(after.slice(2).every(e => berlin(e.endsAt).endsWith('22:00')));
  assert.deepEqual([after[7].startsAt, after[8].startsAt], ['2026-10-20T17:30:00.000Z', '2026-10-27T18:30:00.000Z']);

  // Only the end time changes: an own start time stays.
  action(edit(store, ids[3], { startsAt: '2026-09-22T16:00:00Z', endsAt: '2026-09-22T20:00:00Z' }));
  action(edit(store, ids[2], { endsAt: '2026-09-15T20:30:00Z', series: 'all' }));
  assert.deepEqual([berlin(store.get('events', ids[3]).startsAt), berlin(store.get('events', ids[3]).endsAt)], ['Di., 18:00', 'Di., 22:30']);
  assert.deepEqual([berlin(store.get('events', ids[8]).startsAt), berlin(store.get('events', ids[8]).endsAt)], ['Di., 19:30', 'Di., 22:30']);

  reject(() => action(edit(store, ids[2], { startsAt: '2026-09-16T17:30:00Z', endsAt: '2026-09-16T20:30:00Z', series: 'all' })), 400, /nur die Uhrzeit/);
  reject(() => action(edit(store, ids[2], { series: 'all', version: 99 })), 409);
  reject(() => action(edit(store, ids[2], { until: '2026-12-01' })), 400, /ganze Serie/);
  const single = action({ ...series('2026-09-15T17:00:00Z'), repeat: undefined }).id;
  reject(() => action(edit(store, single, { series: 'all' })), 400, /keiner Terminserie/);
});

test('a whole-series edit carries auto-accept and is announced once, only for a new time or place', t => {
  const { store, action, clear, sam } = setup(t);
  for (const uid of ['sam', 'kim']) store.put('devices', uid, { id: uid, uid, token: `token-${uid}`, platform: 'web' });
  const { ids } = action(series('2026-09-01T17:00:00Z', '2026-10-27', { personIds: [sam] }));
  action(edit(store, ids[3], { title: 'Sonderprobe' }));
  clear();
  const quiet = action(edit(store, ids[2], { autoAccept: true, description: 'Bitte pünktlich', series: 'all', push: true }));
  assert.deepEqual([quiet.ids.length, quiet.pushQueued, quiet.pushSkipped], [7, false, 'unchanged']);
  assert.deepEqual(ids.map(id => store.get('events', id).autoAccept === true), [false, false, true, true, true, true, true, true, true]);
  assert.equal(store.get('events', ids[3]).title, 'Sonderprobe');
  assert.deepEqual([store.all('pushJobs').length, store.all('emailJobs').length], [0, 0]);

  const moved = action(edit(store, ids[2], { place: 'Saal', series: 'all', push: true }));
  assert.deepEqual([moved.pushQueued, moved.pushSkipped], [true, null]);
  const jobs = store.all('pushJobs');
  assert.equal(jobs.length, 1);
  assert.deepEqual([jobs[0].title, jobs[0].body, jobs[0].announce, jobs[0].series.count], ['Terminserie geändert: Probe', 'Gilt für 7 Termine ab Di., 15.09.2026, 19:00 Uhr · Saal', 'changed', 7]);
});

test('a later end date extends the series in its rhythm, with one push and absence declines', t => {
  const { store, app, action, clear, kim } = setup(t);
  app.emailEnabled = true;
  action({ action: 'absence.create', from: '2026-10-27', to: '2026-10-27', reason: 'Urlaub' }, 'kim');
  const { ids } = action(series('2026-09-15T17:00:00Z', '2026-10-13', { personIds: [kim], place: 'Aula', autoAccept: true }));
  const seriesId = store.get('events', ids[0]).seriesId;
  clear();
  const result = action(edit(store, ids[1], { title: 'Probe', until: '2026-11-10', series: 'all', push: true }));
  assert.equal(result.added.length, 4);
  assert.deepEqual([result.pushQueued, result.pushSkipped], [true, null]);
  const added = result.added.map(id => store.get('events', id));
  assert.deepEqual(added.map(e => e.startsAt), ['2026-10-20T17:00:00.000Z', '2026-10-27T18:00:00.000Z', '2026-11-03T18:00:00.000Z', '2026-11-10T18:00:00.000Z']);
  assert.ok(added.every(e => e.seriesId === seriesId && e.place === 'Aula' && e.autoAccept === true && e.version === 1 && berlin(e.endsAt) === 'Di., 21:30'));
  assert.deepEqual(added[0].seriesRepeat, { every: 'week', until: '2026-11-10' });
  assert.deepEqual(added.map(e => store.get('responses', `${e.id}:${kim}`)?.status ?? null), [null, 'no', null, null]);
  assert.equal(occurrences(store, seriesId).length, 9);
  const jobs = store.all('pushJobs');
  assert.equal(jobs.length, 1, 'one summary push, the unchanged dates are not announced');
  assert.deepEqual([jobs[0].title, jobs[0].body, jobs[0].announce, jobs[0].series.count, jobs[0].data.eventId], ['Terminserie verlängert: Probe', '4 Termine, dienstags 19:00, ab 20.10.', 'new', 4, added[0].id]);

  // Without the push switch the extension is mailed once.
  clear();
  const quiet = action(edit(store, ids[1], { until: '2026-11-24', series: 'all' }));
  assert.deepEqual([quiet.added.length, quiet.pushQueued, store.all('pushJobs').length], [2, false, 0]);
  const [email, ...more] = store.all('emailJobs');
  assert.deepEqual(more, []);
  const mail = eventEmail(email, store.get('events', quiet.added[0]), 'https://app.example.com');
  assert.equal(mail.subject, 'Terminserie verlängert: Probe');
  assert.match(mail.text, /2 Termine, dienstags 19:00, ab 17\.11\. Erster neuer Termin: Di\., 17\.11\.2026, 19:00 Uhr/);
});

test('extensions are limited like new series and change nothing when rejected', t => {
  const { store, action } = setup(t);
  const { ids } = action(series('2026-09-15T17:00:00Z', '2026-10-13'));
  const count = store.all('events').length;
  reject(() => action(edit(store, ids[0], { until: '2027-10-14', series: 'all' })), 400, /höchstens ein Jahr/);
  reject(() => action(edit(store, ids[0], { until: '2026-10-19', series: 'all' })), 400, /kein Termin hinzu/);
  reject(() => action(edit(store, ids[0], { until: '2026-13-01', series: 'all' })), 400, /gültiges Enddatum/);
  reject(() => action(edit(store, ids[0], { place: 'Saal', until: '2027-10-14', series: 'all' })), 400);
  assert.equal(store.all('events').length, count);
  assert.ok(ids.every(id => store.get('events', id).version === 1 && store.get('events', id).place === ''), 'a rejected request keeps the edits out, too');
  // One year after the last occurrence holds 52 more Tuesdays.
  assert.equal(action(edit(store, ids[0], { until: '2027-10-13', series: 'all' })).added.length, 52);

  // Monthly series return to the 31st after a shorter month.
  const monthly = action({ ...series('2026-10-31T18:00:00Z', '2027-02-28'), repeat: { every: 'month', until: '2027-02-28' } });
  const extended = action(edit(store, monthly.ids[0], { until: '2027-04-30', series: 'all' }));
  assert.deepEqual(extended.added.map(id => store.get('events', id).startsAt), ['2027-03-31T17:00:00.000Z', '2027-04-30T17:00:00.000Z']);
});

test('older series extend by their inferred rhythm; without one they are only edited or ended', t => {
  const { store, action } = setup(t);
  const { ids } = action({ ...series('2026-09-15T17:00:00Z', '2026-10-13'), repeat: { every: '2weeks', until: '2026-10-13' } });
  for (const id of ids) { const { seriesRepeat, ...rest } = store.get('events', id); store.put('events', id, rest); }
  const extended = action(edit(store, ids[0], { until: '2026-11-10', series: 'all' }));
  assert.deepEqual(extended.added.map(id => store.get('events', id).startsAt.slice(0, 10)), ['2026-10-27', '2026-11-10']);
  assert.equal(store.get('events', extended.added[0]).seriesRepeat.every, '2weeks');

  for (const [i, d] of ['2026-09-15', '2026-09-17', '2026-09-29'].entries()) store.put('events', `odd-${i}`, { id: `odd-${i}`, title: 'Odd', startsAt: `${d}T17:00:00.000Z`, endsAt: `${d}T19:00:00.000Z`, place: '', type: 'rehearsal', roleIds: [], personIds: [], productionIds: [], seriesId: 'odd', version: 1 });
  reject(() => action(edit(store, 'odd-0', { until: '2026-10-31', series: 'all' })), 400, /Rhythmus/);
  assert.deepEqual(action(edit(store, 'odd-0', { place: 'Saal', series: 'all' })).ids, ['odd-0', 'odd-1', 'odd-2']);
  assert.deepEqual(action(edit(store, 'odd-0', { until: '2026-09-17', series: 'all' })).removed, ['odd-2']);
});

test('an earlier end date ends the series there with the usual cancellation notices', t => {
  const { store, app, action, clear, sam, kim, leo } = setup(t);
  app.emailEnabled = true;
  const { ids } = action(series('2026-09-15T17:00:00Z', '2026-12-01'));
  action({ action: 'attendance', eventId: ids[8], status: 'no', reason: 'Krank' }, 'kim');
  clear();
  reject(() => action(edit(store, ids[2], { until: '2026-09-22', series: 'all' })), 400, /nicht vor diesem Termin/);
  const result = action(edit(store, ids[2], { until: '2026-10-20', series: 'all' }));
  assert.deepEqual(result.removed, ids.slice(6));
  assert.deepEqual(result.ids, [ids[2]], 'without other changes only the edited occurrence is saved');
  assert.deepEqual(occurrences(store, store.get('events', ids[0]).seriesId).map(e => e.id), ids.slice(0, 6));
  assert.equal(store.get('responses', `${ids[8]}:${kim}`), null);
  const emails = store.all('emailJobs');
  assert.deepEqual(emails.map(j => [j.cancelled, j.seriesCount, j.event.id]), [[true, 6, ids[6]]]);
  assert.deepEqual(store.all('pushJobs').map(j => [j.title, j.body, j.recipientPersonIds.sort()]), [['Termine abgesagt: Probe', '6 Termine entfallen, ab Di., 27.10.2026, 19:00 Uhr', [sam, kim, leo].sort()]]);

  // Started occurrences stay: no end before them, also when edited from a past one.
  const past = action(series('2026-09-01T17:00:00Z', '2026-10-27'));
  reject(() => action(edit(store, past.ids[0], { until: '2026-09-01', series: 'all' })), 400, /Begonnene Termine/);
  assert.deepEqual(action(edit(store, past.ids[0], { until: '2026-09-08', series: 'all' })).removed, past.ids.slice(2));
});

test('only those who manage events change a whole series', t => {
  const { store, action, leo } = setup(t);
  const { ids } = action(series('2026-09-15T17:00:00Z', '2026-10-13'));
  reject(() => action(edit(store, ids[0], { place: 'Saal', until: '2026-10-27', series: 'all' }), 'sam'), 403);
  assert.equal(store.all('events').length, ids.length);
  action({ action: 'account.permissions', uid: 'leo', permissions: ['events'], version: store.account('leo').version });
  const result = action(edit(store, ids[0], { place: 'Saal', until: '2026-10-27', series: 'all' }), 'leo');
  assert.deepEqual([result.ids.length, result.added.length], [5, 2]);
  assert.deepEqual([store.get('events', result.added[0]).createdBy, store.get('events', ids[3]).updatedBy, store.get('events', result.added[1]).place], [leo, leo, 'Saal']);
});
