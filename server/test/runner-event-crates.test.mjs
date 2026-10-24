import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures } from '../src/theater.mjs';
import { deliverPush } from '../src/push.mjs';
import { bundledCatalog, loadCatalog, shinyChanceOf } from '../src/runner-wardrobe.mjs';
import { attendanceRecorders, attendanceRules, eventCratesSince, settleAttendance } from '../src/runner-event-crates.mjs';

// Termin-Kiste: one private crate per person and event for being there.
const rarities = [{ id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 60, gage: 10 }];
const items = [
  { id: 'c0', kind: 'character', name: 'Engel Logge', rarity: 'hell', default: true },
  { id: 'b0', kind: 'backdrop', name: 'Wand', rarity: 'hell', default: true },
  { id: 'o0', kind: 'obstacles', name: 'Lager', rarity: 'hell', default: true },
  { id: 'f0', kind: 'fx', name: 'Ohne', rarity: 'hell', default: true },
  { id: 'h1', kind: 'character', name: 'Hell 1', rarity: 'hell' },
  { id: 'h2', kind: 'character', name: 'Hell 2', rarity: 'hell' },
  { id: 'h3', kind: 'character', name: 'Hell 3', rarity: 'hell' },
];
const catalogWith = shinyChance => loadCatalog({ rarities, items, dupes: { shinyChance } });
const hour = 3600000, minute = 60000;

function setup(t, { shinyChance = { costume: 0.03, ensemble: 0.03, event: 0.03 }, random = 0.5, pushEnabled = true, store = new Store(), clock = { now: new Date('2026-10-24T08:00:00Z') } } = {}) {
  t.after(() => { try { store.close(); } catch { /* closed by an earlier setup on the same store */ } });
  // Fake time: the tests move this clock instead of waiting.
  const make = () => new Theater(store, { bootstrapEmail: 'admin@example.invalid', pushEnabled, clock: () => clock.now, runnerCatalog: catalogWith(shinyChance), random: () => random, missionRules: null });
  const app = make();
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  // The Termin-Kisten start now; events ending before bring nothing.
  store.transaction(() => eventCratesSince(app));
  let n = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `e-${++n}`);
  const member = (uid, name, roleIds = []) => {
    const personId = action({ action: 'member.save', name, roleIds }).id;
    app.session({ uid, name, email: `${uid}@example.invalid`, email_verified: true });
    action({ action: 'account.approve', uid, personId, version: 1, role: 'member' });
    return personId;
  };
  const admin = store.account('admin').personId;
  const sam = member('sam', 'Sam Beispiel', ['role-1']);
  const kim = member('kim', 'Kim Beispiel', ['role-2']);
  /** An event starting [hours] from now, two hours long. */
  const event = (id, hours = 48, extra = {}) => {
    const startsAt = new Date(+clock.now + hours * hour).toISOString();
    return store.put('events', id, { id, title: `Probe ${id}`, startsAt, endsAt: new Date(Date.parse(startsAt) + 2 * hour).toISOString(), type: 'rehearsal', roleIds: [], personIds: [], productionIds: [], version: 1, createdBy: admin, ...extra });
  };
  const respond = (eventId, status, uid = 'sam', extra = {}) => action({ action: 'attendance', eventId, status, ...extra }, uid);
  /** Records [present] for [personId] like the check-in view (with the current version). */
  const checkin = (eventId, personId, present, uid = 'admin') => action({ action: 'checkin.save', eventId, members: [{ id: personId, present, version: store.get('checkins', `${eventId}:${personId}`)?.version ?? 0 }] }, uid);
  /** Moves the clock to [ms] after the end of [eventId]. */
  const afterEnd = (eventId, ms) => { clock.now = new Date(Date.parse(store.get('events', eventId).endsAt) + ms); };
  const waiting = (uid = 'sam') => app.runnerWardrobe(uid).eventCrates;
  const open = (uid = 'sam', body = {}) => app.runnerOpenCrate(uid, `open-${++n}`, { dupes: true, crate: 'event', ...body });
  const reminders = () => store.all('pushJobs').filter(j => j.pushKind === 'attendanceCheckin');
  return { store, app, make, clock, action, admin, sam, kim, member, event, respond, checkin, afterEnd, waiting, open, reminders };
}

test('servers announce the Termin-Kisten; the check-in view learns which attendance was adopted', t => {
  const { app } = setup(t);
  assert.ok(apiFeatures.includes('runnerEventCrates'));
  assert.ok(app.snapshot('sam').capabilities.features.includes('runnerEventCrates'));
  assert.deepEqual(app.snapshot('admin').autoCheckinsByEvent, {});
  assert.deepEqual(app.snapshot('sam').autoCheckinsByEvent, {});
});

test('a commitment alone brings no crate, only the promise of one', t => {
  const { app, event, respond, waiting } = setup(t);
  event('a');
  assert.deepEqual(respond('a', 'yes').eventCrate, { pending: true, player: false });
  assert.deepEqual(waiting(), []);
  assert.equal(app.runnerWardrobe('sam').progress.eventCrates, 0);
  // Arriving late instead is the same commitment; no second promise.
  assert.equal(respond('a', 'late').eventCrate, undefined);
  assert.equal(respond('a', 'no').eventCrate, undefined);
  app.runnerWardrobe('sam');
  assert.deepEqual(respond('a', 'yes').eventCrate, { pending: true, player: true });
  // Not for the uninvited admin, who sees every event.
  event('kims', 48, { roleIds: ['role-2'] });
  assert.equal(respond('kims', 'yes', 'admin').eventCrate, undefined);
});

test('a recorded attendance brings exactly one crate, whatever was answered', t => {
  const { app, event, respond, checkin, waiting, sam, kim, afterEnd } = setup(t);
  const e = event('a', 2);
  respond('a', 'yes');
  afterEnd('a', 10 * minute);
  checkin('a', sam, true);
  // Kim never answered (and is not invited): recorded as there, Kim gets one too.
  checkin('a', kim, true);
  assert.deepEqual(waiting(), [{ eventId: 'a', title: 'Probe a', startsAt: e.startsAt }]);
  assert.deepEqual(waiting('kim').map(x => x.eventId), ['a']);
  assert.equal(app.runnerWardrobe('sam').progress.eventCrates, 1);
  // Saving again changes nothing.
  checkin('a', sam, true);
  assert.equal(waiting().length, 1);
  // Private: nobody else gets anything.
  assert.deepEqual(waiting('admin'), []);
});

test('without a record the own commitments become the attendance after the deadline', t => {
  const { app, store, event, respond, waiting, sam, kim, afterEnd, member, action } = setup(t);
  const toni = member('toni', 'Toni Beispiel');
  event('a', 2);
  respond('a', 'yes'); respond('a', 'late', 'toni');
  event('auto', 2, { autoAccept: true });
  respond('auto', 'yes', 'toni');
  assert.equal(app.snapshot('sam').events.find(e => e.id === 'auto').implicitYes, true);
  afterEnd('auto', attendanceRules.autoAdoptAfterMs - minute);
  settleAttendance(app);
  assert.deepEqual(waiting(), [], 'not before the deadline');
  afterEnd('auto', attendanceRules.autoAdoptAfterMs);
  settleAttendance(app);
  settleAttendance(app);
  assert.deepEqual(waiting().map(x => x.eventId), ['a']);
  assert.deepEqual(waiting('toni').map(x => x.eventId), ['a', 'auto']);
  // The implicit yes of an auto-accepted event and no answer at all are no own commitment.
  assert.deepEqual(waiting('kim'), []);
  assert.equal(store.get('checkins', `auto:${sam}`), null);
  assert.deepEqual(store.get('checkins', `a:${sam}`).source, 'auto');
  assert.equal(store.get('checkins', `a:${kim}`), null);
  assert.deepEqual(app.snapshot('admin').autoCheckinsByEvent, { a: [sam, toni], auto: [toni] });
  assert.equal(app.snapshot('admin').checkinsByEvent.a[sam], true);
  // Recorded by hand later, the attendance is no longer marked as adopted.
  action({ action: 'checkin.save', eventId: 'a', members: [{ id: toni, present: true, version: 1 }] });
  assert.deepEqual(app.snapshot('admin').autoCheckinsByEvent.a, [sam]);
  assert.equal(store.all('runnerEventCrates').length, 3);
});

test('a recorded attendance rules out the adoption, also for those left unrecorded', t => {
  const { event, respond, checkin, waiting, kim, afterEnd, app, store } = setup(t);
  event('a', 2);
  respond('a', 'yes');
  afterEnd('a', hour);
  checkin('a', kim, false);
  afterEnd('a', attendanceRules.autoAdoptAfterMs + hour);
  settleAttendance(app);
  assert.deepEqual(waiting(), []);
  assert.equal(store.all('checkins').filter(c => c.source === 'auto').length, 0);
  // A record that was taken back (unrecorded again) is no record.
  const fresh = setup(t);
  fresh.event('b', 2); fresh.respond('b', 'yes');
  fresh.afterEnd('b', hour);
  fresh.checkin('b', fresh.kim, true); fresh.checkin('b', fresh.kim, null);
  fresh.afterEnd('b', attendanceRules.autoAdoptAfterMs);
  settleAttendance(fresh.app);
  assert.deepEqual(fresh.waiting().map(x => x.eventId), ['b']);
});

test('corrections both ways: missing lets a waiting crate lapse, there brings the same one back', t => {
  const { store, app, event, respond, checkin, waiting, open, sam, afterEnd } = setup(t);
  event('a', 2);
  respond('a', 'yes');
  afterEnd('a', attendanceRules.autoAdoptAfterMs);
  settleAttendance(app);
  assert.equal(waiting().length, 1);
  checkin('a', sam, false);
  assert.deepEqual(waiting(), []);
  assert.throws(() => open(), { status: 409, code: 'no_crate' });
  checkin('a', sam, true);
  assert.equal(waiting().length, 1);
  checkin('a', sam, null);
  assert.deepEqual(waiting(), []);
  checkin('a', sam, true);
  // Opened, it stays, whatever is recorded afterwards.
  const opened = open();
  assert.equal(opened.outcome.crate, 'event');
  checkin('a', sam, false); checkin('a', sam, true); checkin('a', sam, false);
  assert.deepEqual(waiting(), []);
  assert.equal(store.get('runnerEventCrates', `a:${sam}`).state, 'opened');
  assert.ok(store.get('runnerProgress', sam).owned.includes(opened.item.id));
  assert.equal(store.all('runnerEventCrates').length, 1);
  // Marked as there long after the deadline still brings the crate.
  event('b', 2);
  afterEnd('b', 3 * attendanceRules.autoAdoptAfterMs);
  settleAttendance(app);
  checkin('b', sam, true);
  assert.deepEqual(waiting().map(x => x.eventId), ['b']);
});

test('events that ended before the Termin-Kisten came bring nothing', t => {
  const { store, app, sam, checkin, waiting, clock } = setup(t);
  const startsAt = new Date(+clock.now - 30 * hour).toISOString();
  store.put('events', 'old', { id: 'old', title: 'Alt', startsAt, endsAt: new Date(Date.parse(startsAt) + 2 * hour).toISOString(), type: 'rehearsal', roleIds: [], personIds: [], productionIds: [], version: 1 });
  store.put('responses', `old:${sam}`, { eventId: 'old', personId: sam, status: 'yes', reason: '', expectedArrivalAt: null, updatedAt: startsAt });
  settleAttendance(app);
  checkin('old', sam, true);
  assert.deepEqual(waiting(), []);
  assert.equal(store.all('checkins').filter(c => c.source === 'auto').length, 0);
});

test('the reminder to record the attendance goes out once, not after a record, and survives a restart', t => {
  const clock = { now: new Date('2026-10-24T08:00:00Z') }, store = new Store();
  const { app, make, event, respond, reminders, afterEnd, checkin, sam, admin } = setup(t, { clock, store });
  event('a', 2);
  respond('a', 'yes');
  afterEnd('a', 29 * minute);
  settleAttendance(app);
  assert.equal(reminders().length, 0, 'not before 30 minutes after the end');
  afterEnd('a', 30 * minute);
  settleAttendance(app); settleAttendance(app);
  assert.equal(reminders().length, 1);
  const [first] = reminders();
  assert.equal(first.title, 'Anwesenheit erfassen');
  assert.match(first.body, /^Bitte Anwesenheit für „Probe a“ erfassen/);
  assert.deepEqual(first.data, { eventId: 'a', intent: 'checkin' });
  assert.deepEqual(first.recipientPersonIds, [admin]);
  // A restart (a new Theater on the same database) sends nothing again.
  afterEnd('a', 2 * hour);
  settleAttendance(make());
  assert.equal(reminders().length, 1);
  // The second one, shortly before the adoption, also only once.
  afterEnd('a', attendanceRules.autoAdoptAfterMs - attendanceRules.secondReminderBeforeMs);
  settleAttendance(make()); settleAttendance(app);
  assert.equal(reminders().length, 2);
  assert.equal(reminders().filter(j => /Sonst werden am .* die Zusagen übernommen\.$/.test(j.body)).length, 1);
  // Recorded meanwhile: no reminders at all.
  event('b', 2);
  afterEnd('b', 10 * minute);
  checkin('b', sam, true);
  afterEnd('b', 30 * minute); settleAttendance(app);
  afterEnd('b', attendanceRules.autoAdoptAfterMs - hour); settleAttendance(app);
  assert.equal(reminders().filter(j => j.data.eventId === 'b').length, 0);
  // Down from before the end until shortly before the adoption: only the second one, once.
  event('c', 2);
  afterEnd('c', attendanceRules.autoAdoptAfterMs - hour);
  settleAttendance(make()); settleAttendance(make());
  assert.equal(reminders().filter(j => j.data.eventId === 'c').length, 1);
  // Down past the deadline: no reminder, the adoption follows.
  event('d', 2);
  afterEnd('d', attendanceRules.autoAdoptAfterMs + hour);
  settleAttendance(make());
  assert.equal(reminders().filter(j => j.data.eventId === 'd').length, 0);
});

test('reminders go to the people responsible, else invited holders of the right, else all of them', t => {
  const { app, store, event, action, admin, sam, kim, member } = setup(t);
  const lead = member('lead', 'Lea Leitung', ['role-1']);
  action({ action: 'account.permissions', uid: 'lead', permissions: ['events'], version: store.account('lead').version });
  // The creator without the right can not record: the invited holders are reminded.
  assert.deepEqual(attendanceRecorders(app, event('a', 2, { createdBy: sam, roleIds: ['role-1'] })), [lead]);
  // Created by a holder: just them.
  assert.deepEqual(attendanceRecorders(app, event('b', 2, { createdBy: lead })), [lead]);
  // A director of the production with the right is responsible, too.
  const productionId = store.put('productions', 'p1', { id: 'p1', title: 'Stück', directorMemberIds: [admin], version: 1 }).id;
  assert.deepEqual(attendanceRecorders(app, event('c', 2, { createdBy: lead, productionId })).sort(), [admin, lead].sort());
  // Nobody responsible or invited holds the right: all holders.
  assert.deepEqual(attendanceRecorders(app, event('d', 2, { createdBy: kim, personIds: [kim] })).sort(), [admin, lead].sort());
});

test('the reminder opens the check-in of the event', async t => {
  const { app, store, event, afterEnd } = setup(t);
  event('a', 2);
  afterEnd('a', 30 * minute);
  settleAttendance(app);
  store.put('devices', 'w', { id: 'w', uid: 'admin', token: 'token-w', platform: 'web' });
  const calls = [];
  await deliverPush(app, { sendEachForMulticast: async payload => { calls.push(payload); return { responses: [{ success: true }] }; } }, 'https://app.example.invalid');
  const call = calls.filter(c => c.notification?.title === 'Anwesenheit erfassen');
  assert.equal(call.length, 1);
  assert.equal(new URL(call[0].webpush.fcmOptions.link).searchParams.get('target'), 'theaterapp://app/events/a?intent=checkin');
});

test('without push nothing is reminded, but the adoption still runs', t => {
  const { app, event, respond, afterEnd, reminders, waiting } = setup(t, { pushEnabled: false });
  event('a', 2); respond('a', 'yes');
  afterEnd('a', hour); settleAttendance(app);
  afterEnd('a', attendanceRules.autoAdoptAfterMs); settleAttendance(app);
  assert.equal(reminders().length, 0);
  assert.equal(waiting().length, 1);
});

test('the deadlines are configurable', t => {
  const clock = { now: new Date('2026-10-24T08:00:00Z') }, store = new Store();
  t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', pushEnabled: true, clock: () => clock.now, runnerCatalog: catalogWith({ costume: 0 }), attendanceRules: { autoAdoptAfterMs: 2 * hour, reminderAfterMs: 0, secondReminderBeforeMs: null } });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  store.transaction(() => eventCratesSince(app));
  const startsAt = new Date(+clock.now + hour).toISOString(), endsAt = new Date(+clock.now + 2 * hour).toISOString();
  store.put('events', 'a', { id: 'a', title: 'A', startsAt, endsAt, type: 'rehearsal', roleIds: [], personIds: [], productionIds: [], version: 1 });
  app.action('admin', { action: 'attendance', eventId: 'a', status: 'yes' }, 'r1');
  clock.now = new Date(endsAt); settleAttendance(app);
  assert.equal(store.all('pushJobs').filter(j => j.pushKind === 'attendanceCheckin').length, 1);
  clock.now = new Date(Date.parse(endsAt) + 110 * minute); settleAttendance(app);
  assert.equal(store.all('pushJobs').filter(j => j.pushKind === 'attendanceCheckin').length, 1, 'no second one');
  clock.now = new Date(Date.parse(endsAt) + 2 * hour); settleAttendance(app);
  assert.equal(app.runnerWardrobe('admin').eventCrates.length, 1);
});

test('adopted attendance does not count in the participation summary', t => {
  const { app, event, respond, afterEnd, checkin, kim } = setup(t);
  event('a', 2); respond('a', 'yes'); respond('a', 'yes', 'kim');
  afterEnd('a', attendanceRules.autoAdoptAfterMs); settleAttendance(app);
  checkin('a', kim, true);
  const own = app.participation('sam').own;
  assert.equal(own.recorded, 0);
  assert.equal(own.attended, 0);
  assert.equal(app.participation('kim').own.attended, 1);
});

test('a Termin-Kiste opens like a costume crate, only in apps with duplicates', t => {
  const { app, event, checkin, waiting, open, store, sam } = setup(t);
  event('a', 24); event('b', 48);
  checkin('a', sam, true); checkin('b', sam, true);
  app.runnerWardrobe('sam');
  const before = store.get('runnerProgress', sam);
  assert.throws(() => app.runnerOpenCrate('sam', 'old-app', { crate: 'event' }), { status: 400 });
  // A chosen one, else the earliest.
  const second = open('sam', { eventId: 'b' });
  assert.equal(second.outcome.crate, 'event');
  assert.deepEqual(second.outcome.event, { eventId: 'b', title: 'Probe b', startsAt: store.get('events', 'b').startsAt });
  assert.ok(['h1', 'h2', 'h3'].includes(second.item.id));
  assert.equal(second.reel.length, 56);
  assert.deepEqual(second.wardrobe.eventCrates.map(x => x.eventId), ['a']);
  assert.throws(() => open('sam', { eventId: 'b' }), { status: 409, code: 'no_crate' });
  assert.equal(open().outcome.event.eventId, 'a');
  assert.throws(() => open(), { status: 409, code: 'no_crate' });
  // Costume crates of the own metres are untouched.
  const after = store.get('runnerProgress', sam);
  assert.equal(after.opened, before.opened);
  assert.equal(after.owned.length, 2);
  assert.deepEqual(waiting(), []);
  // The same request again gives the same opening.
  event('c'); checkin('c', sam, true);
  const first = app.runnerOpenCrate('sam', 'same', { dupes: true, crate: 'event' });
  assert.deepEqual(app.runnerOpenCrate('sam', 'same', { dupes: true, crate: 'event' }), first);
});

test('the shine chance of a Termin-Kiste is its own, 3 % in the bundled catalog', t => {
  assert.equal(shinyChanceOf(bundledCatalog(), 'event'), 0.03);
  assert.equal(shinyChanceOf(catalogWith({ costume: 0.2 }), 'event'), 0.2, 'without an entry it has the costume chance');
  for (const [chance, shiny] of [[{ costume: 0, ensemble: 0, event: 1 }, true], [{ costume: 1, ensemble: 1, event: 0 }, false]]) {
    const { event, checkin, open, sam } = setup(t, { shinyChance: chance });
    event('a'); checkin('a', sam, true);
    assert.equal(open().outcome.shiny, shiny);
  }
});

test('deleting a person deletes their crates; a deleted event keeps its crate', t => {
  const { app, store, event, checkin, waiting, sam } = setup(t);
  event('a'); checkin('a', sam, true);
  event('b'); checkin('b', sam, true);
  app.removeEvent('b');
  assert.deepEqual(waiting().map(x => x.title), ['Probe a', 'Probe b']);
  store.transaction(() => app.forgetMember(sam));
  assert.deepEqual(store.all('runnerEventCrates'), []);
});
