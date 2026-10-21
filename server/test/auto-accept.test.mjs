import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures, implicitYes } from '../src/theater.mjs';
import { deliverPush, plannedReminderLeadMs, scheduleReminders } from '../src/push.mjs';
import { calendarFeedEvents } from '../src/calendar-feed.mjs';

// "Alle gelten als zugesagt": invitees without an own answer attend unless they decline.
const hour = 3600000;
const berlinDay = value => new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Berlin' }).format(new Date(value));
function setup(t, { pushEnabled = true, emailEnabled = false } = {}) {
  const store = new Store(); t.after(() => store.close());
  // Delivery compares with the real time, so the clock starts now.
  const clock = { now: new Date(Math.floor(Date.now() / 60000) * 60000) };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.com', pushEnabled, emailEnabled, clock: () => clock.now });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.com', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `auto-${++sequence}`);
  const person = (uid, name) => {
    const id = action({ action: 'member.save', name }).id;
    app.session({ uid, name, email: `${uid}@example.com`, email_verified: true });
    action({ action: 'account.approve', uid, personId: id, version: 1, role: 'member' });
    store.put('devices', uid, { id: uid, uid, token: `token-${uid}`, platform: 'web' });
    return id;
  };
  const sam = person('sam', 'Sam'), kim = person('kim', 'Kim'), lou = person('lou', 'Lou'), admin = store.account('admin').personId;
  const at = hours => new Date(+clock.now + hours * hour).toISOString();
  const event = (hours = 100, extra = {}) => action({ action: 'event.save', title: 'Probe', startsAt: at(hours), endsAt: at(hours + 2), place: 'Saal', personIds: [sam, kim, lou], autoAccept: true, ...extra }).id;
  const clear = () => { for (const kind of ['pushJobs', 'emailJobs']) for (const j of store.all(kind)) store.delete(kind, j.id); };
  clear();
  const respond = (eventId, personId, status) => store.put('responses', `${eventId}:${personId}`, { eventId, personId, status, reason: '', expectedArrivalAt: null, updatedAt: clock.now.toISOString() });
  const absent = (personId, startsAt, id = `abs-${personId}`) => store.put('absences', id, { id, personId, from: berlinDay(startsAt), to: berlinDay(startsAt), reason: 'Urlaub' });
  const planned = () => store.all('pushJobs').filter(j => j.planned);
  const deliver = async () => {
    const sent = [];
    await deliverPush(app, { sendEachForMulticast: async p => { sent.push(p); return { responses: p.tokens.map(() => ({ success: true })) }; } }, 'https://app.example.com');
    return sent;
  };
  return { store, app, clock, action, sam, kim, lou, admin, at, event, clear, respond, absent, planned, deliver };
}

test('the server announces auto-accept', () => {
  assert.ok(apiFeatures.includes('autoAccept'));
});

test('auto-accept is a validated boolean that older clients keep', t => {
  const { store, action, event } = setup(t);
  const plain = action({ action: 'event.save', title: 'Probe', startsAt: '2027-01-10T17:00:00Z', endsAt: '2027-01-10T19:00:00Z' }).id;
  assert.equal(store.get('events', plain).autoAccept, false);
  const id = event();
  assert.equal(store.get('events', id).autoAccept, true);
  // An older app saves without the field: the switch stays on.
  const old = store.get('events', id);
  action({ action: 'event.save', id, title: 'Probe neu', startsAt: old.startsAt, endsAt: old.endsAt, version: 1 });
  assert.equal(store.get('events', id).autoAccept, true);
  assert.throws(() => action({ action: 'event.save', id, title: 'Probe', startsAt: old.startsAt, endsAt: old.endsAt, version: 2, autoAccept: 'ja' }), { status: 400, message: /Alle gelten als zugesagt/ });
  action({ action: 'event.save', id, title: 'Probe', startsAt: old.startsAt, endsAt: old.endsAt, version: 2, autoAccept: false });
  assert.equal(store.get('events', id).autoAccept, false);
});

test('series pass auto-accept on, and "this and following" toggles it silently', t => {
  const { store, app, action, at } = setup(t, { emailEnabled: true });
  const result = action({ action: 'event.save', title: 'Probe', startsAt: at(100), endsAt: at(102), autoAccept: true, repeat: { every: 'week', until: berlinDay(at(100 + 3 * 7 * 24)) } });
  assert.equal(result.ids.length, 4);
  assert.ok(result.ids.every(x => store.get('events', x).autoAccept === true));
  for (const kind of ['pushJobs', 'emailJobs']) for (const j of store.all(kind)) store.delete(kind, j.id);
  const second = store.get('events', result.ids[1]);
  const saved = action({ action: 'event.save', id: second.id, title: 'Probe', startsAt: second.startsAt, endsAt: second.endsAt, version: second.version, autoAccept: false, series: 'following', push: true });
  assert.deepEqual(result.ids.map(x => store.get('events', x).autoAccept), [true, false, false, false]);
  assert.equal(saved.pushSkipped, 'unchanged');
  assert.equal(store.all('pushJobs').length, 0);
  assert.equal(store.all('emailJobs').length, 0);
  // A legacy occurrence without the field equals one switched off: nothing to take over.
  const first = store.get('events', result.ids[0]);
  const { autoAccept, ...legacy } = { ...first, autoAccept: undefined };
  assert.equal(autoAccept, undefined);
  assert.deepEqual(app.seriesFollowers(legacy, { ...legacy, autoAccept: false }), []);
});

test('the snapshot counts implicit attendees; a decline and an absence end the implicit yes', t => {
  const { store, app, action, sam, kim, lou, event, respond, absent } = setup(t);
  const id = event();
  respond(id, kim, 'no');
  let view = app.snapshot('sam').events.find(e => e.id === id);
  assert.deepEqual([view.autoAccept, view.people, view.implicitPeople, view.implicitYes], [true, 2, 2, true]);
  assert.equal(app.snapshot('kim').events.find(e => e.id === id).implicitYes, false);
  assert.deepEqual(app.snapshot('sam').implicitAttendanceByEvent, {}, 'only leaders see who attends implicitly');
  const lead = app.snapshot('admin');
  assert.deepEqual(lead.implicitAttendanceByEvent[id].sort(), [sam, lou].sort());
  assert.deepEqual(lead.memberAttendanceByEvent[id], { [kim]: 'no' }, 'older apps never see a made-up answer');
  // A withdrawn answer counts as none: implicit again.
  respond(id, kim, 'open');
  assert.equal(app.snapshot('kim').events.find(e => e.id === id).implicitYes, true);
  // An explicit yes is counted once.
  respond(id, sam, 'yes');
  view = app.snapshot('sam').events.find(e => e.id === id);
  assert.deepEqual([view.people, view.implicitPeople, view.implicitYes], [3, 2, false]);
  // An absence declines through absence.create; deleting it with reopen restores the implicit yes.
  const absence = action({ action: 'absence.create', from: berlinDay(store.get('events', id).startsAt), to: berlinDay(store.get('events', id).startsAt), reason: 'Urlaub' }, 'lou');
  assert.ok(absence.declinedEventIds.includes(id));
  assert.equal(app.snapshot('lou').events.find(e => e.id === id).implicitYes, false);
  action({ action: 'absence.delete', id: absence.id, reopen: true }, 'lou');
  assert.equal(app.snapshot('lou').events.find(e => e.id === id).implicitYes, true);
  // A covering absence without a decline row still cancels the implicit yes.
  absent(lou, store.get('events', id).startsAt);
  assert.equal(app.snapshot('lou').events.find(e => e.id === id).implicitYes, false);
  // Without auto-accept nobody attends implicitly and no fields are added.
  const plain = event(120, { autoAccept: false });
  view = app.snapshot('sam').events.find(e => e.id === plain);
  assert.deepEqual([view.people, 'implicitYes' in view, 'implicitPeople' in view], [0, false, false]);
});

test('saving an auto-accepted event declines a withdrawn answer that an absence covers', t => {
  const { store, action, kim, event, respond, absent } = setup(t);
  const id = event(), plain = event(100, { autoAccept: false });
  for (const x of [id, plain]) respond(x, kim, 'open');
  absent(kim, store.get('events', id).startsAt);
  for (const x of [id, plain]) { const e = store.get('events', x); action({ action: 'event.save', id: x, title: 'Probe', startsAt: e.startsAt, endsAt: e.endsAt, place: 'Saal', version: e.version }); }
  assert.equal(store.get('responses', `${id}:${kim}`).status, 'no');
  assert.equal(store.get('responses', `${id}:${kim}`).absenceId, `abs-${kim}`);
  assert.equal(store.get('responses', `${plain}:${kim}`).status, 'open', 'other events keep the open answer');
});

test('event details list implicit attendees apart from the open ones', t => {
  const { store, app, sam, kim, lou, event, respond, absent } = setup(t);
  const id = event();
  respond(id, sam, 'yes');
  absent(lou, store.get('events', id).startsAt);
  const details = app.eventDetails('admin', id);
  assert.deepEqual(details.implicitIds, [kim]);
  assert.deepEqual(details.openIds, [lou]);
  assert.deepEqual(details.absentIds, [lou]);
});

test('open reminders are refused for auto-accepted events', t => {
  const { store, action, event } = setup(t);
  const id = event();
  assert.throws(() => action({ action: 'event.remindOpen', eventId: id }), { status: 409, code: 'nothing_open', message: 'Bei diesem Termin gelten alle Eingeladenen automatisch als zugesagt.' });
  assert.equal(store.all('pushJobs').length, 0);
  assert.equal(store.get('nudges', `event:${id}`), null);
});

test('not declining counts as an answer and a commitment, but only with an account at that time', t => {
  const { store, app, sam, kim, at } = setup(t);
  store.saveAccount({ ...store.account('sam'), approvedAt: at(-30 * 24) });
  for (const [id, hours] of [['missed', -48], ['kept', -72]]) store.put('events', id, { id, title: id, startsAt: at(hours), endsAt: at(hours + 2), type: 'rehearsal', personIds: [sam, kim], autoAccept: true });
  for (const personId of [sam, kim]) {
    store.put('checkins', `missed:${personId}`, { eventId: 'missed', personId, present: false, version: 1 });
    store.put('checkins', `kept:${personId}`, { eventId: 'kept', personId, present: true, version: 1 });
  }
  const own = app.participation('sam').own;
  assert.deepEqual([own.answerable, own.answered, own.attended, own.missedAfterCommitment, own.missedUnannounced], [2, 2, 1, 1, 0]);
  // Kim's account is younger than both events: nothing is held against her.
  const later = app.participation('admin').people.find(p => p.personId === kim);
  assert.deepEqual([later.answerable, later.answered, later.missedAfterCommitment, later.missedUnannounced], [0, 0, 0, 0]);
});

test('the calendar feed contains implicit attendance and leaves out declines', t => {
  const { app, sam, kim, event, respond } = setup(t);
  const id = event();
  respond(id, kim, 'no');
  assert.deepEqual(calendarFeedEvents(app, sam).map(e => e.id), [id]);
  assert.deepEqual(calendarFeedEvents(app, kim).map(e => e.id), []);
});

test('"Du bist eingeplant" goes out once, two days ahead, only to implicit attendees', t => {
  const { store, app, clock, sam, kim, lou, event, respond, absent, planned } = setup(t);
  const id = event(49);
  respond(id, sam, 'yes');
  absent(lou, store.get('events', id).startsAt);
  scheduleReminders(app, clock.now);
  assert.equal(planned().length, 0, 'not yet at 49 hours');
  const later = new Date(+clock.now + 2 * hour);
  scheduleReminders(app, later); scheduleReminders(app, later);
  assert.deepEqual(planned().map(j => j.recipientPersonIds), [[kim]]);
  const [job] = planned();
  assert.deepEqual([job.title, job.pushKind, job.data], ['Du bist eingeplant: Probe', 'eventPlanned', { eventId: id, intent: 'decline' }]);
  assert.ok(store.get('reminderSent', `${id}:${store.get('events', id).startsAt}:${kim}:planned`));
});

test('no "Du bist eingeplant" below two hours, for locked events or with the switch off', t => {
  const { store, app, clock, sam, kim, lou, event, planned } = setup(t);
  const soon = event(1.5), locked = event(30, { locked: true }), open = event(30);
  store.put('reminders', lou, { eventPlanned: false });
  scheduleReminders(app, clock.now);
  assert.deepEqual(planned().map(j => [j.data.eventId, j.recipientPersonIds[0]]).sort(), [[open, kim], [open, sam]].sort());
  // Ordinary reminders reach implicit attendees: they attend.
  const ordinary = store.all('pushJobs').filter(j => !j.planned && j.data?.eventId === soon).map(j => j.recipientPersonIds[0]).sort();
  assert.deepEqual(ordinary, [sam, kim, lou].sort());
  // The locked event still counts everyone as attending.
  assert.equal(app.snapshot('sam').events.find(e => e.id === locked).people, 3);
});

test('an ordinary reminder due in the same tick is not sent on top', t => {
  const { store, app, clock, kim, event, planned } = setup(t);
  store.put('reminders', kim, { customMinutes: 48 * 60 });
  const id = event(47);
  scheduleReminders(app, clock.now); scheduleReminders(app, clock.now);
  const forKim = store.all('pushJobs').filter(j => j.recipientPersonIds?.includes(kim));
  assert.deepEqual(forKim.map(j => j.planned === true), [true]);
  assert.ok(store.get('reminderSent', `${id}:${store.get('events', id).startsAt}:${kim}:custom-2880`));
  assert.equal(planned().length, 3);
});

test('an announcement within two days replaces the reminder; switching auto-accept on stays silent', t => {
  const { store, app, clock, action, sam, kim, lou, event, clear, planned } = setup(t);
  store.put('reminders', lou, { eventAnnouncements: false });
  const announced = event(30, { push: true });
  const startsAt = store.get('events', announced).startsAt;
  assert.ok(store.get('reminderSent', `${announced}:${startsAt}:${sam}:planned`));
  assert.equal(store.get('reminderSent', `${announced}:${startsAt}:${lou}:planned`), null, 'Lou gets no announcement');
  // Created close without a push: the reminder goes out at the next tick.
  const quiet = event(30);
  const switched = event(30, { autoAccept: false });
  clear();
  const e = store.get('events', switched);
  action({ action: 'event.save', id: switched, title: 'Probe', startsAt: e.startsAt, endsAt: e.endsAt, personIds: e.personIds, version: e.version, autoAccept: true });
  assert.equal(store.all('pushJobs').length, 0);
  scheduleReminders(app, clock.now);
  assert.deepEqual(planned().map(j => [j.data.eventId, j.recipientPersonIds[0]]).sort(), [[announced, lou], [quiet, kim], [quiet, lou], [quiet, sam]].sort());
  // Far ahead the announcement pre-marks nothing.
  const far = event(plannedReminderLeadMs / hour + 5, { push: true });
  assert.equal(store.get('reminderSent', `${far}:${store.get('events', far).startsAt}:${sam}:planned`), null);
});

test('series pushes carry only their summary, so near occurrences still get "Du bist eingeplant"', t => {
  const { store, app, clock, action, sam, kim, lou, at, event, clear, planned } = setup(t);
  const plannedFor = id => planned().filter(j => j.data.eventId === id).map(j => j.recipientPersonIds[0]).sort();
  const created = action({ action: 'event.save', title: 'Probe', startsAt: at(30), endsAt: at(32), place: 'Saal', personIds: [sam, kim, lou], autoAccept: true, push: true, repeat: { every: 'week', until: berlinDay(at(30 + 14 * 24)) } });
  const first = store.get('events', created.ids[0]);
  assert.equal(store.get('reminderSent', `${first.id}:${first.startsAt}:${sam}:planned`), null);
  clear();
  scheduleReminders(app, clock.now);
  assert.deepEqual(plannedFor(first.id), [sam, kim, lou].sort());
  // "This and following" with a push moves a series close: the change push is a summary as well.
  const id = event(100, { repeat: { every: 'week', until: berlinDay(at(100 + 7 * 24)) } }), old = store.get('events', id);
  action({ action: 'event.save', id, title: 'Probe', startsAt: at(30), endsAt: at(32), place: 'Saal', personIds: old.personIds, version: old.version, series: 'following', push: true });
  assert.ok(store.all('pushJobs').some(j => j.series && j.announce === 'changed'));
  clear();
  scheduleReminders(app, clock.now);
  assert.deepEqual(plannedFor(id), [sam, kim, lou].sort());
});

test('an absence too late to decline still ends the implicit yes for good', t => {
  const { store, app, clock, action, sam, kim, at, event, respond } = setup(t);
  const near = event(0.5), locked = event(30, { locked: true }), plain = event(0.5, { autoAccept: false });
  respond(near, kim, 'yes');
  const range = { action: 'absence.create', from: berlinDay(at(0.5)), to: berlinDay(at(30)), reason: 'Krank' };
  const absence = action(range, 'sam');
  // Nothing was declined in time, but the absence is recorded on the auto-accepted events.
  assert.deepEqual(absence.declinedEventIds, []);
  for (const x of [near, locked]) assert.deepEqual([store.get('responses', `${x}:${sam}`)?.status, store.get('responses', `${x}:${sam}`)?.absenceId], ['no', absence.id]);
  assert.equal(store.get('responses', `${plain}:${sam}`), null, 'other events stay as they are');
  action(range, 'kim');
  assert.equal(store.get('responses', `${near}:${kim}`).status, 'yes', 'an own answer stays');
  // Retention removes the absence after the rehearsal; the absent evening is still no broken commitment.
  clock.now = new Date(+clock.now + 3 * hour);
  store.delete('absences', absence.id);
  store.put('checkins', `${near}:${sam}`, { eventId: near, personId: sam, present: false, version: 1 });
  const own = app.participation('sam').own;
  assert.deepEqual([own.answered, own.missedAfterCommitment, own.missedUnannounced], [1, 0, 0]);
});

test('pushes to implicit attendees say "Du bist eingeplant" and offer "Ok" and the decline', async t => {
  const { store, app, clock, action, sam, kim, lou, event, respond, clear, deliver } = setup(t);
  app.device('kim', 'kim-android-token-with-actions', 'android', false, true);
  const id = event(30);
  respond(id, lou, 'no');
  scheduleReminders(app, clock.now);
  // Sam answers after the reminder was queued: the reminder is void for him.
  respond(id, sam, 'yes');
  let sent = await deliver();
  assert.deepEqual(sent.flatMap(p => p.tokens).sort(), ['kim-android-token-with-actions', 'token-kim']);
  const android = sent.find(p => p.tokens.includes('kim-android-token-with-actions'));
  assert.equal(android.data.title, 'Du bist eingeplant: Probe');
  assert.match(android.data.body, /Uhr · Saal\nDu bist eingeplant\. Kannst du nicht\? Bitte absagen\.$/);
  assert.equal(android.data.attendanceActions, 'planned');
  assert.equal(android.data.intent, 'decline');
  const web = sent.find(p => p.tokens.includes('token-kim'));
  assert.equal(new URL(web.webpush.fcmOptions.link).searchParams.get('target'), `theaterapp://app/events/${id}?intent=decline`);
  // A change reaches implicit and accepted attendees, not who declined.
  clear();
  const e = store.get('events', id);
  action({ action: 'event.save', id, title: 'Probe', startsAt: new Date(Date.parse(e.startsAt) + hour).toISOString(), endsAt: new Date(Date.parse(e.endsAt) + hour).toISOString(), place: 'Saal', version: e.version, push: true });
  sent = await deliver();
  assert.deepEqual(sent.flatMap(p => p.tokens).sort(), ['kim-android-token-with-actions', 'token-kim', 'token-sam']);
  assert.equal(sent.find(p => p.tokens.includes('kim-android-token-with-actions')).data.attendanceActions, 'planned');
  assert.match(sent.find(p => p.tokens.includes('token-sam')).notification.body, /Du hast zugesagt\.$/);
});

test('a queued "Du bist eingeplant" respects a later switch-off', async t => {
  const { store, app, clock, kim, event, deliver } = setup(t);
  event(30);
  scheduleReminders(app, clock.now);
  store.put('reminders', kim, { eventPlanned: false });
  const sent = await deliver();
  assert.deepEqual(sent.flatMap(p => p.tokens).sort(), ['token-lou', 'token-sam']);
});

test('an implicit attendee declining shortly before the start is reported to the direction', t => {
  const { store, app, action, admin, sam, event } = setup(t);
  const id = event(10);
  action({ action: 'attendance', eventId: id, status: 'no', reason: 'Krank' }, 'sam');
  const [job] = store.all('pushJobs').filter(j => j.pushKind === 'lateDeclines');
  assert.deepEqual(job.recipientPersonIds, [admin]);
  // Withdrawing the decline makes Sam an implicit attendee again.
  action({ action: 'attendance', eventId: id, status: 'open' }, 'sam');
  assert.equal(app.snapshot('sam').events.find(e => e.id === id).implicitYes, true);
  assert.equal(implicitYes(store, store.get('events', id), store.get('members', sam), 'open'), true);
});

test('slot events never auto-accept, and deleting a person removes their planned reminders', t => {
  const { store, app, clock, sam, event } = setup(t);
  const slotEvent = { id: 'slot-p-s', title: 'Foto', startsAt: new Date(+clock.now + 30 * hour).toISOString(), endsAt: new Date(+clock.now + 31 * hour).toISOString(), personIds: [sam], slotPoolId: 'p', autoAccept: true };
  assert.deepEqual(app.implicitIds(slotEvent), []);
  assert.equal(implicitYes(store, slotEvent, store.get('members', sam), null), false);
  // The Terminfinder rewrites its events without the field.
  app.syncSlotEvent({ id: 'p', title: 'Foto', slots: [] }, { id: 's', startsAt: slotEvent.startsAt, endsAt: slotEvent.endsAt });
  store.put('slotBookings', `p:${sam}`, { poolId: 'p', slotId: 's', personId: sam });
  app.syncSlotEvent({ id: 'p', title: 'Foto', slots: [] }, { id: 's', startsAt: slotEvent.startsAt, endsAt: slotEvent.endsAt });
  assert.equal(store.get('events', 'slot-p-s').autoAccept, undefined);
  const id = event(30);
  scheduleReminders(app, clock.now);
  const key = `${id}:${store.get('events', id).startsAt}:${sam}:planned`;
  assert.ok(store.get('reminderSent', key));
  app.forgetMember(sam);
  assert.equal(store.get('reminderSent', key), null);
});
