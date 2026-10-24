// Performance telemetry: anonymous frame, start and API timings from the app (see
// docs/operations.md "Performance-Telemetrie"). Reports carry a random installation id instead
// of the account; the server keeps the account only in memory for the rate limit. Nothing is
// shown in the app: an agent reads the table with scripts/perf-report.mjs.

// Upper bounds (ms) of the frame-time buckets; the last bucket is open. The app uses the same
// edges (lib/core/telemetry/perf_stats.dart), so reports can be merged exactly.
export const frameEdges = Object.freeze([4, 8, 10, 12, 14, 16, 18, 20, 25, 33, 50, 67, 100, 150, 250, 500, 1000]);
// Upper bounds (ms) of the API latency buckets.
export const latencyEdges = Object.freeze([50, 100, 200, 300, 500, 750, 1000, 1500, 2000, 3000, 5000, 10000]);
export const perfTelemetry = Object.freeze({
  maxBytes: 16 * 1024,
  perInstallPerHour: 30,
  perAccountPerHour: 60,
  windowMs: 3600000,
  maxTracked: 5000,
  retentionDays: 30,
  maxRoutes: 16,
  maxApi: 20,
  maxWorst: 5,
});

const kinds = ['app', 'stageRunner'];
const platforms = ['android', 'ios', 'web', 'macos', 'windows', 'linux', 'fuchsia', 'other'];
const methods = ['GET', 'POST', 'PUT', 'DELETE'];
const isObject = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const obj = v => isObject(v) ? v : {};
/** A finite number clamped to [min, max] with `digits` decimals, or undefined. */
const num = (v, max, min = 0, digits = 1) => {
  if (typeof v !== 'number' || !Number.isFinite(v)) return undefined;
  const f = 10 ** digits;
  return Math.round(Math.min(max, Math.max(min, v)) * f) / f;
};
const int = (v, max, min = 0) => num(v, max, min, 0);
const bool = v => typeof v === 'boolean' ? v : undefined;
/** A trimmed string of at most `max` characters, limited to `allowed` characters. */
const str = (v, max, allowed = /[^\w .:/()+,;-]/g) => {
  if (typeof v !== 'string') return undefined;
  const s = v.replace(allowed, '').trim().slice(0, max);
  return s || undefined;
};
const oneOf = (v, values) => values.includes(v) ? v : undefined;
const id = v => typeof v === 'string' && /^[A-Za-z0-9-]{16,64}$/.test(v) ? v : undefined;
const hist = (v, length) => Array.isArray(v) && v.length === length && v.every(x => Number.isInteger(x) && x >= 0 && x <= 1e7) ? v : undefined;
/** Drops undefined fields; returns undefined for an empty object. */
const compact = o => {
  const out = Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined));
  return Object.keys(out).length ? out : undefined;
};
const list = (v, max, fn) => {
  const out = Array.isArray(v) ? v.slice(0, max).map(fn).filter(Boolean) : [];
  return out.length ? out : undefined;
};

const ms = v => num(v, 60000);
/** Frame statistics of a session window, a route or a stage runner run. */
const frames = v => {
  if (!isObject(v)) return undefined;
  const n = int(v.n, 1e7);
  const out = compact({
    n, ms: int(v.ms, 864e5), p50: ms(v.p50), p95: ms(v.p95), p99: ms(v.p99), max: ms(v.max),
    j25: int(v.j25, n ?? 0), j50: int(v.j50, n ?? 0), j100: int(v.j100, n ?? 0), h: hist(v.h, frameEdges.length + 1),
    // FrameTiming (build/raster/total span) where the platform reports it.
    ft: int(v.ft, 1e7), b50: ms(v.b50), b95: ms(v.b95), r50: ms(v.r50), r95: ms(v.r95), t95: ms(v.t95),
  });
  return out?.n ? out : undefined;
};
const route = v => str(v, 48, /[^\w.:-]/g);
const events = v => str(v, 64, /[^\w,.:-]/g);
const worst = v => isObject(v) && ms(v.ms) !== undefined ? compact({ ms: ms(v.ms), r: route(v.r), t: num(v.t, 1e7), in: str(v.in, 12, /[^\w-]/g), ev: events(v.ev), m: int(v.m, 1e7) }) : undefined;
const api = v => {
  if (!isObject(v)) return undefined;
  const m = oneOf(v.m, methods), p = str(v.p, 80, /[^\w/:.-]/g), n = int(v.n, 1e6);
  if (!m || !p?.startsWith('/') || !n) return undefined;
  return compact({ m, p, n, err: int(v.err, n), off: int(v.off, n), p50: num(v.p50, 120000), p95: num(v.p95, 120000), max: num(v.max, 120000), h: hist(v.h, latencyEdges.length + 1) });
};

/**
 * The validated, trimmed report, or null when it is not one. Unknown fields are dropped, numbers
 * clamped to plausible ranges and strings shortened to a safe character set.
 */
export function sanitizePerfReport(body) {
  if (!isObject(body) || body.v !== 1) return null;
  const kind = oneOf(body.kind, kinds), install = id(body.install);
  if (!kind || !install) return null;
  const d = obj(body.device), a = obj(body.app), s = obj(body.startup), r = obj(body.run);
  const report = compact({
    v: 1, kind, install, session: id(body.session), seq: int(body.seq, 1e5),
    // Window length and its end in seconds since the app started.
    span: int(body.span, 864e5), up: num(body.up, 1e7),
    device: compact({
      platform: oneOf(d.platform, platforms) ?? 'other', renderer: str(d.renderer, 24, /[^\w-]/g), compiler: str(d.compiler, 16, /[^\w-]/g),
      browser: str(d.browser, 40), os: str(d.os, 40), model: str(d.model, 60), sdk: int(d.sdk, 100), mobile: bool(d.mobile), pwa: bool(d.pwa),
      dpr: num(d.dpr, 8, 0.25, 2), w: int(d.w, 20000), h: int(d.h, 20000), hz: num(d.hz, 500), cores: int(d.cores, 512), mem: num(d.mem, 1024, 0, 2),
      net: str(d.net, 16, /[^\w-]/g), mode: oneOf(d.mode, ['release', 'profile', 'debug']),
    }),
    app: compact({ version: str(a.version, 20, /[^\w.+-]/g), build: str(a.build, 12, /[^\w.-]/g) }),
    startup: compact({ kind: str(s.kind, 16, /[^\w-]/g), nav: str(s.nav, 16, /[^\w-]/g), preMs: int(s.preMs, 6e5), firstFrameMs: int(s.firstFrameMs, 6e5), readyMs: int(s.readyMs, 6e5), dataMs: int(s.dataMs, 6e5) }),
    frames: frames(body.frames),
    routes: list(body.routes, perfTelemetry.maxRoutes, x => { const f = frames(x), name = route(x?.r); return f && name ? { r: name, ...f } : undefined; }),
    worst: list(body.worst, perfTelemetry.maxWorst, worst),
    api: list(body.api, perfTelemetry.maxApi, api),
    run: kind === 'stageRunner' ? compact({ ms: int(r.ms, 864e5), m: int(r.m, 1e7), score: int(r.score, 1e8), character: route(r.character), backdrop: route(r.backdrop), fx: route(r.fx), end: str(r.end, 16, /[^\w-]/g) }) : undefined,
  });
  if (!report.frames && !report.startup && !report.api?.length) return null;
  return report;
}

/** In-memory sliding-window counter; keys are never stored. */
class Limiter {
  constructor(clock) { this.clock = clock; this.hits = new Map(); }
  take(key, max) {
    const at = this.clock(), since = at - perfTelemetry.windowMs;
    if (this.hits.size >= perfTelemetry.maxTracked) {
      for (const [k, times] of this.hits) if (!times.some(t => t > since)) this.hits.delete(k);
      while (this.hits.size >= perfTelemetry.maxTracked) this.hits.delete(this.hits.keys().next().value);
    }
    const recent = (this.hits.get(key) ?? []).filter(t => t > since);
    if (recent.length >= max) return false;
    this.hits.delete(key); this.hits.set(key, [...recent, at]);
    return true;
  }
}

/** Stores accepted reports in the `perf_reports` table (see store.mjs). */
export class PerfTelemetry {
  constructor(store, { clock = () => Date.now() } = {}) { this.store = store; this.clock = clock; this.limiter = new Limiter(clock); }
  /** Records `body` for the signed-in `uid`; returns whether it was stored. Never throws for bad input. */
  record(uid, body) {
    const report = sanitizePerfReport(body);
    if (!report) return false;
    // The account limit is checked first so one account cannot flood with fresh installation ids.
    if (!this.limiter.take(`a:${uid}`, perfTelemetry.perAccountPerHour) || !this.limiter.take(`i:${report.install}`, perfTelemetry.perInstallPerHour)) return false;
    const d = report.device ?? {};
    this.store.db.prepare(`INSERT INTO perf_reports(created_at, install_id, session_id, kind, platform, renderer, browser, os, pwa, app_version, app_build, data)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`).run(new Date(this.clock()).toISOString(), report.install, report.session ?? null, report.kind, d.platform ?? 'other', d.renderer ?? null,
      d.browser ?? null, d.os ?? null, d.pwa === undefined ? null : d.pwa ? 1 : 0, report.app?.version ?? null, report.app?.build ?? null, JSON.stringify(report));
    return true;
  }
}
