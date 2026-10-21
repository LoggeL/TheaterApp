import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures, accountPermissions, can } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { deliverPush } from '../src/push.mjs';

// The right "Termine verwalten" (`permissions: ['events']`) for single member accounts.
const now = new Date('2026-10-19T12:00:00Z');
function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.com', pushEnabled: true, clock: () => now });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.com', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `perm-${++sequence}`);
  const person = (uid, name, roleIds = [], role = 'member') => {
    const id = action({ action: 'member.save', name, roleIds }).id;
    app.session({ uid, name, email: `${uid}@example.com`, email_verified: true });
    action({ action: 'account.approve', uid, personId: id, version: 1, role });
    store.put('devices', uid, { id: uid, uid, token: `token-${uid}`, platform: 'web' });
    return id;
  };
  const admin = store.account('admin').personId;
  const leo = person('leo', 'Leo'), sam = person('sam', 'Sam', ['role-1']), kim = person('kim', 'Kim', ['role-1']);
  const grant = (uid, permissions, by = 'admin') => action({ action: 'account.permissions', uid, permissions, version: store.account(uid).version }, by);
  grant('leo', ['events']);
  const clear = () => { for (const kind of ['pushJobs', 'emailJobs']) for (const j of store.all(kind)) store.delete(kind, j.id); };
  clear();
  // Addressed to the role "Schauspiel" only, so Leo is not invited.
  store.put('events', 'probe', { id: 'probe', title: 'Szenenprobe', startsAt: '2026-10-21T17:00:00Z', endsAt: '2026-10-21T19:00:00Z', place: 'Saal', type: 'rehearsal', roleIds: ['role-1'], personIds: [], productionIds: [], version: 1 });
  return { store, app, action, person, grant, clear, admin, leo, sam, kim };
}

test('the server announces account permissions; admins hold every right', t => {
  const { app } = setup(t);
  assert.ok(apiFeatures.includes('accountPermissions'));
  assert.ok(app.snapshot('leo').capabilities.features.includes('accountPermissions'));
  assert.deepEqual(accountPermissions, ['events']);
  assert.equal(can({ role: 'admin' }, 'events'), true);
  assert.equal(can({ role: 'member', permissions: ['events'] }, 'events'), true);
  assert.equal(can({ role: 'member' }, 'events'), false);
  assert.deepEqual(app.snapshot('leo').user.permissions, ['events']);
  assert.deepEqual(app.snapshot('admin').user.permissions, ['events']);
  assert.deepEqual(app.snapshot('sam').user.permissions, []);
});

test('the profile only names known permissions', t => {
  const { store, app } = setup(t);
  store.saveAccount({ ...store.account('sam'), permissions: ['events', 'foo'] });
  assert.deepEqual(app.snapshot('sam').user.permissions, ['events']);
  assert.deepEqual(app.session({ uid: 'sam', name: 'Sam', email: 'sam@example.com', email_verified: true }).permissions, ['events']);
});

test('only admins grant and revoke; pushes tell the person, repeating is a no-op', t => {
  const { store, action, grant, clear, leo, sam } = setup(t);
  assert.deepEqual(store.account('leo').permissions, ['events']);
  assert.equal(store.account('leo').permissionsChangedBy, 'admin');
  // Holders and members cannot hand out (or take back) rights, also not their own.
  assert.throws(() => grant('sam', ['events'], 'leo'), { status: 403 });
  assert.throws(() => grant('leo', [], 'leo'), { status: 403 });
  assert.throws(() => grant('sam', ['events'], 'sam'), { status: 403 });
  assert.throws(() => grant('admin', ['events']), { status: 409, code: 'admin_has_all' });
  assert.throws(() => grant('sam', ['foo']), { status: 400 });
  assert.throws(() => action({ action: 'account.permissions', uid: 'sam', permissions: 'events', version: store.account('sam').version }), { status: 400 });
  assert.throws(() => action({ action: 'account.permissions', uid: 'sam', permissions: ['events'], version: 99 }), { status: 409, code: 'version_conflict' });

  clear();
  grant('sam', ['events', 'events']);
  assert.deepEqual(store.account('sam').permissions, ['events']);
  let [push, ...more] = store.all('pushJobs');
  assert.deepEqual(more, []);
  assert.deepEqual([push.title, push.body, push.recipientPersonIds], ['Termine verwalten freigeschaltet', 'Du kannst jetzt Termine anlegen, ändern und Rückmeldungen einsehen.', [sam]]);
  const version = store.account('sam').version;
  clear();
  grant('sam', ['events']);
  assert.equal(store.account('sam').version, version, 'same set: nothing changes');
  assert.equal(store.all('pushJobs').length, 0);

  grant('leo', []);
  assert.deepEqual(store.account('leo').permissions, []);
  [push, ...more] = store.all('pushJobs');
  assert.deepEqual(more, []);
  assert.deepEqual([push.title, push.body, push.recipientPersonIds], ['Termine-Recht entzogen', 'Du kannst keine Termine mehr verwalten.', [leo]]);
  const audit = store.db.prepare("SELECT actor, subject FROM audit WHERE action = 'account.permissions'").all().map(x => ({ ...x }));
  assert.deepEqual(audit.at(-1), { actor: 'admin', subject: 'leo' });
});

test('rights need a linked account; suspended accounts keep them and can lose them, rejected ones lose them', t => {
  const { store, app, action, grant, clear } = setup(t);
  app.session({ uid: 'neu', name: 'Neu', email: 'neu@example.com', email_verified: true });
  assert.throws(() => grant('neu', ['events']), { status: 409 });

  action({ action: 'account.status', uid: 'leo', status: 'suspended', version: store.account('leo').version });
  assert.deepEqual(store.account('leo').permissions, ['events'], 'suspending keeps the rights');
  assert.throws(() => app.snapshot('leo'), { status: 403 });
  // Revoking still works while suspended, quietly: the person has no access anyway.
  clear();
  grant('leo', []);
  assert.deepEqual(store.account('leo').permissions, []);
  assert.equal(store.all('pushJobs').length, 0);
  grant('leo', ['events']);
  action({ action: 'account.status', uid: 'leo', status: 'approved', version: store.account('leo').version });
  assert.deepEqual(app.snapshot('leo').user.permissions, ['events'], 'back with the right granted while suspended');

  action({ action: 'account.status', uid: 'leo', status: 'rejected', version: store.account('leo').version });
  assert.deepEqual(store.account('leo').permissions, []);
  assert.throws(() => grant('leo', ['events']), { status: 409 });
  // Rejected with a person, it can come back; without its old rights.
  action({ action: 'account.status', uid: 'leo', status: 'approved', version: store.account('leo').version });
  assert.deepEqual(app.snapshot('leo').user.permissions, []);
});

test('approval, role changes and reconsidering set or reset the rights', t => {
  const { store, app, action, grant, clear } = setup(t);
  const approve = (uid, name, extra) => {
    const id = action({ action: 'member.save', name }).id;
    app.session({ uid, name, email: `${uid}@example.com`, email_verified: true });
    action({ action: 'account.approve', uid, personId: id, version: store.account(uid).version, ...extra });
    return id;
  };
  approve('mia', 'Mia', { role: 'member', permissions: ['events'] });
  assert.deepEqual(store.account('mia').permissions, ['events']);
  approve('ole', 'Ole', { role: 'admin', permissions: ['events'] });
  assert.deepEqual(store.account('ole').permissions, []);
  approve('ada', 'Ada', { role: 'member' });
  assert.deepEqual(store.account('ada').permissions, [], 'older apps send none');
  app.session({ uid: 'bad', name: 'Bad', email: 'bad@example.com', email_verified: true });
  const badId = action({ action: 'member.save', name: 'Bad' }).id;
  assert.throws(() => action({ action: 'account.approve', uid: 'bad', personId: badId, version: store.account('bad').version, role: 'member', permissions: ['foo'] }), { status: 400 });

  const setRole = (uid, role, extra = {}) => action({ action: 'account.role', uid, role, version: store.account(uid).version, ...extra });
  setRole('mia', 'admin');
  assert.deepEqual(store.account('mia').permissions, [], 'promoting clears');
  assert.deepEqual(app.snapshot('mia').user.permissions, ['events']);
  clear();
  setRole('mia', 'member', { permissions: ['events'] });
  assert.deepEqual(store.account('mia').permissions, ['events']);
  assert.equal(store.all('pushJobs')[0].body, 'Dein Zugang gilt jetzt als Mitglied mit dem Recht „Termine verwalten“.');
  setRole('mia', 'admin');
  clear();
  setRole('mia', 'member');
  assert.deepEqual(store.account('mia').permissions, [], 'older apps demote without rights');
  assert.equal(store.all('pushJobs')[0].body, 'Dein Zugang gilt jetzt als Mitglied.');

  grant('sam', ['events']);
  // A rejected account that is reconsidered starts from scratch (legacy records may still carry rights).
  action({ action: 'account.status', uid: 'sam', status: 'rejected', version: store.account('sam').version });
  store.saveAccount({ ...store.account('sam'), permissions: ['events'] });
  action({ action: 'account.reconsider', uid: 'sam', version: store.account('sam').version });
  assert.equal(store.account('sam').status, 'pending');
  assert.deepEqual(store.account('sam').permissions, []);
});

test('holders plan and run all events, series and Terminfinder', t => {
  const { store, app, action, sam, kim, leo } = setup(t);
  const as = body => action(body, 'leo');
  const id = as({ action: 'event.save', title: 'Leseprobe', startsAt: '2026-10-22T17:00:00Z', endsAt: '2026-10-22T19:00:00Z', roleIds: ['role-1'], push: true }).id;
  assert.equal(store.get('events', id).createdBy, leo);
  const series = as({ action: 'event.save', title: 'Probe', startsAt: '2026-10-27T17:00:00Z', endsAt: '2026-10-27T19:00:00Z', roleIds: ['role-1'], repeat: { every: 'week', until: '2026-11-24' } });
  assert.equal(series.ids.length, 5);
  const second = store.get('events', series.ids[1]);
  const following = as({ action: 'event.save', ...second, id: second.id, version: second.version, title: 'Hauptprobe', series: 'following' });
  assert.equal(following.ids.length, 4);
  assert.equal(store.get('events', series.ids[4]).updatedBy, leo);
  as({ action: 'event.delete', id: series.ids[3], version: store.get('events', series.ids[3]).version, series: 'following' });
  assert.equal(store.all('events').filter(e => e.seriesId === second.seriesId).length, 3);
  // The holder is not invited to "probe", yet runs it like an admin.
  const details = app.eventDetails('leo', 'probe');
  assert.deepEqual(details.invitedIds.sort(), [sam, kim].sort());
  assert.equal(as({ action: 'event.remindOpen', eventId: 'probe' }).recipients, 2);
  as({ action: 'checkin.save', eventId: 'probe', members: [{ id: sam, present: true, version: 0 }] });
  assert.equal(store.get('checkins', `probe:${sam}`).present, true);
  store.put('productions', 'winter', { id: 'winter', title: 'Winterstück', roles: [], version: 1 });
  store.put('scripts', 'winter', { revision: 'r1', scenes: [{ id: 's1' }], cues: [], roles: [] });
  as({ action: 'event.script', eventId: 'probe', productionId: 'winter', sceneIds: ['s1'], version: 1 });
  assert.deepEqual(store.get('events', 'probe').sceneIds, ['s1']);
  assert.equal(store.get('events', 'probe').updatedBy, leo);

  const slot = (start, capacity = 1) => ({ startsAt: `2026-10-25T${start}:00Z`, endsAt: `2026-10-25T${start.slice(0, 3)}${String(+start.slice(3) + 15).padStart(2, '0')}:00Z`, capacity });
  const poolId = as({ action: 'slotPool.save', title: 'Fototermin', place: 'Kolpingheim', roleIds: ['role-1'], slots: [slot('10:00'), slot('10:15', 2)] }).id;
  let pool = store.get('slotPools', poolId);
  assert.deepEqual([pool.createdBy, pool.updatedBy], [leo, leo]);
  assert.equal(as({ action: 'slotPool.remindOpen', id: poolId }).recipients, 2);
  as({ action: 'slot.assign', poolId, personId: sam, slotId: pool.slots[0].id });
  assert.equal(store.get('slotBookings', `${poolId}:${sam}`).slotId, pool.slots[0].id);
  as({ action: 'slotPool.close', id: poolId, version: pool.version });
  pool = store.get('slotPools', poolId);
  assert.equal(pool.closed, true);
  as({ action: 'slotPool.delete', id: poolId, version: pool.version });
  assert.equal(store.get('slotPools', poolId), null);
  as({ action: 'event.delete', id, version: store.get('events', id).version });
  assert.equal(store.get('events', id), null);
});

test('holders stay out of everything else; plain members cannot edit events', async t => {
  const { store, app, action, sam } = setup(t);
  const as = body => action(body, 'leo');
  const forbidden = [
    { action: 'message.send', title: 'X', body: 'X', audience: 'all' },
    { action: 'push.send', title: 'X', body: 'X', audience: 'all' },
    { action: 'poll.save', title: 'Frage', options: [{ label: 'Ja' }, { label: 'Nein' }] },
    { action: 'member.save', name: 'Neu' },
    { action: 'personRole.save', name: 'Requisite' },
    { action: 'production.save', title: 'Sommerstück' },
    { action: 'production.scopeEvents', productionId: 'winter' },
    { action: 'account.approve', uid: 'sam', personId: sam, version: 1, role: 'member' },
    { action: 'account.role', uid: 'sam', role: 'admin', version: store.account('sam').version },
    { action: 'account.status', uid: 'sam', status: 'suspended', version: store.account('sam').version },
  ];
  for (const body of forbidden) assert.throws(() => as(body), { status: 403 }, body.action);
  assert.throws(() => app.adminData('leo'), { status: 403 });
  assert.throws(() => app.importScript('leo', { id: 'x' }, { revision: 'r', cues: [], scenes: [], roles: [] }), { status: 403 });
  await assert.rejects(() => app.deleteAccount('leo', 'sam', store.account('sam').version), { status: 403 });
  assert.equal(app.participation('leo').people, undefined);
  assert.ok(app.participation('admin').people);

  // This closes the gap for everyone else.
  assert.throws(() => action({ action: 'event.save', title: 'X', startsAt: '2026-10-22T17:00:00Z', endsAt: '2026-10-22T19:00:00Z' }, 'sam'), { status: 403, message: 'Hierfür fehlt das Recht „Termine verwalten“.', code: 'forbidden' });
  assert.throws(() => action({ action: 'event.delete', id: 'probe', version: 1 }, 'sam'), { status: 403 });
  assert.throws(() => app.eventDetails('sam', 'probe'), { status: 403 });
  assert.ok(store.get('events', 'probe'));
});

test('the holder snapshot carries event data but no admin data', t => {
  const { app, action, sam } = setup(t);
  action({ action: 'attendance', eventId: 'probe', status: 'no', reason: 'Urlaub' }, 'sam');
  action({ action: 'checkin.save', eventId: 'probe', members: [{ id: sam, present: false, version: 0 }] });
  action({ action: 'event.remindOpen', eventId: 'probe' });
  action({ action: 'message.send', title: 'Info', body: 'Text', audience: 'all' });
  action({ action: 'poll.save', title: 'Frage', options: [{ label: 'Ja' }, { label: 'Nein' }] });
  const poolId = action({ action: 'slotPool.save', title: 'Fototermin', roleIds: ['role-1'], slots: [{ startsAt: '2026-10-25T10:00:00Z', endsAt: '2026-10-25T10:15:00Z', capacity: 1 }] }).id;
  app.session({ uid: 'neu', name: 'Neu', email: 'neu@example.com', email_verified: true });

  const snap = app.snapshot('leo');
  const probe = snap.events.find(e => e.id === 'probe');
  assert.equal(probe.addressedToMe, false);
  assert.ok(probe.lastRemindedAt);
  assert.equal(snap.memberAttendanceByEvent.probe[sam], 'no');
  assert.equal(snap.checkinsByEvent.probe[sam], false);
  assert.equal(snap.checkinVersions[`probe:${sam}`], 1);
  const pool = snap.slotPools.find(p => p.id === poolId);
  assert.equal(pool.addressedToMe, false);
  assert.ok('lastRemindedAt' in pool);
  assert.ok(snap.polls.every(p => p.eligibleCount === undefined));
  assert.ok(snap.messages.every(m => m.recipientIds === undefined && m.readerIds === undefined && m.lastRemindedAt === undefined));
  assert.deepEqual(snap.pendingAccounts, []);
  assert.deepEqual(snap.capabilities, app.snapshot('sam').capabilities);
  assert.ok(app.snapshot('admin').pendingAccounts.length > 0);
  // Plain members see neither the event nor other people's answers.
  const member = app.snapshot('kim');
  assert.deepEqual(member.memberAttendanceByEvent, {});
  assert.deepEqual(member.checkinsByEvent, {});
  assert.equal(member.events.find(e => e.id === 'probe').lastRemindedAt, undefined);
});

test('holders see implicit attendees but cannot answer events they are not invited to', t => {
  const { store, app, action, sam, kim } = setup(t);
  store.put('events', 'probe', { ...store.get('events', 'probe'), autoAccept: true });
  action({ action: 'attendance', eventId: 'probe', status: 'no', reason: 'Urlaub' }, 'sam');
  assert.deepEqual(app.snapshot('leo').implicitAttendanceByEvent.probe, [kim]);
  assert.deepEqual(app.snapshot('leo').memberAttendanceByEvent.probe, { [sam]: 'no' });
  assert.deepEqual(app.snapshot('kim').implicitAttendanceByEvent, {});
  // Managing events is no invitation: a stray answer would count Leo as attending.
  assert.throws(() => action({ action: 'attendance', eventId: 'probe', status: 'yes' }, 'leo'), { status: 404 });
  assert.equal(store.all('responses').some(r => r.eventId === 'probe' && r.personId !== sam), false);
});

test('who created and changed an event is only shown to those who manage events', t => {
  const { store, app, action, leo } = setup(t);
  const id = action({ action: 'event.save', title: 'Probe', startsAt: '2026-10-22T17:00:00Z', endsAt: '2026-10-22T19:00:00Z' }, 'leo').id;
  action({ ...store.get('events', id), action: 'event.save', title: 'Probe neu' });
  const admin = store.account('admin').personId;
  assert.deepEqual([store.get('events', id).createdBy, store.get('events', id).updatedBy], [leo, admin]);
  const seen = app.snapshot('leo').events.find(e => e.id === id);
  assert.deepEqual([seen.createdBy, seen.updatedBy], [leo, admin]);
  const plain = app.snapshot('sam').events.find(e => e.id === id);
  assert.equal('createdBy' in plain, false);
  assert.equal('updatedBy' in plain, false);
  // Older events without a creator stay without one.
  action({ ...store.get('events', 'probe'), action: 'event.save', title: 'Szenenprobe 2' }, 'leo');
  assert.deepEqual([store.get('events', 'probe').createdBy, store.get('events', 'probe').updatedBy], [null, leo]);
});

test('event details list only the absences of invited people', t => {
  const { app, action, sam } = setup(t);
  action({ action: 'absence.create', from: '2026-10-21', to: '2026-10-21', reason: 'Arzttermin' }, 'sam');
  action({ action: 'absence.create', from: '2026-10-20', to: '2026-10-22', reason: 'Privat' }, 'leo');
  for (const uid of ['leo', 'admin']) {
    const details = app.eventDetails(uid, 'probe');
    assert.deepEqual(details.absences.map(x => x.personId), [sam]);
    assert.deepEqual(details.absentIds, [sam]);
    assert.ok(!JSON.stringify(details).includes('Privat'));
  }
});

test('short-notice declines reach holders, who can switch them off', t => {
  const { store, action, admin, leo, clear } = setup(t);
  const soon = action({ action: 'event.save', title: 'Probe', startsAt: '2026-10-20T08:00:00Z', endsAt: '2026-10-20T10:00:00Z', roleIds: ['role-1'] }).id;
  clear();
  action({ action: 'attendance', eventId: soon, status: 'no' }, 'sam');
  const late = () => store.all('pushJobs').filter(j => j.pushKind === 'lateDeclines');
  assert.deepEqual(late()[0].recipientPersonIds.sort(), [admin, leo].sort());
  action({ action: 'settings.reminders', value: { lateDeclines: false } }, 'leo');
  clear();
  action({ action: 'attendance', eventId: soon, status: 'no' }, 'kim');
  assert.deepEqual(late()[0].recipientPersonIds, [admin]);
});

test('admin-only pushes skip holders', async t => {
  const { store, app } = setup(t);
  store.put('devices', 'admin', { id: 'admin', uid: 'admin', token: 'token-admin', platform: 'web' });
  app.session({ uid: 'neu', name: 'Neu', email: 'neu@example.com', email_verified: true });
  const sent = [];
  await deliverPush(app, { sendEachForMulticast: async p => { sent.push(p); return { responses: p.tokens.map(() => ({ success: true })) }; } });
  const registration = sent.filter(p => p.notification?.title === 'Neue Registrierung' || p.data?.title === 'Neue Registrierung');
  assert.equal(registration.length, 1);
  assert.deepEqual(registration[0].tokens, ['token-admin']);
});

test('HTTP: holders read event details but no admin endpoints', async t => {
  const { app } = setup(t);
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token, email: `${token}@example.com`, email_verified: true }) });
  await new Promise(r => server.listen(0, '127.0.0.1', r));
  t.after(() => new Promise(r => server.close(r)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  const get = (path, uid) => fetch(`${base}${path}`, { headers: { Authorization: `Bearer ${uid}` } });
  assert.equal((await get('/admin/events/probe', 'leo')).status, 200);
  assert.equal((await get('/admin/events/probe', 'sam')).status, 403);
  for (const path of ['/admin/accounts', '/admin/push', '/admin/email', '/admin/script-source', '/admin/feedback']) assert.equal((await get(path, 'leo')).status, 403, path);
  assert.equal((await get('/admin/accounts', 'admin')).status, 200);
});
