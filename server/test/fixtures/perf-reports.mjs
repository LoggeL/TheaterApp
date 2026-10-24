// Reports as the app sends them (lib/core/telemetry), for perf-telemetry and perf-report tests.
// Frame buckets end at 4, 8, 10, 12, 14, 16, 18, 20, 25, 33, 50, 67, 100, 150, 250, 500, 1000 ms.

/** A frame histogram from { bucketIndex: count }. */
export const hist = counts => Array.from({ length: 18 }, (_, i) => counts[i] ?? 0);
const frames = (counts, extra = {}) => {
  const h = hist(counts), n = h.reduce((a, b) => a + b, 0), above = from => h.slice(from).reduce((a, b) => a + b, 0);
  return { n, ms: Math.round(n * 17), p50: 16.7, p95: 24, p99: 40, max: 120, j25: above(9), j50: above(11), j100: above(13), h, ...extra };
};
const latency = counts => Array.from({ length: 13 }, (_, i) => counts[i] ?? 0);

export const android = {
  v: 1, kind: 'app', install: 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1', session: 'b1b1b1b1b1b1b1b1', seq: 0, span: 300000, up: 300,
  device: { platform: 'android', renderer: 'impeller', model: 'Google Pixel 6a', os: 'Android 15', sdk: 35, mobile: true, dpr: 2.625, w: 412, h: 892, hz: 60, cores: 8, mode: 'release' },
  app: { version: '0.12.0', build: '29' },
  startup: { kind: 'cold', preMs: 420, firstFrameMs: 610, readyMs: 900, dataMs: 1350 },
  frames: frames({ 6: 900, 7: 40, 8: 20, 9: 25, 10: 10, 11: 3, 12: 1, 13: 1 }, { ft: 1000, b50: 3.1, b95: 9.5, r50: 4.2, r95: 11.8, t95: 19.4 }),
  routes: [
    { r: 'today', ...frames({ 6: 600, 7: 20, 8: 10, 9: 5 }) },
    { r: 'ScriptReaderScreen', ...frames({ 6: 300, 7: 20, 8: 10, 9: 20, 10: 10, 11: 3, 12: 1, 13: 1 }) },
  ],
  worst: [{ ms: 120, r: 'ScriptReaderScreen', t: 42.5, in: 'drag', ev: 'route' }, { ms: 70, r: 'ScriptReaderScreen', t: 50, in: 'drag' }],
  api: [
    { m: 'GET', p: '/snapshot', n: 3, err: 0, off: 0, p50: 380, p95: 900, max: 950, h: latency({ 3: 1, 4: 1, 6: 1 }) },
    { m: 'GET', p: '/productions/:id/script', n: 1, err: 0, off: 0, p50: 1200, p95: 1200, max: 1200, h: latency({ 7: 1 }) },
  ],
};

export const chromePwa = {
  v: 1, kind: 'app', install: 'c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2', session: 'd2d2d2d2d2d2d2d2', seq: 0, span: 200000, up: 200,
  device: { platform: 'web', renderer: 'skwasm', compiler: 'dart2wasm', browser: 'Chrome 141', os: 'Android 14', mobile: true, pwa: true, dpr: 3, w: 393, h: 852, hz: 60, cores: 8, mem: 4, net: '4g', mode: 'release' },
  app: { version: '0.12.0' },
  startup: { kind: 'cached', nav: 'navigate', preMs: 1900, firstFrameMs: 450, readyMs: 700, dataMs: 1200 },
  frames: frames({ 6: 500, 7: 50, 8: 50, 9: 60, 10: 30, 11: 6, 12: 3, 13: 1 }, { ft: 0 }),
  routes: [{ r: 'today', ...frames({ 6: 500, 7: 50, 8: 50, 9: 60, 10: 30, 11: 6, 12: 3, 13: 1 }) }],
  worst: [{ ms: 140, r: 'today', t: 3.2, ev: 'api' }],
  api: [{ m: 'GET', p: '/snapshot', n: 2, err: 0, off: 1, p50: 500, p95: 2500, max: 2600, h: latency({ 4: 1, 10: 1 }) }],
};

export const safari = {
  v: 1, kind: 'app', install: 'e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3e3', session: 'f3f3f3f3f3f3f3f3', seq: 0, span: 100000, up: 100,
  device: { platform: 'web', renderer: 'canvaskit', compiler: 'dart2js', browser: 'Safari 18.4', os: 'iOS 18.4', mobile: true, pwa: false, dpr: 3, w: 390, h: 844, hz: 60, cores: 4, mode: 'release' },
  app: { version: '0.12.0' },
  startup: { kind: 'network', nav: 'navigate', preMs: 4200, firstFrameMs: 900, readyMs: 1300, dataMs: 2100 },
  frames: frames({ 6: 300, 8: 50, 9: 100, 10: 40, 11: 8, 12: 2 }),
  routes: [{ r: 'schedule', ...frames({ 6: 300, 8: 50, 9: 100, 10: 40, 11: 8, 12: 2 }) }],
  worst: [{ ms: 95, r: 'schedule', t: 12, in: 'tap', ev: 'route' }],
};

export const runnerWeb = {
  v: 1, kind: 'stageRunner', install: 'c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2', session: 'd2d2d2d2d2d2d2d2', seq: 1,
  device: chromePwa.device, app: chromePwa.app,
  frames: frames({ 6: 3000, 7: 100, 8: 50, 9: 30, 10: 10, 11: 5, 12: 2 }, { ft: 0 }),
  run: { ms: 55000, m: 610, score: 900, character: 'logge', backdrop: 'creepshow', fx: 'confetti', end: 'crash' },
  worst: [
    { ms: 90, t: 12.1, m: 130, ev: 'pickup,sound' }, { ms: 80, t: 30, m: 330, ev: 'debut' }, { ms: 70, t: 31, m: 345, ev: 'sound' },
    { ms: 60, t: 54.9, m: 609, ev: 'crash,sound' }, { ms: 40, t: 8, m: 80 },
  ],
};

export const runnerAndroid = {
  v: 1, kind: 'stageRunner', install: 'a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1', session: 'b1b1b1b1b1b1b1b1', seq: 1,
  device: android.device, app: android.app,
  frames: frames({ 6: 2400, 7: 20, 9: 5, 11: 1 }, { ft: 2426, b50: 2.5, b95: 5.5, r50: 3.3, r95: 7.1, t95: 12.2 }),
  run: { ms: 42000, m: 400, score: 520, end: 'crash' },
  worst: [{ ms: 55, t: 0.1, m: 0, ev: 'skin' }, { ms: 30, t: 20, m: 190, ev: 'pickup' }],
};

/** [createdAt, report] pairs; the last one is older than seven days. */
export const fixtureReports = [
  ['2026-10-20T10:00:00.000Z', android],
  ['2026-10-21T18:00:00.000Z', chromePwa],
  ['2026-10-22T19:30:00.000Z', safari],
  ['2026-10-21T18:05:00.000Z', runnerWeb],
  ['2026-10-20T10:03:00.000Z', runnerAndroid],
  ['2026-10-01T10:00:00.000Z', { ...safari, install: 'olololololololololololololololol' }],
];
