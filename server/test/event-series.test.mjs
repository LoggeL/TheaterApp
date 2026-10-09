import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { deliverPush } from '../src/push.mjs';
import { eventEmail } from '../src/email.mjs';

const now = new Date('2026-09-12T12:00:00Z');
function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.com', pushEnabled: true, clock: () => now });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.com', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `test-${++sequence}`);
  const person = (uid, name, roleIds = []) => {
    const id = action({ action: 'member.save', name, roleIds }).id;
    app.session({ uid, name, email: `${uid}@example.com`, email_verified: true });
    action({ action: 'account.approve', uid, personId: id, version: 1, role: 'member' });
    return id;
  };
  const people = { sam: person('sam', 'Sam'), tech: person('tech', 'Toni', ['role-3']), kim: person('kim', 'Kim') };
  for (const j of store.all('pushJobs')) store.delete('pushJobs', j.id); // registration notices
  return { store, app, action, ...people };
}
// Tuesday, 15 September 2026, 19:00–21:30 in Berlin (CEST).
const series = (repeat, extra = {}) => ({ action: 'event.save', title: 'Probe', startsAt: '2026-09-15T17:00:00Z', endsAt: '2026-09-15T19:30:00Z', repeat, ...extra });
const berlin = iso => new Intl.DateTimeFormat('de-DE', { timeZone: 'Europe/Berlin', weekday: 'short', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(iso));
const seriesEvents = (store, seriesId) => store.all('events').filter(e => e.seriesId === seriesId).sort((x, y) => x.startsAt.localeCompare(y.startsAt));

test('a weekly series keeps the Berlin wall-clock time across the October switch', t => {
  const { app, store, action } = setup(t);
  const result = action(series({ every: 'week', until: '2026-12-01' }));
  assert.equal(result.ids.length, 12);
  assert.equal(result.id, result.ids[0]);
  const events = seriesEvents(store, store.get('events', result.id).seriesId);
  assert.deepEqual(events.map(e => e.id), result.ids);
  assert.ok(events.every(e => berlin(e.startsAt) === 'Di., 19:00' && berlin(e.endsAt) === 'Di., 21:30'));
  assert.deepEqual(events.slice(5, 7).map(e => [e.startsAt, e.endsAt]), [
    ['2026-10-20T17:00:00.000Z', '2026-10-20T19:30:00.000Z'],
    ['2026-10-27T18:00:00.000Z', '2026-10-27T20:30:00.000Z'],
  ]);
  assert.equal(events.at(-1).startsAt, '2026-12-01T18:00:00.000Z');
  assert.ok(events.every(e => e.title === 'Probe' && e.version === 1));
  assert.equal(app.snapshot('sam').events.find(e => e.id === result.ids[3]).seriesId, events[0].seriesId);
});

test('fortnightly and monthly series', t => {
  const { store, action } = setup(t);
  const fortnight = action(series({ every: '2weeks', until: '2026-10-13' }));
  assert.deepEqual(fortnight.ids.map(id => store.get('events', id).startsAt.slice(0, 10)), ['2026-09-15', '2026-09-29', '2026-10-13']);
  // The 31st falls back to the last day of shorter months; winter time keeps 19:00.
  const monthly = action(series({ every: 'month', until: '2027-02-28' }, { startsAt: '2026-10-31T18:00:00Z', endsAt: '2026-10-31T20:00:00Z' }));
  assert.deepEqual(monthly.ids.map(id => store.get('events', id).startsAt), ['2026-10-31T18:00:00.000Z', '2026-11-30T18:00:00.000Z', '2026-12-31T18:00:00.000Z', '2027-01-31T18:00:00.000Z', '2027-02-28T18:00:00.000Z']);
});

test('series are validated and capped', t => {
  const { store, action } = setup(t);
  const reject = (body, message) => assert.throws(() => action(body), e => e.status === 400 && message.test(e.message));
  reject(series({ every: 'week', until: '2026-09-14' }), /vor dem ersten Termin/);
  reject(series({ every: 'week', until: '2027-09-16' }), /höchstens ein Jahr/);
  reject(series({ every: 'week', until: '2027-09-14' }), /höchstens 52 Termine/); // 53 Tuesdays
  reject(series({ every: 'week', until: '2026-09-21' }), /nur ein Termin/);
  reject(series({ every: 'day', until: '2026-10-01' }), /wöchentlich/);
  reject(series({ every: 'week', until: '2026-02-30' }), /gültiges Enddatum/);
  reject(series({ every: 'week' }), /gültiges Enddatum/);
  reject(series('weekly'), /Ungültige Wiederholung/);
  assert.equal(store.all('events').length, 0, 'nothing is created for a rejected series');
  assert.equal(action(series({ every: 'week', until: '2027-09-13' })).ids.length, 52);
  // A repetition belongs to new events only.
  const single = action(series(undefined));
  reject(series({ every: 'week', until: '2026-10-01' }, { id: single.id, version: 1 }), /beim Anlegen/);
});

test('a series is announced with a single push and a single email', async t => {
  const { app, store, action, sam } = setup(t);
  for (const uid of ['admin', 'sam', 'tech', 'kim']) store.put('devices', uid, { id: uid, uid, token: `token-${uid}`, platform: uid === 'sam' ? 'android' : 'web', notificationActions: uid === 'sam' });
  app.emailEnabled = true;
  const quiet = action(series({ every: 'week', until: '2026-12-01' }, { roleIds: ['role-3'], personIds: [sam] }));
  assert.equal(quiet.pushQueued, false);
  assert.equal(store.all('pushJobs').length, 0);
  assert.equal(store.all('emailJobs').length, 1, 'one email job instead of one per occurrence');
  for (const j of store.all('emailJobs')) store.delete('emailJobs', j.id);

  const result = action(series({ every: 'week', until: '2026-12-01' }, { roleIds: ['role-3'], personIds: [sam], push: true }));
  assert.equal(result.pushQueued, true);
  const jobs = store.all('pushJobs');
  assert.equal(jobs.length, 1);
  assert.deepEqual([jobs[0].title, jobs[0].body, jobs[0].roleIds, jobs[0].personIds, jobs[0].data, jobs[0].announce, jobs[0].series.count], ['Neue Terminserie: Probe', '12 Termine, dienstags 19:00, ab 15.9.', ['role-3'], [sam], { eventId: result.id }, 'new', 12]);
  const [email] = store.all('emailJobs');
  assert.equal(store.all('emailJobs').length, 1);
  const message = eventEmail(email, store.get('events', result.id), 'https://app.example.com');
  assert.equal(message.subject, 'Neue Terminserie: Probe');
  assert.match(message.text, /12 Termine, dienstags 19:00, ab 15\.9\. Erster Termin: Di\., 15\.09\.2026, 19:00 Uhr/);

  const calls = [];
  await deliverPush({ pushEnabled: true, store }, { sendEachForMulticast: async p => { calls.push(p); return { responses: p.tokens.map(() => ({ success: true })) }; } });
  assert.deepEqual(calls.flatMap(p => p.tokens).sort(), ['token-sam', 'token-tech']);
  const web = calls.find(p => p.notification), android = calls.find(p => !p.notification);
  assert.deepEqual(web.notification, { title: 'Neue Terminserie: Probe', body: '12 Termine, dienstags 19:00, ab 15.9.' });
  assert.equal(android.data.title, 'Neue Terminserie: Probe');
  assert.equal(android.data.attendanceActions, undefined, 'no quick answer for a whole series');
});

test('absences decline each occurrence they cover', t => {
  const { store, action, sam, kim } = setup(t);
  action({ action: 'absence.create', from: '2026-09-22', to: '2026-09-29', reason: 'Urlaub' }, 'sam');
  const { ids } = action(series({ every: 'week', until: '2026-10-13' }, { personIds: [sam, kim] }));
  assert.deepEqual(ids.map(id => store.get('responses', `${id}:${sam}`)?.status ?? null), [null, 'no', 'no', null, null]);
  assert.equal(store.get('responses', `${ids[1]}:${sam}`).reason, 'Urlaub');
  assert.ok(ids.every(id => !store.get('responses', `${id}:${kim}`)));
});

test('deleting this and all following occurrences of a series', t => {
  const { app, store, action, sam } = setup(t);
  app.emailEnabled = true;
  const { ids } = action(series({ every: 'week', until: '2026-12-01' }));
  const other = action(series({ every: 'week', until: '2026-10-06' }, { title: 'Andere' }));
  action({ action: 'attendance', eventId: ids[5], status: 'yes' }, 'sam');
  action({ action: 'checkin.save', eventId: ids[5], members: [{ id: sam, present: true }] });
  const moved = store.get('events', ids[7]);
  action(series(undefined, { id: ids[7], version: 1, title: 'Umbenannt', startsAt: moved.startsAt, endsAt: moved.endsAt }));
  for (const j of store.all('emailJobs')) store.delete('emailJobs', j.id);

  assert.throws(() => action({ action: 'event.delete', id: ids[3], version: 2, series: 'following' }), { status: 409 });
  assert.throws(() => action({ action: 'event.delete', id: ids[3], version: 1, series: 'all' }), { status: 400 });
  const removed = action({ action: 'event.delete', id: ids[3], version: 1, series: 'following' });
  assert.deepEqual(removed.ids, ids.slice(3));
  assert.deepEqual(seriesEvents(store, store.get('events', ids[0]).seriesId).map(e => e.id), ids.slice(0, 3));
  assert.equal(store.get('events', ids[7]), null, 'an edited occurrence still belongs to the series');
  assert.equal(store.get('responses', `${ids[5]}:${sam}`), null);
  assert.equal(store.get('checkins', `${ids[5]}:${sam}`), null);
  assert.equal(other.ids.every(id => store.get('events', id)), true, 'other series stay');
  const emails = store.all('emailJobs');
  assert.equal(emails.length, 1, 'one cancellation email for the series');
  assert.deepEqual([emails[0].cancelled, emails[0].seriesCount, emails[0].event.id], [true, 9, ids[3]]);
  assert.equal(eventEmail(emails[0], emails[0].event, 'https://app.example.com').subject, 'Termine abgesagt: Probe');

  // Without the choice only the one occurrence goes.
  assert.deepEqual(action({ action: 'event.delete', id: ids[1], version: 1 }).ids, [ids[1]]);
  assert.deepEqual(seriesEvents(store, store.get('events', ids[0]).seriesId).map(e => e.id), [ids[0], ids[2]]);
});
