import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { deliverPush, scheduleReminders } from '../src/push.mjs';

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const theater = new Theater(store, { pushEnabled: true, bootstrapEmail: 'admin@example.invalid' });
  const a = theater.session({ uid: 'admin', email: 'admin@example.invalid', email_verified: true });
  store.put('devices', 'a', { id: 'a', uid: 'admin', token: 'token-a', platform: 'android' });
  store.put('devices', 'b', { id: 'b', uid: 'admin', token: 'token-b', platform: 'web' });
  return { store, theater, a };
}
test('FCM retry sends only previously unaccepted devices', async t => {
  const { store, theater } = setup(t); theater.enqueuePush({ title: 'Probe', body: 'Heute' });
  const calls = []; let attempt = 0;
  const messaging = { sendEachForMulticast: async payload => { calls.push(payload); return { responses: attempt++ === 0 ? [{ success: true }, { success: false, error: { code: 'messaging/internal-error' } }] : [{ success: true }] }; } };
  await deliverPush(theater, messaging);
  let job = store.all('pushJobs')[0]; assert.equal(job.status, 'pending'); assert.equal(job.accepted, 1);
  store.put('pushJobs', job.id, { ...job, nextAttemptAt: new Date(0).toISOString() });
  await deliverPush(theater, messaging); job = store.all('pushJobs')[0];
  assert.deepEqual(calls.map(x => x.tokens), [['token-a', 'token-b'], ['token-b']]);
  assert.equal(calls[0].android.notification.channelId, 'theater_updates');
  assert.equal(job.status, 'accepted_by_provider'); assert.equal(job.accepted, 2);
});
test('suspended accounts and dead tokens are excluded from future push', async t => {
  const { store, theater } = setup(t); theater.enqueuePush({ title: 'Probe', body: 'Heute' });
  await deliverPush(theater, { sendEachForMulticast: async () => ({ responses: [{ success: false, error: { code: 'messaging/registration-token-not-registered' } }, { success: true }] }) });
  assert.equal(store.get('devices', 'a'), null);
  store.saveAccount({ ...store.account('admin'), status: 'suspended' });
  theater.enqueuePush({ title: 'Probe 2', body: 'Heute' });
  await deliverPush(theater, { sendEachForMulticast: async () => { assert.fail('Suspended account must not receive push'); } });
  assert.equal(store.all('pushJobs').find(x => x.title === 'Probe 2').status, 'no_devices');
});
test('scheduled reminder is persisted once and respects cancellation and preference', t => {
  const { store, theater, a } = setup(t); const now = new Date('2026-09-12T10:00:00Z');
  store.put('events', 'e', { id: 'e', title: 'Probe', startsAt: '2026-09-13T09:00:00Z' });
  store.put('reminders', a.personId, { dayBefore: false }); scheduleReminders(theater, now); assert.equal(store.all('pushJobs').length, 0);
  store.put('reminders', a.personId, { dayBefore: true }); store.put('responses', `e:${a.personId}`, { status: 'no' }); scheduleReminders(theater, now); assert.equal(store.all('pushJobs').length, 0);
  store.delete('responses', `e:${a.personId}`); scheduleReminders(theater, now); assert.equal(store.all('pushJobs').length, 0);
  store.put('responses', `e:${a.personId}`, { status: 'yes' }); scheduleReminders(theater, now); scheduleReminders(theater, now); assert.equal(store.all('pushJobs').length, 1);
});

test('web push opens the exact message with an encoded target', async t => {
  const { theater } = setup(t);
  theater.enqueuePush({ title: 'Regie', body: 'Probe', data: { messageId: 'm-42' } });
  let link;
  await deliverPush(theater, { sendEachForMulticast: async p => { link = p.webpush.fcmOptions.link; return {responses: p.tokens.map(() => ({success:true}))}; } }, 'https://theater.example');
  assert.equal(new URL(link).origin, 'https://theater.example');
  assert.equal(new URL(link).searchParams.get('target'), 'theaterapp://app/messages/m-42');
});

test('one-day reminder defaults off, two-hour reminder defaults on, opt-in survives', t => {
  const { store, theater, a } = setup(t);
  const now = new Date('2026-09-14T12:00:00Z');
  store.put('events', 'e', { id: 'e', title: 'Abbau', startsAt: '2026-09-15T11:00:00Z', place: 'Kolpingheim' });
  assert.deepEqual(theater.snapshot('admin').reminders, { dayBefore: false, twoHours: true, changes: true, emailEnabled: false, customMinutes: null, lateDeclines: true });
  store.put('responses', `e:${a.personId}`, { status: 'yes' });
  scheduleReminders(theater, now);
  assert.equal(store.all('pushJobs').length, 0);
  store.put('events', 'e', { ...store.get('events', 'e'), startsAt: '2026-09-14T13:30:00Z' });
  scheduleReminders(theater, now);
  const job = store.all('pushJobs')[0];
  assert.equal(job.title, 'Abbau');
  assert.equal(job.body, 'Mo., 14.09.2026, 15:30 Uhr · Kolpingheim');
  store.put('reminders', a.personId, { dayBefore: true });
  assert.equal(theater.snapshot('admin').reminders.dayBefore, true);
  assert.equal(theater.snapshot('admin').reminders.twoHours, true);
});

test('Berlin event time handles winter and summer even when the server uses UTC', async () => {
  const { eventNotificationBody } = await import('../src/event-notification.mjs');
  assert.equal(eventNotificationBody({ startsAt: '2026-12-14T18:00:00Z' }), 'Mo., 14.12.2026, 19:00 Uhr');
  assert.equal(eventNotificationBody({ startsAt: '2026-09-14T17:00:00Z' }), 'Mo., 14.09.2026, 19:00 Uhr');
});

test('upgraded Android receives an account-bound action payload, old Android and web keep OS notifications', async t => {
  const { store, theater } = setup(t);
  theater.device('admin', 'new-android-device-token', 'android', false, true);
  const future = new Date(Date.now() + 3600000).toISOString();
  store.put('events', 'e', { id: 'e', title: 'Abbau', startsAt: future, endsAt: future, place: 'Saal' });
  theater.enqueuePush({ title: 'Abbau', body: 'Old generic body', data: { eventId: 'e' }, newEvent: true, announce: 'new' });
  const calls = [];
  await deliverPush(theater, { sendEachForMulticast: async p => {
    calls.push(p); return { responses: p.tokens.map(() => ({ success: true })) };
  } });
  const custom = calls.find(p => p.tokens.includes('new-android-device-token'));
  assert.equal(custom.notification, undefined);
  assert.equal(custom.android.notification, undefined);
  assert.equal(custom.android.priority, 'high');
  assert.equal(custom.data.attendanceActions, 'true');
  assert.equal(custom.data.recipientUid, 'admin');
  assert.equal(custom.data.eventId, 'e');
  assert.match(custom.data.body, /Uhr · Saal$/);
  assert.ok(custom.data.notificationId);
  const legacy = calls.find(p => p.tokens.includes('token-a'));
  assert.deepEqual(legacy.tokens, ['token-a', 'token-b']);
  assert.equal(legacy.notification.body, custom.data.body);
  assert.equal(legacy.data.recipientUid, undefined);
  assert.equal(store.all('pushJobs')[0].accepted, 3);
});

for (const [status, summary] of [['yes', 'Du hast zugesagt.'], ['late', 'Du kommst später.']]) {
  test(`event reminders show the current ${status} response without quick answers on every platform`, async t => {
    const { store, theater, a } = setup(t);
    theater.device('admin', 'new-android-device-token', 'android', false, true);
    theater.device('admin', 'ios-device-token-for-reminder', 'ios');
    const future = new Date(Date.now() + 3600000).toISOString();
    store.put('events', 'e', { id: 'e', title: 'Abbau', startsAt: future, endsAt: future, place: 'Saal' });
    store.put('responses', `e:${a.personId}`, { status: 'yes' });
    scheduleReminders(theater);
    assert.equal(store.all('pushJobs').length, 1);
    // A changed answer arrives after the reminder was queued, before it is sent.
    store.put('responses', `e:${a.personId}`, { status });
    const calls = [];
    await deliverPush(theater, { sendEachForMulticast: async p => {
      calls.push(p); return { responses: p.tokens.map(() => ({ success: true })) };
    } }, 'https://theater.example');
    const android = calls.find(p => p.tokens.includes('new-android-device-token'));
    assert.equal(android.data.attendanceActions, undefined);
    assert.equal(android.data.recipientUid, 'admin');
    assert.equal(android.data.eventId, 'e');
    assert.ok(android.data.body.endsWith(`Uhr · Saal\n${summary}`));
    const legacy = calls.find(p => p.tokens.includes('token-a'));
    assert.deepEqual(legacy.tokens, ['token-a', 'token-b', 'ios-device-token-for-reminder']);
    assert.equal(legacy.notification.body, android.data.body);
    assert.equal(new URL(legacy.webpush.fcmOptions.link).searchParams.get('target'), 'theaterapp://app/events/e');
    assert.equal(store.all('pushJobs')[0].accepted, 4);
  });
}

for (const status of [null, 'no']) {
  test(`open and declined invitations (${status ?? 'open'}) do not schedule or receive ordinary reminder pushes`, async t => {
    const { store, theater, a } = setup(t);
    const future = new Date(Date.now() + 3600000).toISOString();
    store.put('events', 'e', { id: 'e', title: 'Probe', startsAt: future, endsAt: future });
    if (status) store.put('responses', `e:${a.personId}`, { status });
    scheduleReminders(theater);
    assert.equal(store.all('pushJobs').length, 0);
    assert.equal(store.all('reminderSent').length, 0);
    // Previously queued reminders also obey the current attendance restriction.
    theater.enqueuePush({ title: 'Probe', body: 'Probe', data: { eventId: 'e' } });
    await deliverPush(theater, { sendEachForMulticast: async () => assert.fail('No reminder for an open or declined invitation') });
    assert.equal(store.all('pushJobs')[0].status, 'no_devices');
  });

  test(`a queued accepted reminder is skipped after the response becomes ${status ?? 'open'}`, async t => {
    const { store, theater, a } = setup(t);
    const future = new Date(Date.now() + 3600000).toISOString();
    store.put('events', 'e', { id: 'e', title: 'Probe', startsAt: future, endsAt: future });
    store.put('responses', `e:${a.personId}`, { status: 'yes' });
    scheduleReminders(theater);
    assert.equal(store.all('pushJobs').length, 1);
    if (status) store.put('responses', `e:${a.personId}`, { status });
    else store.delete('responses', `e:${a.personId}`);
    await deliverPush(theater, { sendEachForMulticast: async () => assert.fail('The acceptance was withdrawn before sending') });
    assert.equal(store.all('pushJobs')[0].status, 'no_devices');
  });
}

test('a decline suppresses reminders at retry and between device batches', async t => {
  const { store, theater, a } = setup(t);
  store.put('devices', 'a', { ...store.get('devices', 'a'), notificationActions: true });
  const future = new Date(Date.now() + 3600000).toISOString();
  store.put('events', 'e', { id: 'e', title: 'Probe', startsAt: future, endsAt: future });
  store.put('responses', `e:${a.personId}`, { status: 'late' });
  scheduleReminders(theater);
  let sends = 0;
  await deliverPush(theater, { sendEachForMulticast: async p => {
    sends++;
    assert.deepEqual(p.tokens, ['token-a']);
    store.put('responses', `e:${a.personId}`, { status: 'no' });
    return { responses: [{ success: false, error: { code: 'messaging/internal-error' } }] };
  } });
  assert.equal(sends, 1, 'the other device batch is skipped after the decline');
  const job = store.all('pushJobs')[0];
  assert.equal(job.status, 'pending');
  store.put('pushJobs', job.id, { ...job, nextAttemptAt: new Date(0).toISOString() });
  await deliverPush(theater, { sendEachForMulticast: async () => assert.fail('Declined reminders must not be retried') });
  assert.equal(store.all('pushJobs')[0].status, 'no_devices');
});

test('declined invitees do not receive event changes or already queued announcements', async t => {
  const { store, theater, a } = setup(t);
  const future = new Date(Date.now() + 3600000).toISOString();
  store.put('events', 'e', { id: 'e', title: 'Probe', startsAt: future, endsAt: future });
  store.put('responses', `e:${a.personId}`, { status: 'no' });
  for (const kind of [{ change: true }, { change: true, announce: 'changed' }, { newEvent: true, announce: 'new' }]) {
    theater.enqueuePush({ title: 'Probe', body: 'Probe', data: { eventId: 'e' }, ...kind });
  }
  await deliverPush(theater, { sendEachForMulticast: async () => assert.fail('Declined invitees must stay quiet') });
  assert.ok(store.all('pushJobs').every(j => j.status === 'no_devices'));
});

test('new event announcements keep responses separate and offer quick answers only to open invitees', async t => {
  const { store, theater, a } = setup(t);
  theater.device('admin', 'admin-android-device-with-actions', 'android', false, true);
  const personId = theater.action('admin', { action: 'member.save', name: 'Sam' }, 'create-sam').id;
  theater.session({ uid: 'sam', name: 'Sam', email: 'sam@example.invalid', email_verified: true });
  theater.action('admin', { action: 'account.approve', uid: 'sam', personId, version: 1, role: 'member' }, 'approve-sam');
  theater.device('sam', 'sam-android-device-with-actions', 'android', false, true);
  theater.device('sam', 'sam-web-device-for-notifications', 'web');
  theater.device('sam', 'sam-legacy-android-device-token', 'android');
  for (const job of store.all('pushJobs')) store.delete('pushJobs', job.id);
  const future = new Date(Date.now() + 3600000).toISOString();
  store.put('events', 'e', { id: 'e', title: 'Probe', startsAt: future, endsAt: future });
  store.put('responses', `e:${a.personId}`, { status: 'yes' });
  theater.enqueuePush({ title: 'Probe', body: 'Probe', data: { eventId: 'e' }, newEvent: true, announce: 'new' });
  const calls = [];
  await deliverPush(theater, { sendEachForMulticast: async p => {
    calls.push(p); return { responses: p.tokens.map(() => ({ success: true })) };
  } });
  const adminAndroid = calls.find(p => p.tokens.includes('admin-android-device-with-actions'));
  const samAndroid = calls.find(p => p.tokens.includes('sam-android-device-with-actions'));
  const adminLegacy = calls.find(p => p.tokens.includes('token-b'));
  const samLegacy = calls.find(p => p.tokens.includes('sam-web-device-for-notifications'));
  assert.equal(adminAndroid.data.attendanceActions, undefined);
  assert.ok(adminAndroid.data.body.endsWith('\nDu hast zugesagt.'));
  assert.equal(samAndroid.data.attendanceActions, 'true');
  assert.equal(samAndroid.data.recipientUid, 'sam');
  assert.ok(samAndroid.data.body.endsWith('Uhr'));
  assert.equal(adminLegacy.notification.body, adminAndroid.data.body);
  assert.equal(samLegacy.notification.body, samAndroid.data.body);
  assert.deepEqual(adminLegacy.tokens, ['token-a', 'token-b']);
  assert.deepEqual(samLegacy.tokens, ['sam-web-device-for-notifications', 'sam-legacy-android-device-token']);
});

test('a push retry reads a newly saved response and does not resend accepted devices', async t => {
  const { store, theater, a } = setup(t);
  store.put('devices', 'a', { ...store.get('devices', 'a'), notificationActions: true });
  theater.device('admin', 'second-android-device-for-retry', 'android', false, true);
  const future = new Date(Date.now() + 3600000).toISOString();
  store.put('events', 'e', { id: 'e', title: 'Probe', startsAt: future, endsAt: future });
  theater.enqueuePush({ title: 'Probe', body: 'Probe', data: { eventId: 'e' }, newEvent: true, announce: 'new' });
  const calls = [];
  let retry = false;
  const messaging = { sendEachForMulticast: async p => {
    calls.push(p);
    return { responses: p.tokens.map(token => token === 'second-android-device-for-retry' && !retry
      ? { success: false, error: { code: 'messaging/internal-error' } } : { success: true }) };
  } };
  await deliverPush(theater, messaging);
  assert.equal(calls[0].data.attendanceActions, 'true');
  const job = store.all('pushJobs')[0];
  assert.equal(job.status, 'pending');
  store.put('responses', `e:${a.personId}`, { status: 'yes' });
  store.put('pushJobs', job.id, { ...job, nextAttemptAt: new Date(0).toISOString() });
  retry = true;
  await deliverPush(theater, messaging);
  assert.equal(calls.length, 3);
  assert.deepEqual(calls[2].tokens, ['second-android-device-for-retry']);
  assert.equal(calls[2].data.attendanceActions, undefined);
  assert.ok(calls[2].data.body.endsWith('\nDu hast zugesagt.'));
  assert.equal(store.all('pushJobs')[0].status, 'accepted_by_provider');
  assert.equal(store.all('pushJobs')[0].accepted, 3);
});

test('locked and expired events have no response actions', async t => {
  const { store, theater, a } = setup(t);
  store.put('devices', 'a', { ...store.get('devices', 'a'), notificationActions: true });
  store.put('responses', `e:${a.personId}`, { status: 'yes' });
  for (const locked of [false, true]) {
    store.put('events', 'e', { id: 'e', title: 'Probe', startsAt: '2020-01-01T12:00:00Z', locked });
    theater.enqueuePush({ title: 'Probe', body: 'Probe', data: { eventId: 'e' } });
    await deliverPush(theater, { sendEachForMulticast: async p => {
      assert.equal(p.data.attendanceActions, undefined);
      return { responses: p.tokens.map(() => ({ success: true })) };
    } });
  }
});

test('new registrations notify admins once, only when ready to link', async t => {
  const { store, theater } = setup(t);
  const jobs = () => store.all('pushJobs').filter(j => j.title === 'Neue Registrierung');
  assert.equal(jobs().length, 0, 'bootstrap admin must not announce itself');
  let n = 0; const act = body => theater.action('admin', body, `reg-${++n}`);
  const personId = act({ action: 'member.save', name: 'Sam' }).id;
  theater.session({ uid: 'sam', name: 'Sam', email: 'sam@example.invalid', email_verified: true });
  act({ action: 'account.approve', uid: 'sam', version: 1, personId, role: 'member' });
  store.put('devices', 's', { id: 's', uid: 'sam', token: 'token-s', platform: 'android' });
  for (const j of store.all('pushJobs')) store.delete('pushJobs', j.id);
  const password = { uid: 'neu', name: 'Neu Mitglied', email: 'neu@example.invalid', email_verified: false };
  theater.session(password); theater.session(password);
  assert.equal(jobs().length, 0, 'unverified e-mail is not ready for approval');
  theater.session({ ...password, email_verified: true }); theater.session({ ...password, email_verified: true });
  assert.equal(jobs().length, 1);
  assert.equal(jobs()[0].body, 'Neu Mitglied wartet auf Zuordnung.');
  const google = { uid: 'g', name: 'Alias', email: 'g@example.invalid', email_verified: true, firebase: { sign_in_provider: 'google.com' } };
  theater.session(google);
  assert.equal(jobs().length, 2, 'provider accounts are linkable without a supplied name');
  theater.session(google, 'Gabi Beispiel'); theater.session(google);
  assert.deepEqual(jobs().map(j => j.body).sort(), ['Alias wartet auf Zuordnung.', 'Neu Mitglied wartet auf Zuordnung.']);
  const calls = [];
  await deliverPush(theater, { sendEachForMulticast: async p => { calls.push(p); return { responses: p.tokens.map(() => ({ success: true })) }; } }, 'https://theater.example');
  assert.ok(calls.length > 0);
  assert.ok(calls.every(p => !p.tokens.includes('token-s')), 'members must not receive admin notifications');
  assert.ok(calls.some(p => new URL(p.webpush.fcmOptions.link).searchParams.get('target') === 'theaterapp://app/accounts/neu'));
  assert.equal(calls.find(p => p.data.accountUid === 'neu').notification.title, 'Neue Registrierung');
});

test('role audiences limit reminders and pushes to invited members', async t => {
  const { store, theater, a } = setup(t); const now = new Date('2026-09-14T12:00:00Z');
  store.put('events', 'e', { id: 'e', title: 'Lichtprobe', startsAt: '2026-09-14T13:30:00Z', roleIds: ['role-light'] });
  store.put('responses', `e:${a.personId}`, { status: 'yes' });
  scheduleReminders(theater, now); assert.equal(store.all('pushJobs').length, 0);
  theater.enqueuePush({ title: 'Termin aktualisiert', body: 'Licht', roleIds: ['role-light'] });
  await deliverPush(theater, { sendEachForMulticast: async () => assert.fail('admin is not invited') });
  assert.equal(store.all('pushJobs').find(j => j.title === 'Termin aktualisiert').status, 'no_devices');
  store.put('members', a.personId, { ...store.get('members', a.personId), roleIds: ['role-light'] });
  scheduleReminders(theater, now); assert.equal(store.all('pushJobs').filter(j => j.title === 'Lichtprobe').length, 1);
});

test('new polls can be pushed once with a polls deep link', async t => {
  const { store, theater } = setup(t);
  let n = 0; const act = body => theater.action('admin', body, `poll-${++n}`);
  for (const j of store.all('pushJobs')) store.delete('pushJobs', j.id);
  const body = { action: 'poll.save', title: 'Probenwochenende', options: [{ label: 'Ja' }, { label: 'Nein' }], closesAt: '2030-06-14T17:00:00Z', push: true };
  const created = act(body);
  assert.equal(created.pushQueued, true);
  const [job] = store.all('pushJobs');
  assert.deepEqual([job.title, job.body, job.data], ['Neue Abstimmung: Probenwochenende', 'Abstimmen bis Fr., 14.06.2030, 19:00 Uhr', { pollId: created.id }]);
  assert.equal(store.all('emailJobs').length, 0);
  assert.deepEqual(act({ ...body, id: created.id, version: 1, title: 'Probenwochenende?' }), { ok: true, id: created.id, pushQueued: false });
  assert.equal(store.all('pushJobs').length, 1, 'edits are never pushed');
  assert.equal(act({ ...body, closesAt: null, push: undefined }).pushQueued, false);
  act({ ...body, title: 'Ohne Frist', closesAt: null });
  assert.equal(store.all('pushJobs').find(j => j.title === 'Neue Abstimmung: Ohne Frist').body, 'Deine Stimme ist gefragt.');
  const calls = [];
  await deliverPush(theater, { sendEachForMulticast: async p => { calls.push(p); return { responses: p.tokens.map(() => ({ success: true })) }; } }, 'https://theater.example');
  const sent = calls.find(p => p.notification?.title === 'Neue Abstimmung: Probenwochenende');
  assert.equal(new URL(sent.webpush.fcmOptions.link).searchParams.get('target'), `theaterapp://app/polls/${created.id}`);
  assert.deepEqual(sent.data, { pollId: created.id });
});

function lateSetup(t) {
  const store = new Store(); t.after(() => store.close());
  const theater = new Theater(store, { pushEnabled: true, emailEnabled: true, bootstrapEmail: 'admin@example.com', clock: () => new Date('2026-09-12T12:00:00Z') });
  theater.session({ uid: 'admin', name: 'Admin', email: 'admin@example.com', email_verified: true });
  let n = 0; const act = (body, uid = 'admin') => theater.action(uid, body, `late-${++n}`);
  const person = (uid, name) => {
    const id = act({ action: 'member.save', name }).id;
    theater.session({ uid, name, email: `${uid}@example.com`, email_verified: true });
    act({ action: 'account.approve', uid, personId: id, version: 1, role: 'member' });
    return id;
  };
  const admin = store.account('admin').personId, sam = person('sam', 'Sam'), director = person('dir', 'Regie'), kim = person('kim', 'Kim');
  store.put('productions', 'winter', { id: 'winter', title: 'Winterstück', roles: [], directorMemberIds: [director], version: 1 });
  const event = startsAt => act({ action: 'event.save', title: 'Probe', startsAt, endsAt: new Date(Date.parse(startsAt) + 7200000).toISOString(), place: 'Saal', productionId: 'winter' }).id;
  const late = () => store.all('pushJobs').filter(j => j.title.startsWith('Kurzfristige Absage'));
  for (const kind of ['pushJobs', 'emailJobs']) for (const j of store.all(kind)) store.delete(kind, j.id);
  return { store, theater, act, admin, sam, director, kim, event, late };
}

test('short-notice declines notify admins and directors without the reason or quick answers', async t => {
  const { store, theater, act, admin, sam, director, event, late } = lateSetup(t);
  const soon = event('2026-09-12T15:00:00Z');
  for (const kind of ['pushJobs', 'emailJobs']) for (const j of store.all(kind)) store.delete(kind, j.id);
  act({ action: 'attendance', eventId: soon, status: 'no', reason: 'Krank' }, 'sam');
  const [job] = late();
  assert.equal(late().length, 1);
  assert.deepEqual(job.recipientPersonIds.sort(), [admin, director].sort());
  assert.ok(!job.recipientPersonIds.includes(sam));
  assert.deepEqual([job.title, job.body, job.data, job.fixedText, job.email], ['Kurzfristige Absage: Probe', 'Sam kommt nicht · Sa., 12.09.2026, 17:00 Uhr · Saal', { eventId: soon }, true, false]);
  assert.ok(!JSON.stringify(job).includes('Krank'));
  assert.equal(store.all('emailJobs').length, 0, 'no email mirror');
  assert.ok(store.get('reminderSent', `${soon}:2026-09-12T15:00:00.000Z:${sam}:lateDecline`));

  theater.device('admin', 'admin-android-token-with-actions', 'android', false, true);
  store.put('responses', `${soon}:${admin}`, { status: 'yes' });
  const calls = [];
  await deliverPush(theater, { sendEachForMulticast: async p => { calls.push(p); return { responses: p.tokens.map(() => ({ success: true })) }; } });
  const android = calls.find(p => p.tokens.includes('admin-android-token-with-actions'));
  assert.equal(android.data.title, 'Kurzfristige Absage: Probe');
  assert.equal(android.data.body, job.body);
  assert.equal(android.data.attendanceActions, undefined);
  assert.equal(android.data.eventId, soon);

  // yes → no → yes → no is announced once.
  act({ action: 'attendance', eventId: soon, status: 'yes' }, 'sam');
  act({ action: 'attendance', eventId: soon, status: 'no' }, 'sam');
  act({ action: 'attendance', eventId: soon, status: 'no', reason: 'Doch nicht' }, 'sam');
  assert.equal(late().length, 1);
});

test('declines further ahead stay quiet; absences and opt-outs are respected', t => {
  const { store, act, admin, sam, director, kim, event, late } = lateSetup(t);
  const later = event('2026-09-15T15:00:00Z');
  act({ action: 'attendance', eventId: later, status: 'no' }, 'sam');
  assert.equal(late().length, 0, 'three days ahead is not short notice');

  // Older clients send the whole record without the new key; the stored opt-out survives.
  act({ action: 'settings.reminders', value: { dayBefore: false, twoHours: true, changes: true, lateDeclines: false } });
  act({ action: 'settings.reminders', value: { dayBefore: true, twoHours: true, changes: true } });
  assert.equal(store.get('reminders', admin).lateDeclines, false);
  assert.equal(store.get('reminders', admin).dayBefore, true);
  act({ action: 'settings.reminders', value: { dayBefore: false } }, 'sam');
  assert.equal(store.get('reminders', sam).lateDeclines, true);

  const soon = event('2026-09-12T20:00:00Z');
  act({ action: 'absence.create', from: '2026-09-12', to: '2026-09-12' }, 'kim');
  assert.deepEqual(late().map(j => j.recipientPersonIds), [[director]]);
  assert.equal(late()[0].body.startsWith('Kim kommt nicht'), true);
  assert.equal(store.get('responses', `${soon}:${kim}`).status, 'no');
  // The director declining is not told about their own decline.
  act({ action: 'attendance', eventId: soon, status: 'no' }, 'dir');
  assert.equal(late().length, 1, 'the only remaining recipient is the director themselves');
});
