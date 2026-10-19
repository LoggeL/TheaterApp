import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { CalendarFeedLimiter, calendarFeed, calendarFeedEvents, calendarFeedLimits, calendarFeedLink, icsFold, icsText, resetCalendarFeed } from '../src/calendar-feed.mjs';

const origin = 'https://app.example.invalid';
function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const clock = { now: new Date('2026-10-19T12:00:00Z') };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.now });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `calendar-${++sequence}`);
  const person = (uid, name) => {
    const id = action({ action: 'member.save', name }).id;
    app.session({ uid, name, email: `${uid}@example.invalid`, email_verified: true });
    action({ action: 'account.approve', uid, personId: id, version: 1, role: 'member' });
    return id;
  };
  const sam = person('sam', 'Sam'), kim = person('kim', 'Kim');
  const event = (extra = {}) => action({ action: 'event.save', title: 'Probe', startsAt: '2026-10-25T17:00:00Z', endsAt: '2026-10-25T19:00:00Z', place: 'Pfarrheim', ...extra }).id;
  const feedIds = personId => calendarFeedEvents(app, personId).map(e => e.id);
  return { store, app, clock, action, sam, kim, event, feedIds };
}

async function serve(t, app, options = {}) {
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }), appOrigin: origin, ...options });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const api = async (uid, method, path) => {
    const response = await fetch(`${base}/api/mobile/v1${path}`, { method, headers: uid ? { Authorization: `Bearer ${uid}` } : {} });
    return { status: response.status, body: await response.json() };
  };
  // Calendar apps fetch the public address without any sign-in.
  const feed = async (url, headers = {}, method = 'GET') => {
    const response = await fetch(`${base}${new URL(url).pathname}`, { method, headers });
    return { status: response.status, headers: response.headers, text: await response.text() };
  };
  return { api, feed, base };
}
const unfold = ics => ics.replace(/\r\n /g, '');
const events = ics => unfold(ics).split('BEGIN:VEVENT').slice(1).map(x => x.split('END:VEVENT')[0]);
const prop = (vevent, name) => vevent.split('\r\n').find(l => l.startsWith(`${name}:`))?.slice(name.length + 1);

test('the server announces the calendar feed as a feature', t => {
  const { app } = setup(t);
  assert.ok(apiFeatures.includes('calendarFeed'));
  assert.ok(app.snapshot('sam').capabilities.features.includes('calendarFeed'));
});

test('a link is created once, kept and replaced on request; the old link stops at once', async t => {
  const { app, store } = setup(t);
  const { api, feed } = await serve(t, app);
  assert.equal((await api(null, 'GET', '/calendar-feed')).status, 401);
  const first = await api('sam', 'GET', '/calendar-feed');
  assert.equal(first.status, 200);
  assert.match(first.body.url, /^https:\/\/app\.example\.invalid\/api\/calendar\/[A-Za-z0-9_-]{32}\.ics$/);
  assert.ok(first.body.createdAt);
  assert.deepEqual((await api('sam', 'GET', '/calendar-feed')).body, first.body, 'the same link on every device');
  assert.notEqual((await api('kim', 'GET', '/calendar-feed')).body.url, first.body.url, 'one link per account');
  // Stored under the hash of the token, one record per account.
  const records = store.all('calendarFeeds').filter(f => f.uid === 'sam');
  assert.equal(records.length, 1);
  assert.notEqual(records[0].id, records[0].token);
  assert.equal((await feed(first.body.url)).status, 200);
  const second = await api('sam', 'POST', '/calendar-feed/reset');
  assert.equal(second.status, 200);
  assert.notEqual(second.body.url, first.body.url);
  assert.equal((await feed(first.body.url)).status, 404);
  assert.equal((await feed(second.body.url)).status, 200);
  assert.deepEqual((await api('sam', 'GET', '/calendar-feed')).body.url, second.body.url);
  assert.equal(store.all('calendarFeeds').filter(f => f.uid === 'sam').length, 1);
  const audit = store.db.prepare("SELECT actor, subject FROM audit WHERE action = 'calendarFeed.reset'").all();
  assert.deepEqual(audit.map(x => ({ ...x })), [{ actor: 'sam', subject: 'sam' }]);
});

test('without a configured app address there is no link', async t => {
  const { app } = setup(t);
  const { api } = await serve(t, app, { appOrigin: null });
  const result = await api('sam', 'GET', '/calendar-feed');
  assert.equal(result.status, 409);
  assert.equal(result.body.code, 'calendar_unavailable');
  assert.throws(() => calendarFeedLink(app, 'sam', 'http://theater.example.invalid'), { status: 409 }, 'plain HTTP only locally');
  assert.match(calendarFeedLink(app, 'sam', 'http://127.0.0.1:8787').url, /^http:\/\/127\.0\.0\.1:8787\/api\/calendar\//);
});

test('unknown tokens, blocked, deleted and unapproved accounts all get a plain 404', async t => {
  const { app, store, action } = setup(t);
  const { api, feed, base } = await serve(t, app);
  const url = (await api('sam', 'GET', '/calendar-feed')).body.url;
  const notFound = async target => { const r = await feed(target); assert.equal(r.status, 404, target); assert.deepEqual(JSON.parse(r.text), { error: 'Nicht gefunden.', code: 'not_found' }); };
  await notFound(`${base}/api/calendar/${'A'.repeat(32)}.ics`);
  await notFound(`${base}/api/calendar/short.ics`);
  await notFound(url.replace(/\.ics$/, 'x.ics'));
  // Suspended: no feed; approved again: the same link works again.
  action({ action: 'account.status', uid: 'sam', status: 'suspended', version: store.account('sam').version });
  await notFound(url);
  action({ action: 'account.status', uid: 'sam', status: 'approved', version: store.account('sam').version });
  assert.equal((await feed(url)).status, 200);
  // A deactivated person.
  const member = store.get('members', store.account('sam').personId);
  store.put('members', member.id, { ...member, active: false });
  await notFound(url);
  store.put('members', member.id, member);
  // A link stays bound to the person it was created for.
  const relinked = store.account('sam');
  store.saveAccount({ ...relinked, personId: action({ action: 'member.save', name: 'Lou' }).id });
  await notFound(url);
  store.saveAccount(relinked);
  assert.equal((await feed(url)).status, 200);
  // Deleting the account removes its link.
  await app.deleteAccount('admin', 'sam', store.account('sam').version);
  await notFound(url);
  assert.deepEqual(store.all('calendarFeeds').filter(f => f.uid === 'sam'), []);
  // Waiting accounts cannot get a link.
  app.session({ uid: 'new', name: 'Neu', email: 'new@example.invalid', email_verified: true });
  assert.equal((await api('new', 'GET', '/calendar-feed')).status, 403);
  assert.equal(calendarFeed(app, null), null);
});

test('the feed holds invited events that are not declined, from 60 days ago on', t => {
  const { app, action, sam, kim, event, feedIds } = setup(t);
  const open = event({ title: 'Offen', startsAt: '2026-10-24T17:00:00Z' });
  const yes = event({ title: 'Zugesagt', startsAt: '2026-10-25T16:00:00Z' });
  action({ action: 'attendance', eventId: yes, status: 'yes' }, 'sam');
  const late = event({ title: 'Später' });
  action({ action: 'attendance', eventId: late, status: 'late' }, 'sam');
  const declined = event({ title: 'Abgesagt' });
  action({ action: 'attendance', eventId: declined, status: 'no', reason: 'Krank' }, 'sam');
  const other = event({ title: 'Nur Kim', personIds: [kim] });
  const named = event({ title: 'Mit Sam', personIds: [sam], startsAt: '2026-10-25T18:00:00Z' });
  const deleted = event({ title: 'Gelöscht' });
  action({ action: 'event.delete', id: deleted, version: 1 });
  const recent = event({ title: 'Vor 59 Tagen', startsAt: '2026-08-21T10:00:00Z', endsAt: '2026-08-21T12:00:00Z' });
  const old = event({ title: 'Vor 61 Tagen', startsAt: '2026-08-19T10:00:00Z', endsAt: '2026-08-19T12:00:00Z' });
  const far = event({ title: 'Nächstes Jahr', startsAt: '2028-01-10T18:00:00Z', endsAt: '2028-01-10T20:00:00Z' });
  const ids = feedIds(sam);
  for (const id of [open, yes, late, named, recent, far]) assert.ok(ids.includes(id), id);
  for (const id of [declined, other, deleted, old]) assert.ok(!ids.includes(id), id);
  assert.deepEqual(ids, [recent, open, yes, late, named, far], 'sorted by start');
  // Admins see every event in the app, but their feed only holds what they are invited to.
  assert.ok(!feedIds(app.account('admin').personId).includes(other));
});

test('absences count as declines; an explicit yes despite an absence stays', t => {
  const { action, sam, event, feedIds } = setup(t);
  const before = event({ title: 'Vor der Abwesenheit' });
  const locked = event({ title: 'Gesperrt', locked: true, startsAt: '2026-11-02T17:00:00Z', endsAt: '2026-11-02T19:00:00Z' });
  action({ action: 'absence.create', from: '2026-10-25', to: '2026-11-03', reason: 'Urlaub' }, 'sam');
  const after = event({ title: 'Nach der Abwesenheit angelegt', startsAt: '2026-11-01T17:00:00Z', endsAt: '2026-11-01T19:00:00Z' });
  const confirmed = event({ title: 'Trotzdem dabei', startsAt: '2026-10-30T17:00:00Z', endsAt: '2026-10-30T19:00:00Z' });
  action({ action: 'attendance', eventId: confirmed, status: 'yes' }, 'sam');
  const outside = event({ title: 'Danach', startsAt: '2026-11-04T17:00:00Z', endsAt: '2026-11-04T19:00:00Z' });
  const ids = feedIds(sam);
  // `before` and `after` got an automatic decline; `locked` none, the absence still covers its day.
  for (const id of [before, after, locked]) assert.ok(!ids.includes(id), id);
  assert.deepEqual(ids, [confirmed, outside]);
});

test('the iCalendar text follows RFC 5545: CRLF, folding, escaping, UID and SEQUENCE, no alarms', t => {
  const { app, store, action, sam, event } = setup(t);
  store.put('productions', 'winter', { id: 'winter', title: 'Winterstück', roles: [], casting: {}, directorMemberIds: [], memberIds: [], version: 1 });
  const long = 'Ä'.repeat(50) + '🎭'.repeat(10) + ' Ende';
  const id = event({ title: 'Probe, Akt 1; Szene\\2', description: `Bitte Text können.\nZweite Zeile, mit Komma; ${long}`, place: 'Pfarrheim, Saal', productionId: 'winter' });
  const plain = event({ title: 'Winterstück: Hauptprobe', productionId: 'winter', place: '' });
  const result = calendarFeed(app, calendarFeedLink(app, 'sam', origin).url.match(/calendar\/(.+)\.ics$/)[1], { appOrigin: origin });
  const ics = result.body;
  assert.ok(ics.endsWith('END:VCALENDAR\r\n'));
  assert.ok(!/[^\r]\n/.test(ics), 'only CRLF line breaks');
  for (const line of ics.split('\r\n')) {
    assert.ok(Buffer.byteLength(line) <= 75, line);
    assert.ok(!line.includes('�'));
  }
  assert.ok(!ics.includes('VALARM'));
  for (const header of ['VERSION:2.0', 'PRODID:-//Kolpingtheater Ramsen//Theater-App//DE', 'X-WR-CALNAME:Kolpingtheater Ramsen', 'X-WR-TIMEZONE:Europe/Berlin', 'REFRESH-INTERVAL;VALUE=DURATION:PT1H', 'X-PUBLISHED-TTL:PT1H']) assert.ok(ics.includes(`\r\n${header}\r\n`), header);
  const byId = x => events(ics).find(v => prop(v, 'UID') === `${x}@kolpingtheater.ramsen`);
  const first = byId(id), second = byId(plain);
  assert.equal(prop(first, 'UID'), `${id}@kolpingtheater.ramsen`);
  assert.equal(prop(first, 'SEQUENCE'), '0');
  assert.equal(prop(first, 'DTSTART'), '20261025T170000Z');
  assert.equal(prop(first, 'DTEND'), '20261025T190000Z');
  assert.match(prop(first, 'DTSTAMP'), /^\d{8}T\d{6}Z$/);
  assert.equal(prop(first, 'LAST-MODIFIED'), prop(first, 'DTSTAMP'));
  assert.equal(prop(first, 'SUMMARY'), 'Probe\\, Akt 1\\; Szene\\\\2 · Winterstück');
  assert.equal(prop(first, 'LOCATION'), 'Pfarrheim\\, Saal');
  const link = `${origin}/?target=theaterapp%3A%2F%2Fapp%2Fevents%2F${id}`;
  assert.equal(prop(first, 'DESCRIPTION'), `Bitte Text können.\\nZweite Zeile\\, mit Komma\\; ${long}\\n\\nIn der Theater-App öffnen: ${link}`);
  assert.equal(prop(first, 'URL'), link);
  // The production title is not repeated, and an empty place is left out.
  assert.equal(prop(second, 'SUMMARY'), 'Winterstück: Hauptprobe');
  assert.equal(prop(second, 'LOCATION'), undefined);
  // An edit raises SEQUENCE.
  action({ action: 'event.save', id, version: 1, title: 'Probe', startsAt: '2026-10-25T18:00:00Z', endsAt: '2026-10-25T20:00:00Z' });
  const token = store.all('calendarFeeds').find(f => f.uid === 'sam').token;
  const edited = events(calendarFeed(app, token, { appOrigin: origin }).body).find(v => prop(v, 'UID').startsWith(id));
  assert.equal(prop(edited, 'SEQUENCE'), '1');
  assert.equal(prop(edited, 'DTSTART'), '20261025T180000Z');
  assert.ok(sam);
});

test('folding never splits a character and escaping covers every special', () => {
  const line = `SUMMARY:${'aä🎭'.repeat(40)}`;
  const folded = icsFold(line);
  assert.equal(folded.replace(/\r\n /g, ''), line);
  for (const part of folded.split('\r\n')) assert.ok(Buffer.byteLength(part) <= 75);
  assert.equal(icsFold('X:kurz'), 'X:kurz');
  assert.equal(icsText('a\\b;c,d\r\ne\nf\rg\u0007'), 'a\\\\b\\;c\\,d\\ne\\nf\\ng');
});

test('the public route serves text/calendar with an ETag, answers HEAD and 304', async t => {
  const { app, event } = setup(t);
  event();
  const { api, feed } = await serve(t, app);
  const url = (await api('sam', 'GET', '/calendar-feed')).body.url;
  const first = await feed(url);
  assert.equal(first.status, 200);
  assert.equal(first.headers.get('content-type'), 'text/calendar; charset=utf-8');
  assert.match(first.headers.get('cache-control'), /^private/);
  assert.ok(first.text.startsWith('BEGIN:VCALENDAR\r\n'));
  const etag = first.headers.get('etag');
  assert.ok(etag);
  assert.equal((await feed(url, { 'If-None-Match': etag })).status, 304);
  assert.equal((await feed(url)).headers.get('etag'), etag, 'stable between requests');
  event({ title: 'Neu' });
  const changed = await feed(url, { 'If-None-Match': etag });
  assert.equal(changed.status, 200);
  assert.notEqual(changed.headers.get('etag'), etag);
  const head = await feed(url, {}, 'HEAD');
  assert.equal(head.status, 200);
  assert.equal(head.text, '');
  assert.equal((await feed(url, {}, 'POST')).status, 404);
});

test('unknown tokens are limited per address without blocking valid links', async t => {
  const { app } = setup(t);
  const { api, feed, base } = await serve(t, app);
  const url = (await api('sam', 'GET', '/calendar-feed')).body.url;
  for (let i = 0; i < calendarFeedLimits.clientMisses; i++) assert.equal((await feed(`${base}/api/calendar/${String(i).padStart(32, 'x')}.ics`)).status, 404);
  const limited = await feed(`${base}/api/calendar/${'y'.repeat(32)}.ics`);
  assert.equal(limited.status, 429);
  assert.ok(Number(limited.headers.get('retry-after')) > 0);
  assert.equal((await feed(url)).status, 200);
});

test('the limiter counts per key within its window', () => {
  let now = 0;
  const limiter = new CalendarFeedLimiter({ clock: () => now });
  for (let i = 0; i < calendarFeedLimits.tokenRequests; i++) assert.equal(limiter.token('a'), 0);
  assert.ok(limiter.token('a') > 0);
  assert.equal(limiter.token('b'), 0);
  now += calendarFeedLimits.windowMs + 1;
  assert.equal(limiter.token('a'), 0);
});

test('resetting needs an approved account', t => {
  const { app } = setup(t);
  app.session({ uid: 'new', name: 'Neu', email: 'new@example.invalid', email_verified: true });
  assert.throws(() => resetCalendarFeed(app, 'new', origin), { status: 403 });
});
