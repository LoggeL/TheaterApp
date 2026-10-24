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
import { PerfTelemetry, perfTelemetry, sanitizePerfReport } from '../src/perf-telemetry.mjs';
import { purgeExpired, retention } from '../src/retention.mjs';
import { histQuantile, perfReport } from '../scripts/perf-report.mjs';
import { android, chromePwa, fixtureReports, runnerWeb } from './fixtures/perf-reports.mjs';

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
  for (let i = 0; i < perfTelemetry.perInstallPerHour; i++) assert.equal(perf.record('sam', android), true);
  assert.equal(perf.record('sam', android), false, 'the installation sent enough this hour');
  // Fresh installation ids do not get around the account limit.
  let accepted = 0;
  for (let i = 0; i < perfTelemetry.perAccountPerHour; i++) if (perf.record('sam', { ...android, install: `${i}`.padStart(32, 'f') })) accepted++;
  assert.equal(accepted, perfTelemetry.perAccountPerHour - perfTelemetry.perInstallPerHour - 1, 'rejected attempts count against the account');
  assert.equal(perf.record('kim', chromePwa), true, 'other accounts are not affected');
  clock.now = new Date(+clock.now + perfTelemetry.windowMs + 1);
  assert.equal(perf.record('sam', android), true, 'the window slides');
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
