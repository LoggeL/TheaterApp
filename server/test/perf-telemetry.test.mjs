import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { PerfTelemetry, perfTelemetry, sanitizePerfReport, serverEdges } from '../src/perf-telemetry.mjs';
import { purgeExpired, retention } from '../src/retention.mjs';
import { dedupeReports, histQuantile, perfReport, throttled } from '../scripts/perf-report.mjs';
import { android, chromePwa, fixtureReports, hist, runnerWeb, safari } from './fixtures/perf-reports.mjs';

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const clock = { now: new Date('2026-10-24T12:00:00Z') };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.now });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `perf-${++sequence}`);
  const personId = action({ action: 'member.save', name: 'Sam Beispiel' }).id;
  app.session({ uid: 'sam', name: 'Sam', email: 'sam@example.invalid', email_verified: true });
  action({ action: 'account.approve', uid: 'sam', personId, version: 1, role: 'member' });
  app.session({ uid: 'pending', name: 'Neu', email: 'pending@example.invalid', email_verified: true });
  const perf = new PerfTelemetry(store, { clock: () => +clock.now });
  const rows = () => store.db.prepare('SELECT * FROM perf_reports ORDER BY id').all();
  return { store, app, clock, perf, rows, personId };
}

async function serve(t, app, options = {}) {
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }), ...options });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  return async (uid, body) => {
    const response = await fetch(`${base}/api/mobile/v1/telemetry/perf/`, { method: 'POST', headers: { 'Content-Type': 'application/json', ...(uid ? { Authorization: `Bearer ${uid}` } : {}) }, body: typeof body === 'string' ? body : JSON.stringify(body) });
    return { status: response.status, text: await response.text() };
  };
}

test('servers announce the telemetry and promise its retention', async () => {
  assert.ok(apiFeatures.includes('perfTelemetry'));
  assert.equal(retention.perfReportDays, 30);
  const privacy = await readFile(new URL('../../web/privacy.html', import.meta.url), 'utf8');
  assert.match(privacy, /id="leistungsmessung"[^]*nach 30 Tagen gelöscht/);
  assert.match(privacy, /Berichte der Leistungsmessung nach 30 Tagen/);
  // The opt-out in the app's settings is the way to object.
  assert.match(privacy, /id="leistungsmessung">Leistungsmessung<\/h2>(?:<p>[^<]*<\/p>)*<p>[^<]*„Leistungsdaten senden“ aus/);
});

test('a report keeps only known, trimmed and clamped fields', () => {
  const report = sanitizePerfReport({
    ...android, uid: 'sam', personId: 7, extra: { nested: true },
    device: { ...android.device, model: '<script>alert(1)</script> Pixel 6a with a very long model name that goes on and on', dpr: 99, cores: -3, secret: 'x' },
    app: { version: '0.12.0"; DROP TABLE', build: '29' },
    frames: { ...android.frames, p95: 1e9, j50: 1e9, h: [1, 2, 3] },
    routes: [...Array(40)].map((_, i) => ({ r: `route${i}/../${'x'.repeat(80)}`, n: 10, h: android.frames.h })),
    worst: [...Array(9)].map(() => ({ ms: 80, ev: 'pickup,sound,<b>', in: 'tap' })),
    api: [{ m: 'PATCH', p: '/x', n: 1 }, { m: 'GET', p: 'no-slash', n: 1 }, { m: 'GET', p: '/snapshot', n: 2, err: 9, off: 1 }],
  });
  for (const field of ['uid', 'personId', 'extra']) assert.equal(report[field], undefined);
  assert.equal(report.device.secret, undefined);
  assert.equal(report.device.model, 'scriptalert(1)/script Pixel 6a with a very long model name t');
  assert.equal(report.device.dpr, 8);
  assert.equal(report.device.cores, 0);
  assert.equal(report.app.version, '0.12.0DROPTABLE');
  assert.equal(report.frames.p95, 60000);
  assert.equal(report.frames.j50, report.frames.n, 'jank counts never exceed the frames');
  assert.equal(report.frames.h, undefined, 'a histogram of the wrong length is dropped');
  assert.equal(report.routes.length, perfTelemetry.maxRoutes);
  assert.ok(report.routes.every(r => r.r.length <= 48 && !r.r.includes('/')));
  assert.equal(report.worst.length, perfTelemetry.maxWorst);
  assert.equal(report.worst[0].ev, 'pickup,sound,b');
  assert.deepEqual(report.api, [{ m: 'GET', p: '/snapshot', n: 2, err: 2, off: 1 }]);
  assert.equal(report.run, undefined, 'only stage runner reports carry a run');
  assert.deepEqual(sanitizePerfReport(runnerWeb).run, runnerWeb.run);
});

test('newer apps add optional fields; older reports stay valid', () => {
  const srv = Array.from({ length: serverEdges.length + 1 }, (_, i) => (i === 2 ? 3 : 0));
  const report = sanitizePerfReport({
    ...android, rid: '0123456789abcdef',
    startup: { ...android.startup, vis: 'hidden', hidden: true, fcp: 812.4, paint: 3 },
    worst: [{ ms: 120, r: 'WardrobeScreen', t: 4, ev: 'skin,img', b: 31.24, ra: 70000, gap: 9 }],
    api: [{ m: 'GET', p: '/games/runner/skins/:id.webp', n: 4, susp: 9, srv, h: hist({}).slice(0, 13) }, { m: 'GET', p: '/snapshot', n: 1, srv: [1, 2] }],
  });
  assert.equal(report.rid, '0123456789abcdef');
  assert.deepEqual(report.startup, { ...android.startup, vis: 'hidden', hidden: true, fcp: 812 });
  assert.deepEqual(report.worst, [{ ms: 120, r: 'WardrobeScreen', t: 4, ev: 'skin,img', b: 31.2, ra: 60000 }], 'unknown worst-frame fields are dropped');
  assert.deepEqual(report.api[0].srv, srv);
  assert.equal(report.api[0].susp, 4, 'never more paused calls than calls');
  assert.equal(report.api[1].srv, undefined, 'a server histogram of the wrong length is dropped');
  const run = sanitizePerfReport({ ...runnerWeb, run: { ...runnerWeb.run, snd: false, f0: 41.26, music: 'x' } }).run;
  assert.deepEqual(run, { ...runnerWeb.run, snd: false, f0: 41.3 });
  for (const rid of ['0123456789ABCDEF', '0123', 'g123456789abcdef', 7]) assert.equal(sanitizePerfReport({ ...android, rid }).rid, undefined, `${rid}`);
  assert.equal(sanitizePerfReport({ ...android, startup: { ...android.startup, vis: 'gone', hidden: 'yes' } }).startup.vis, undefined);
  // An older app sends none of them.
  assert.deepEqual(sanitizePerfReport(android).api, android.api);
  assert.equal(sanitizePerfReport(android).rid, undefined);
});

test('a report sent twice is stored once and still answered with 204', async t => {
  const { app, rows, perf, clock, store } = setup(t);
  const send = await serve(t, app, { perf });
  assert.equal((await send('sam', android)).status, 204);
  assert.equal((await send('sam', android)).status, 204, 'same session and sequence number');
  assert.equal(rows().length, 1);
  assert.equal((await send('sam', { ...android, seq: 1 })).status, 204);
  assert.equal(rows().length, 2, 'the next report of the session');
  // With a report id the id decides, also without a session.
  const withId = { ...chromePwa, rid: 'aaaaaaaaaaaaaaaa' };
  assert.equal(perf.record('kim', withId), true);
  assert.equal(perf.record('kim', withId), false);
  const { session, ...sessionless } = { ...withId, rid: 'bbbbbbbbbbbbbbbb', install: 'e'.repeat(32) };
  assert.ok(session);
  assert.equal(perf.record('kim', sessionless), true);
  assert.equal(perf.record('kim', sessionless), false);
  // Older apps without a session and report id cannot be told apart and are all kept.
  const { session: _, ...old } = { ...safari };
  assert.equal(perf.record('lou', old), true);
  assert.equal(perf.record('lou', old), true);
  // The same report three days later counts again (the lookup only goes back that far).
  clock.now = new Date(+clock.now + perfTelemetry.dedupeDays * 864e5 + 1);
  assert.equal(perf.record('sam', android), true);
  assert.equal(rows().length, 7);
  assert.ok(store.db.prepare("SELECT 1 FROM sqlite_master WHERE type='index' AND name='perf_reports_session'").get());
});

test('reports that are not ours are rejected', () => {
  assert.equal(sanitizePerfReport(null), null);
  assert.equal(sanitizePerfReport([]), null);
  assert.equal(sanitizePerfReport({ ...android, v: 2 }), null);
  assert.equal(sanitizePerfReport({ ...android, kind: 'crash' }), null);
  assert.equal(sanitizePerfReport({ ...android, install: 'short' }), null);
  assert.equal(sanitizePerfReport({ ...android, install: 'sam@example.invalid-0000000000' }), null);
  assert.equal(sanitizePerfReport({ v: 1, kind: 'app', install: android.install, device: android.device }), null, 'nothing measured');
});

test('the endpoint stores reports without the account and never reports errors', async t => {
  const { app, rows, perf } = setup(t);
  const send = await serve(t, app, { perf });
  assert.deepEqual(await send('sam', android), { status: 204, text: '' });
  const [row] = rows();
  assert.equal(row.install_id, android.install);
  assert.equal(row.session_id, android.session);
  assert.deepEqual([row.kind, row.platform, row.renderer, row.browser, row.os, row.pwa, row.app_version, row.app_build], ['app', 'android', 'impeller', null, 'Android 15', null, '0.12.0', '29']);
  assert.equal(row.created_at, '2026-10-24T12:00:00.000Z');
  assert.ok(!JSON.stringify(row).includes('sam'), 'neither the uid nor the person is stored');
  assert.deepEqual(JSON.parse(row.data).frames, android.frames);
  // Invalid, oversized and unauthorized reports are dropped silently.
  assert.equal((await send('sam', '{not json')).status, 204);
  assert.equal((await send('sam', { ...android, v: 9 })).status, 204);
  assert.equal((await send('sam', { ...android, padding: 'x'.repeat(perfTelemetry.maxBytes) })).status, 204);
  assert.equal((await send('pending', android)).status, 204);
  assert.equal((await send('nobody', android)).status, 204);
  assert.equal(rows().length, 1);
  assert.equal((await send(null, android)).status, 401, 'the endpoint still needs a sign-in');
  assert.equal((await send('sam', chromePwa)).status, 204);
  assert.deepEqual(rows().map(r => [r.platform, r.renderer, r.browser, r.pwa]).at(-1), ['web', 'skwasm', 'Chrome 141', 1]);
});

test('reports of the review account stay out of the data', async t => {
  const { app, rows, perf } = setup(t);
  const reviewStore = new Store(); t.after(() => reviewStore.close());
  const review = { uid: 'reviewer', theater: new Theater(reviewStore, { bootstrapEmail: 'review@example.invalid' }) };
  const send = await serve(t, app, { perf, review });
  assert.equal((await send('reviewer', android)).status, 204);
  assert.equal(rows().length, 0);
  assert.equal(reviewStore.db.prepare('SELECT COUNT(*) AS n FROM perf_reports').get().n, 0);
});

test('reports are limited per installation and per account', t => {
  const { perf, rows, clock } = setup(t);
  for (let i = 0; i < perfTelemetry.perInstallPerHour; i++) assert.equal(perf.record('sam', { ...android, seq: i }), true);
  assert.equal(perf.record('sam', { ...android, seq: 99 }), false, 'the installation sent enough this hour');
  // Fresh installation ids do not get around the account limit.
  let accepted = 0;
  for (let i = 0; i < perfTelemetry.perAccountPerHour; i++) if (perf.record('sam', { ...android, install: `${i}`.padStart(32, 'f') })) accepted++;
  assert.equal(accepted, perfTelemetry.perAccountPerHour - perfTelemetry.perInstallPerHour - 1, 'rejected attempts count against the account');
  assert.equal(perf.record('kim', chromePwa), true, 'other accounts are not affected');
  clock.now = new Date(+clock.now + perfTelemetry.windowMs + 1);
  assert.equal(perf.record('sam', { ...android, seq: 100 }), true, 'the window slides');
  assert.equal(rows().length, perfTelemetry.perAccountPerHour + 1);
});

test('retention deletes reports after 30 days', async t => {
  const { app, store, perf, clock, rows } = setup(t);
  clock.now = new Date('2026-09-20T12:00:00Z'); perf.record('sam', android);
  clock.now = new Date('2026-10-10T12:00:00Z'); perf.record('sam', chromePwa);
  const counts = await purgeExpired(app, { now: new Date('2026-10-24T12:00:00Z') });
  assert.equal(counts.perfReports, 1);
  assert.deepEqual(rows().map(r => r.install_id), [chromePwa.install]);
  assert.ok(store.db.prepare("SELECT 1 FROM sqlite_master WHERE type='index' AND name='perf_reports_created'").get());
});

test('bucket quantiles interpolate inside the bucket', () => {
  const edges = [10, 20, 30];
  assert.equal(histQuantile([0, 0, 0, 0], edges, 0.5), null);
  assert.equal(histQuantile([0, 10, 0, 0], edges, 0.5), 15);
  assert.equal(histQuantile([5, 5, 0, 0], edges, 0.5), 10);
  assert.equal(histQuantile([0, 0, 0, 4], edges, 1, 80), 80, 'the open bucket ends at the longest frame');
});

const fillFixture = store => {
  const insert = new PerfTelemetry(store);
  for (const [at, report] of fixtureReports) { insert.clock = () => Date.parse(at); insert.limiter.clock = insert.clock; assert.equal(insert.record(`uid-${report.install}`, report), true); }
};

test('the report summarizes the fixture by platform, route, start, API and game', t => {
  const { store } = setup(t);
  fillFixture(store);
  const text = perfReport(store.db, { days: 7, now: new Date('2026-10-24T12:00:00Z') });
  assert.match(text, /Berichte: 5 \(App 3, Bühnenlauf 2\) · Installationen: 3 · App-Sitzungen: 3/);
  // Android: 1000 frames, 40 above 25 ms, 5 above 50 ms, 1 above 100 ms.
  assert.match(text, /\| android · impeller \| 1 \| 1 \| 1000 \| 0\.3 \| [\d.]+ \| [\d.]+ \| [\d.]+ \| 120 \| 4\.0 % \| 0\.50 % \| 0\.10 % \|/);
  assert.match(text, /\| web · skwasm \| 1 \| 1 \| 700 \|/);
  assert.match(text, /\| Chrome 141 · Android 14 \|/);
  assert.match(text, /\| Web · installiert \(standalone\) \| 1 \|/);
  assert.match(text, /\| Web · Browser-Tab \| 1 \|/);
  assert.match(text, /\| android · Google Pixel 6a \|/);
  assert.match(text, /\| ScriptReaderScreen \| 1 \| 1 \| 365 \|/);
  assert.match(text, /\| today \| 2 \| 2 \| 1335 \|/);
  assert.match(text, /\| android · impeller · cold \| 1 \| 1 \| 420 \/ 420 \| 610 \/ 610 \| 900 \/ 900 \| 1350 \/ 1350 \|/);
  assert.match(text, /\| GET \/snapshot \| 2 \| 5 \|/);
  assert.match(text, /\| web · skwasm \| 1 \| 0 % \|/, 'shows whether FrameTiming arrives on the web');
  assert.match(text, /Läufe: 2 · Spielzeit: 1\.6 min · Installationen: 2/);
  assert.match(text, /\| sound \| 3 \| 60\.0 % \|/);
  assert.match(text, /\| logge \|/);
  assert.match(text, /\| 140 \| today \|/);
  assert.ok(!text.includes('olololol') && !/Safari 18\.4.*\| 2 \|/.test(text), 'older reports stay outside the window');
});

test('the report script reads the database read-only', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'theater-perf-')); t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, 'theater.sqlite'), store = new Store(path);
  fillFixture(store); store.close();
  const script = fileURLToPath(new URL('../scripts/perf-report.mjs', import.meta.url));
  const { stdout } = await promisify(execFile)(process.execPath, [script, path, '--days', '3650']);
  assert.match(stdout, /^# Performance-Telemetrie: /);
  assert.match(stdout, /Berichte: 6 /);
  const empty = join(directory, 'empty.sqlite');
  new Store(empty).close();
  const { stdout: none } = await promisify(execFile)(process.execPath, [script, empty]);
  assert.match(none, /Keine Berichte im Zeitraum/);
  await assert.rejects(promisify(execFile)(process.execPath, [script]), /Aufruf/);
});

// A historical row as the old server stored it, bypassing the duplicate check.
const insertRaw = (store, at, report) => store.db.prepare(`INSERT INTO perf_reports(created_at, install_id, session_id, kind, platform, renderer, browser, os, pwa, app_version, app_build, data)
  VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`).run(at, report.install, report.session ?? null, report.kind, report.device.platform, report.device.renderer ?? null, report.device.browser ?? null,
  report.device.os ?? null, report.device.pwa === undefined ? null : report.device.pwa ? 1 : 0, report.app.version, report.app.build ?? null, JSON.stringify(sanitizePerfReport(report)));

test('30-Hz windows, duplicates and start frames are recognized', () => {
  // Safari at 30 Hz: a median of 33 ms although the frames are cheap to build.
  const slow = { kind: 'app', frames: { n: 400, p50: 33.3, b95: 6 } };
  assert.equal(throttled(slow.kind, slow.frames), true);
  assert.equal(throttled('app', { ...slow.frames, b95: 22 }), false, 'expensive frames are real jank');
  assert.equal(throttled('app', { ...slow.frames, n: 40 }), false);
  assert.equal(throttled('app', { ...slow.frames, p50: 16.7 }), false);
  assert.equal(throttled('stageRunner', { p50: 28.4 }), true);
  assert.equal(throttled('stageRunner', { p50: 16.7 }), false);
  const row = (id, session, seq, data = { seq }) => ({ install_id: id, session_id: session, data, raw: JSON.stringify(data) });
  const { rows, dropped } = dedupeReports([row('a', 's', 0), row('a', 's', 0), row('a', 's', 1), row('b', 's', 0), row('c', null, undefined, { x: 1 }), row('c', null, undefined, { x: 1 }), row('c', null, undefined, { x: 2 })]);
  assert.equal(dropped, 2);
  assert.equal(rows.length, 5);
});

test('the report leaves out duplicates, 30-Hz windows and start frames', t => {
  const { store } = setup(t);
  const day = '2026-10-22T10:00:00.000Z';
  const frames = (counts, extra) => { const h = hist(counts), n = h.reduce((a, b) => a + b, 0), above = from => h.slice(from).reduce((a, b) => a + b, 0); return { n, ms: n * 20, p50: 16.7, p95: 24, p99: 40, max: 120, j25: above(9), j50: above(11), j100: above(13), h, ...extra }; };
  const base = { v: 1, install: '1'.repeat(32), session: '2'.repeat(16), app: { version: '0.13.1' } };
  const ios = { platform: 'web', renderer: 'canvaskit', browser: 'Safari 26.6', os: 'iOS 18.7', mobile: true, pwa: true };
  // A Safari window at 30 Hz (all frames 25–33 ms) next to a normal one; the normal one twice.
  const fast = { ...base, kind: 'app', seq: 0, up: 100, device: ios, frames: frames({ 6: 900, 9: 90, 11: 10 }, { b95: 5 }), routes: [{ r: 'today', ...frames({ 6: 900, 9: 90, 11: 10 }) }],
    startup: { kind: 'cached', preMs: 800, firstFrameMs: 32000, readyMs: 32500, dataMs: 2000 }, worst: [{ ms: 400, r: 'today', t: 99.8 }, { ms: 300, r: 'today', t: 40, ev: 'skin' }] };
  const slow = { ...base, kind: 'app', seq: 1, up: 400, device: ios, frames: frames({ 9: 1000, 11: 6 }, { p50: 33.1, b95: 7 }), routes: [{ r: 'today', ...frames({ 9: 1000, 11: 6 }) }] };
  // Two runs of the session: both start with a slow first frame, the second also at 30 Hz.
  const run = (seq, extra) => ({ ...base, kind: 'stageRunner', seq, device: ios, frames: frames({ 6: 2000, 11: 4 }), run: { ms: 60000, m: 500, end: 'crash' },
    worst: [{ ms: 200, t: 0, m: 0, ev: 'sound,obstacle' }, { ms: 90, t: 20, m: 200, ev: 'sound' }, { ms: 60, t: 30, m: 300 }], ...extra });
  for (const [report, times] of [[fast, 2], [slow, 1], [run(2), 1], [run(3, { frames: frames({ 9: 2000, 11: 4 }, { p50: 33 }), run: { ms: 60000, m: 500, end: 'crash', snd: true } }), 2]]) {
    for (let i = 0; i < times; i++) insertRaw(store, day, report);
  }
  const text = perfReport(store.db, { days: 7, now: new Date('2026-10-24T12:00:00Z') });
  const section = title => text.split('\n## ').find(x => x.startsWith(title)).trim();
  assert.match(text, /Berichte: 4 \(App 2, Bühnenlauf 2\)/);
  assert.match(text, /Bereinigt: 2 doppelt gespeicherte Berichte entfernt\. .*App 1, Bühnenlauf 1\./);
  // The 30-Hz window has its own row; the platform row keeps only the normal frames for the
  // percentiles and shares, but counts its janks per minute (16 janks in 2006 × 20 ms).
  assert.equal(section('App: Bildzeiten nach Plattform'), [
    'App: Bildzeiten nach Plattform und Renderer',
    '| Gruppe | Inst. | Berichte | Bilder | Min. aktiv | p50 ms | p95 ms | p99 ms | max ms | >25 ms | >50 ms | >100 ms | >50 ms/min |',
    '|---|---|---|---|---|---|---|---|---|---|---|---|---|',
    '| web · canvaskit | 1 | 2 | 1000 | 0.3 | 17.1 | 29.4 | 33 | 120 | 10.0 % | 1.0 % | 0 % | 23.93 |',
    '| 30 Hz (gedrosselt) | 1 | 1 | 1006 | 0.3 | 29 | 32.6 | 33 | 120 | 100.0 % | 0.60 % | 0 % | 17.89 |',
  ].join('\n'));
  assert.match(section('App: nach System und Modus'), /\| iOS\/iPadOS · standalone \| 1 \| 2 \| 1000 \|/);
  assert.match(section('App: nach Bildschirm (alle'), /\| today \| 1 \| 2 \| 1000 \|[^\n]*\n\| 30 Hz \(gedrosselt\) \| 1 \| 1 \| 1006 \|/);
  // A first frame after 32 s is a hidden page, not a slow start.
  assert.match(section('Start'), /\| web · canvaskit · cached · erstes Bild > 10 s \| 1 \| 1 \| 800 \/ 800 \| 32000 \/ 32000 \|/);
  assert.equal(section('Bühnenlauf').split('### ').find(x => x.startsWith('Häufigste')).trim(), [
    'Häufigste Ruckel-Auslöser (4 Ruckler ≥50 ms aus den je 5 schlimmsten pro Lauf, ohne 2 Startbilder)',
    '| Ereignis im Ruckel-Bild (≥50 ms) | Ruckler | Anteil |',
    '|---|---|---|',
    '| sound | 2 | 50.0 % |',
    '| (kein Ereignis im Bild) | 2 | 50.0 % |',
    '| Startbild (erster Lauf der Sitzung) | 1 | 16.7 % aller |',
    '| Startbild (späterer Lauf) | 1 | 16.7 % aller |',
  ].join('\n'));
  // Its only run with sound is throttled: the group stays, without percentiles.
  assert.match(section('Bühnenlauf'), /### nach Ton\n[^]*\| Ton an \| 1 \| 1 \| 0 \| 0 \| – \| – \| – \| 0 \| – \| – \| – \| 5\.99 \|\n\| 30 Hz \(gedrosselt\) \| 1 \| 1 \| 2004 \|/);
  const worst = section('Schlimmste Ruckler');
  assert.match(worst, /\| 400 \| today \|[^\n]*\| 100 s nach Start · vor Hintergrund \|/);
  assert.match(worst, /\| 300 \| today \|[^\n]*\| skin \| 40 s nach Start \|/);
  assert.match(worst, /\| 200 \| stageRunner \|[^\n]*\| 0 s · 0 m · Startbild \|/);
  assert.match(section('App: Ereignisse'), /\| skin \| 1 \| 50\.0 % \|/);
});

test('the report shows server time, paused calls and frame timings once apps send them', t => {
  const { store } = setup(t);
  const srv = Array.from({ length: serverEdges.length + 1 }, (_, i) => (i === 1 ? 4 : 0));
  insertRaw(store, '2026-10-22T10:00:00.000Z', { ...chromePwa, startup: { ...chromePwa.startup, fcp: 1500, hidden: true },
    api: [{ ...chromePwa.api[0], susp: 1, srv }], worst: [{ ms: 140, r: 'today', t: 3.2, ev: 'img', b: 12, ra: 30 }] });
  const text = perfReport(store.db, { days: 7, now: new Date('2026-10-24T12:00:00Z') });
  assert.match(text, /\| Aufruf \| Inst\. \| Anzahl \| p50 ms \| p95 ms \| max ms \| Fehler \| offline \| Server p50 ms \| Server p95 ms \| pausiert \|/);
  assert.match(text, /\| GET \/snapshot \| 1 \| 2 \| [\d.]+ \| [\d.]+ \| 2600 \| 0 % \| 50\.0 % \| 1\.5 \| 1\.9 \| 50\.0 % \|/);
  assert.match(text, /\| web · skwasm · cached · verdeckt \| 1 \| 1 \| 1900 \/ 1900 \| 1500 \/ 1500 \| 450 \/ 450 \|/);
  assert.match(text, /\| 140 \| today \|[^\n]*\| img \| 3 s nach Start \| 12 \/ 30 \|/);
});
