import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures, cancelReasonMaxLength } from '../src/theater.mjs';
import { deliverPush, scheduleReminders } from '../src/push.mjs';
import { deliverEmail } from '../src/email.mjs';
import { calendarFeedLines } from '../src/calendar-feed.mjs';
import { settleAttendance } from '../src/runner-event-crates.mjs';

// "Termin absagen" (`event.cancel`): the event stays as cancelled, who committed hears of it by push.
const hour = 3600000;
function setup(t, { pushEnabled = true, emailEnabled = false } = {}) {
  const store = new Store(); t.after(() => store.close());
  // Delivery compares with the real time, so the clock starts now.
  const clock = { now: new Date(Math.floor(Date.now() / 60000) * 60000) };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.com', pushEnabled, emailEnabled, clock: () => clock.now, missionRules: null });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.com', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `cancel-${++sequence}`);
  const person = (uid, name) => {
    const id = action({ action: 'member.save', name }).id;
    app.session({ uid, name, email: `${uid}@example.com`, email_verified: true });
    action({ action: 'account.approve', uid, personId: id, version: 1, role: 'member' });
    store.put('devices', uid, { id: uid, uid, token: `token-${uid}`, platform: 'web' });
    return id;
  };
  const sam = person('sam', 'Sam'), kim = person('kim', 'Kim'), lou = person('lou', 'Lou'), pia = person('pia', 'Pia'), admin = store.account('admin').personId;
  const at = hours => new Date(+clock.now + hours * hour).toISOString();
  const event = (hours = 30, extra = {}) => action({ action: 'event.save', title: 'Probe', startsAt: at(hours), endsAt: at(hours + 2), place: 'Saal', personIds: [sam, kim, lou, pia], ...extra }).id;
  const clear = () => { for (const kind of ['pushJobs', 'emailJobs']) for (const j of store.all(kind)) store.delete(kind, j.id); };
  clear();
  const respond = (eventId, uid, status) => action({ action: 'attendance', eventId, status, ...(status === 'no' ? { reason: 'Krank' } : {}) }, uid);
  const cancel = (id, extra = {}, uid = 'admin') => action({ action: 'event.cancel', id, version: store.get('events', id).version, ...extra }, uid);
  const deliver = async () => {
    const sent = [];
    await deliverPush(app, { sendEachForMulticast: async p => { sent.push(p); return { responses: p.tokens.map(() => ({ success: true })) }; } }, 'https://app.example.com');
    return sent;
  };
  return { store, app, clock, action, sam, kim, lou, pia, admin, at, event, clear, respond, cancel, deliver };
}

test('the server announces event cancellation', () => {
  assert.ok(apiFeatures.includes('eventCancel'));
});

test('a cancelled event stays, marked with time, reason and who called it off', t => {
  const { store, app, event, cancel, admin } = setup(t);
  const id = event();
  const result = cancel(id, { reason: '  Saal\n belegt  ' });
  assert.equal(result.id, id);
  const e = store.get('events', id);
  assert.equal(e.cancelledAt, app.clock().toISOString());
  assert.equal(e.cancelReason, 'Saal belegt');
  assert.equal(e.cancelledBy, admin);
  assert.equal(e.version, 2);
  const seen = app.snapshot('sam').events.find(x => x.id === id);
  assert.equal(seen.cancelledAt, e.cancelledAt);
  assert.equal(seen.cancelReason, 'Saal belegt');
});

test('only those managing events cancel and withdraw, with the current version', t => {
  const { store, action, event, cancel } = setup(t);
  const id = event();
  assert.throws(() => cancel(id, {}, 'sam'), { status: 403 });
  assert.throws(() => action({ action: 'event.cancel', id, version: 7 }), { status: 409, code: 'version_conflict' });
  assert.throws(() => action({ action: 'event.cancel', id: 'missing', version: 1 }), { status: 404 });
  // A holder of the events right ("Termine verwalten") may.
  action({ action: 'account.permissions', uid: 'kim', permissions: ['events'], version: store.account('kim').version });
  cancel(id, {}, 'kim');
  assert.ok(store.get('events', id).cancelledAt);
  assert.throws(() => cancel(id), { status: 409, code: 'closed' });
  assert.throws(() => action({ action: 'event.uncancel', id, version: store.get('events', id).version }, 'sam'), { status: 403 });
  assert.throws(() => action({ action: 'event.uncancel', id, version: 1 }), { status: 409, code: 'version_conflict' });
  action({ action: 'event.uncancel', id, version: store.get('events', id).version }, 'kim');
  assert.equal(store.get('events', id).cancelledAt, undefined);
  assert.throws(() => action({ action: 'event.uncancel', id, version: store.get('events', id).version }), { status: 409, code: 'closed' });
});

test('past, Terminfinder and overlong reasons are refused', t => {
  const { store, action, event, cancel, at } = setup(t);
  const past = action({ action: 'event.save', title: 'Alt', startsAt: at(-5), endsAt: at(-3) }).id;
  assert.throws(() => cancel(past), { status: 409, code: 'closed' });
  // A running event can still be called off.
  const running = action({ action: 'event.save', title: 'Läuft', startsAt: at(-1), endsAt: at(1) }).id;
  cancel(running);
  store.put('events', 'slot', { id: 'slot', title: 'Gespräch', startsAt: at(5), endsAt: at(6), slotPoolId: 'pool', version: 1 });
  assert.throws(() => cancel('slot'), { status: 409, code: 'closed' });
  const id = event();
  assert.throws(() => cancel(id, { reason: 'x'.repeat(cancelReasonMaxLength + 1) }), { status: 400 });
  assert.throws(() => cancel(id, { reason: 42 }), { status: 400 });
  assert.equal(store.get('events', id).cancelledAt, undefined);
});

test('the push reaches exactly who accepted, not open, declined or the canceller', async t => {
  const { store, event, respond, cancel, deliver, sam, kim, lou, pia, admin } = setup(t);
  const id = event(30, { personIds: [sam, kim, lou, pia, admin] });
  respond(id, 'sam', 'yes'); respond(id, 'kim', 'late'); respond(id, 'lou', 'no');
  respond(id, 'admin', 'yes');
  const result = cancel(id, { reason: 'Saal belegt' });
  assert.deepEqual([result.recipients, result.pushQueued, result.pushSkipped], [2, true, null]);
  const [job] = store.all('pushJobs');
  assert.deepEqual(job.recipientPersonIds.sort(), [sam, kim].sort());
  assert.equal(job.pushKind, 'changes');
  assert.deepEqual(job.data, { eventId: id });
  const sent = await deliver();
  assert.deepEqual(sent.flatMap(p => p.tokens).sort(), ['token-kim', 'token-sam']);
  assert.equal(sent[0].notification.title, 'Termin abgesagt: Probe');
  assert.match(sent[0].notification.body, / · Saal · Grund: Saal belegt$/);
  assert.deepEqual(sent[0].data, { eventId: id });
  assert.match(sent[0].webpush.fcmOptions.link, /events%2F/);
});

test('on auto-accepted events everyone invited who did not decline hears of it', t => {
  const { store, event, respond, cancel, sam, kim, pia } = setup(t);
  const id = event(30, { autoAccept: true });
  respond(id, 'sam', 'yes'); respond(id, 'lou', 'no');
  // An absence on the day counts as a decline, too.
  const day = new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Berlin' }).format(new Date(store.get('events', id).startsAt));
  store.put('absences', 'away', { id: 'away', personId: pia, from: day, to: day, reason: 'Urlaub' });
  cancel(id);
  const [job] = store.all('pushJobs');
  assert.deepEqual(job.recipientPersonIds.sort(), [sam, kim].sort());
});

test('nobody committed: nothing is queued; without push the answer says so', t => {
  const quiet = setup(t);
  const id = quiet.event();
  quiet.respond(id, 'sam', 'no');
  assert.deepEqual([quiet.cancel(id).pushQueued, quiet.store.all('pushJobs').length], [false, 0]);
  const off = setup(t, { pushEnabled: false });
  const other = off.event();
  off.respond(other, 'sam', 'yes');
  const result = off.cancel(other);
  assert.deepEqual([result.pushQueued, result.pushSkipped, result.recipients], [false, 'disabled', 1]);
  assert.equal(off.store.all('pushJobs').length, 0);
});

test('answers, open reminders and check-ins are closed after a cancellation', t => {
  const { store, action, event, respond, cancel } = setup(t);
  const id = event();
  respond(id, 'sam', 'yes');
  cancel(id);
  assert.throws(() => respond(id, 'kim', 'yes'), { status: 409, code: 'closed' });
  assert.throws(() => respond(id, 'sam', 'no'), { status: 409, code: 'closed' });
  assert.throws(() => action({ action: 'event.remindOpen', eventId: id }), { status: 409, code: 'closed' });
  assert.throws(() => action({ action: 'checkin.save', eventId: id, members: [{ id: store.account('sam').personId, present: true }] }), { status: 409, code: 'closed' });
  // The own yes stays for a later withdrawal of the cancellation.
  assert.equal(store.get('responses', `${id}:${store.account('sam').personId}`).status, 'yes');
  // A new absence leaves the cancelled event alone.
  assert.deepEqual(action({ action: 'absence.create', from: '2020-01-01', to: '2099-12-31', reason: 'Weg' }, 'kim').declinedEventIds, []);
});

test('no reminders, no "Du bist eingeplant" and no queued pushes or emails after a cancellation', async t => {
  const { store, app, clock, action, event, respond, cancel, clear, deliver } = setup(t, { emailEnabled: true });
  for (const uid of ['sam', 'kim']) action({ action: 'settings.reminders', value: { dayBefore: true, twoHours: true, changes: true } }, uid);
  store.put('settings', 'eventCratesSince', { at: new Date(0).toISOString() });
  const id = event(20, { autoAccept: true });
  respond(id, 'sam', 'yes');
  clear();
  // A change push queued before the cancellation becomes obsolete.
  app.enqueuePush({ title: 'Probe', body: '', data: { eventId: id }, recipientPersonIds: [store.account('sam').personId] });
  const before = store.all('pushJobs').map(j => j.id);
  cancel(id);
  scheduleReminders(app, clock.now);
  assert.equal(store.all('pushJobs').filter(j => !before.includes(j.id) && !j.cancelledAt).length, 0);
  assert.equal(store.all('pushJobs').filter(j => j.planned).length, 0);
  const sent = await deliver();
  assert.deepEqual(sent.map(p => p.notification.title), ['Termin abgesagt: Probe']);
  assert.equal(store.get('pushJobs', before[0]).status, 'obsolete');
  // Attendance is neither adopted nor asked for after the end.
  clock.now = new Date(Date.parse(store.get('events', id).endsAt) + 30 * hour);
  settleAttendance(app, clock.now);
  assert.equal(store.all('checkins').length, 0);
  assert.equal(store.all('pushJobs').filter(j => j.pushKind === 'attendanceCheckin').length, 0);
});

test('the cancellation email goes to the same people and names the reason', async t => {
  const { store, app, event, respond, cancel } = setup(t, { pushEnabled: false, emailEnabled: true });
  for (const uid of ['sam', 'kim']) store.put('reminders', store.account(uid).personId, { emailEnabled: true, changes: true });
  const id = event();
  respond(id, 'sam', 'yes');
  cancel(id, { reason: 'Saal belegt' });
  const sent = [], email = { configured: true, send: async value => { sent.push(value); return 'id'; } };
  await deliverEmail(app, email, 'https://app.example.com');
  assert.deepEqual(sent.map(x => x.to), ['sam@example.com']);
  assert.equal(sent[0].subject, 'Termin abgesagt: Probe');
  assert.match(sent[0].text, /Grund: Saal belegt/);
});

test('withdrawing the cancellation is silent and reopens answers', async t => {
  const { store, app, clock, action, event, respond, cancel, deliver } = setup(t);
  const id = event(20, { autoAccept: true });
  respond(id, 'sam', 'yes');
  cancel(id);
  // Withdrawn before delivery: the cancellation push lapses.
  const result = action({ action: 'event.uncancel', id, version: store.get('events', id).version });
  assert.equal(result.id, id);
  const e = store.get('events', id);
  assert.deepEqual([e.cancelledAt, e.cancelReason, e.cancelledBy, e.version], [undefined, undefined, undefined, 3]);
  assert.equal((await deliver()).length, 0);
  assert.ok(store.all('pushJobs').every(j => j.status === 'obsolete'));
  const jobs = store.all('pushJobs').length;
  // No "Du bist eingeplant" right away either.
  scheduleReminders(app, clock.now);
  assert.equal(store.all('pushJobs').filter(j => j.planned).length, 0);
  assert.equal(store.all('pushJobs').length, jobs);
  respond(id, 'kim', 'no');
  assert.equal(store.get('responses', `${id}:${store.account('kim').personId}`).status, 'no');
});

test('editing a cancelled event keeps it cancelled and quiet; deleting it sends nothing more', t => {
  const { store, action, event, respond, cancel, clear } = setup(t);
  const id = event();
  respond(id, 'sam', 'yes');
  cancel(id, { reason: 'Saal belegt' });
  clear();
  const e = store.get('events', id);
  const saved = action({ action: 'event.save', id, version: e.version, title: 'Probe', startsAt: e.startsAt, endsAt: e.endsAt, place: 'Bühne', personIds: e.personIds, push: true });
  assert.equal(saved.pushQueued, false);
  const after = store.get('events', id);
  assert.deepEqual([after.cancelledAt, after.cancelReason, after.place], [e.cancelledAt, 'Saal belegt', 'Bühne']);
  assert.equal(store.all('pushJobs').length, 0);
  action({ action: 'event.delete', id, version: after.version });
  assert.equal(store.all('pushJobs').length, 0);
  assert.equal(store.get('events', id), null);
});

test('only this occurrence of a series is cancelled', t => {
  const { store, action, at, cancel } = setup(t);
  const { ids } = action({ action: 'event.save', title: 'Serie', startsAt: at(30), endsAt: at(32), repeat: { every: 'week', until: new Date(Date.parse(at(30)) + 20 * 86400000).toISOString().slice(0, 10) } });
  assert.ok(ids.length >= 3);
  cancel(ids[1]);
  assert.deepEqual(ids.map(x => !!store.get('events', x).cancelledAt), ids.map((_, i) => i === 1));
});

test('the calendar feed and participation treat a cancelled event as called off', t => {
  const { app, clock, event, respond, cancel, sam } = setup(t);
  const id = event();
  respond(id, 'sam', 'yes');
  cancel(id, { reason: 'Saal belegt' });
  const lines = calendarFeedLines(app, sam).join('\n');
  assert.match(lines, /SUMMARY:Abgesagt: Probe/);
  assert.match(lines, /STATUS:CANCELLED/);
  assert.match(lines, /Grund: Saal belegt/);
  clock.now = new Date(+clock.now + 40 * hour);
  assert.equal(app.participation('sam').own.events, 0);
});
