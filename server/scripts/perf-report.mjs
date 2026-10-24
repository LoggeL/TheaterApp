#!/usr/bin/env node
// Summarizes the performance telemetry (src/perf-telemetry.mjs) as Markdown. Read-only:
//   node scripts/perf-report.mjs <db> [--days 7]
// In the container: docker exec <container> node scripts/perf-report.mjs /data/theater.sqlite --days 7
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
import { frameEdges, latencyEdges } from '../src/perf-telemetry.mjs';

const dayMs = 24 * 3600000;

/** The `q` quantile (0..1) of a bucket histogram, interpolated inside the bucket. */
export function histQuantile(hist, edges, q, max = null) {
  const total = hist.reduce((a, b) => a + b, 0);
  if (!total) return null;
  let target = q * total, low = 0;
  for (let i = 0; i < hist.length; i++) {
    const high = i < edges.length ? edges[i] : Math.max(max ?? edges.at(-1) * 2, edges.at(-1));
    if (target <= hist[i] && hist[i] > 0) return Math.min(low + (high - low) * (target / hist[i]), max ?? Infinity);
    target -= hist[i]; low = high;
  }
  return max;
}
const quantile = (values, q) => {
  const v = values.filter(x => Number.isFinite(x)).sort((a, b) => a - b);
  if (!v.length) return null;
  const pos = (v.length - 1) * q, lo = Math.floor(pos), hi = Math.ceil(pos);
  return v[lo] + (v[hi] - v[lo]) * (pos - lo);
};
const fmt = (x, digits = 1) => x === null || x === undefined || !Number.isFinite(x) ? '–' : x.toFixed(digits).replace(/\.0+$/, '');
const pct = (part, whole) => !whole ? '–' : !part ? '0 %' : `${(100 * part / whole).toFixed(part / whole < 0.01 ? 2 : 1)} %`;
const table = (head, rows) => rows.length ? [`| ${head.join(' | ')} |`, `|${head.map(() => '---').join('|')}|`, ...rows.map(r => `| ${r.join(' | ')} |`)].join('\n') : '_keine Daten_';

class FrameGroup {
  constructor() { this.hist = new Array(frameEdges.length + 1).fill(0); this.n = 0; this.ms = 0; this.j25 = 0; this.j50 = 0; this.j100 = 0; this.max = 0; this.installs = new Set(); this.reports = 0; }
  add(f, install) {
    if (!f?.n) return;
    if (Array.isArray(f.h)) f.h.forEach((x, i) => { this.hist[i] += x; });
    this.n += f.n; this.ms += f.ms ?? 0; this.j25 += f.j25 ?? 0; this.j50 += f.j50 ?? 0; this.j100 += f.j100 ?? 0; this.max = Math.max(this.max, f.max ?? 0);
    this.installs.add(install); this.reports++;
  }
  q(p) { return histQuantile(this.hist, frameEdges, p, this.max); }
  row(label) {
    const minutes = this.ms / 60000;
    return [label, this.installs.size, this.reports, this.n, fmt(minutes), fmt(this.q(0.5)), fmt(this.q(0.95)), fmt(this.q(0.99)), fmt(this.max, 0), pct(this.j25, this.n), pct(this.j50, this.n), pct(this.j100, this.n), minutes ? fmt(this.j50 / minutes, 2) : '–'];
  }
}
const frameHead = ['Gruppe', 'Inst.', 'Berichte', 'Bilder', 'Min. aktiv', 'p50 ms', 'p95 ms', 'p99 ms', 'max ms', '>25 ms', '>50 ms', '>100 ms', '>50 ms/min'];
const groupBy = (items, key, add) => {
  const groups = new Map();
  for (const item of items) { const k = key(item); if (k === null || k === undefined) continue; if (!groups.has(k)) groups.set(k, new FrameGroup()); add(groups.get(k), item); }
  return groups;
};
const frameTable = (rows, key, { limit = 25, minFrames = 0 } = {}) => {
  const groups = [...groupBy(rows, key, (g, r) => g.add(r.data.frames, r.install_id))].filter(([, g]) => g.n > minFrames).sort((a, b) => b[1].n - a[1].n).slice(0, limit);
  return table(frameHead, groups.map(([k, g]) => g.row(k)));
};

const memBucket = m => m === undefined ? 'RAM ?' : m <= 2 ? 'RAM ≤2 GB' : m <= 4 ? 'RAM 4 GB' : 'RAM ≥8 GB';
const coreBucket = c => c === undefined ? '? Kerne' : c <= 4 ? '≤4 Kerne' : c <= 8 ? '5–8 Kerne' : '>8 Kerne';
const keys = {
  platform: r => `${r.platform} · ${r.renderer ?? '?'}`,
  browser: r => r.platform === 'web' ? `${r.browser ?? '?'} · ${r.os ?? '?'}` : `${r.platform} · ${r.os ?? '?'}`,
  pwa: r => r.platform !== 'web' ? null : r.pwa === 1 ? 'Web · installiert (standalone)' : r.pwa === 0 ? 'Web · Browser-Tab' : 'Web · ?',
  device: r => {
    const d = r.data.device ?? {};
    if (r.platform === 'android') return `android · ${d.model ?? '?'}${d.mem ? ` · ${memBucket(d.mem)}` : ''}`;
    return `${r.platform} · ${d.mobile ? 'mobil' : d.mobile === false ? 'Desktop' : '?'} · ${memBucket(d.mem)} · ${coreBucket(d.cores)}`;
  },
  refresh: r => { const hz = r.data.device?.hz; return hz ? `${r.platform} · ${Math.round(hz)} Hz` : r.platform === 'web' ? 'web · im Browser nicht messbar' : `${r.platform} · ? Hz`; },
  version: r => `${r.app_version ?? '?'}${r.app_build ? `+${r.app_build}` : ''} · ${r.platform}`,
};

const startupTable = rows => {
  const groups = new Map();
  for (const r of rows) {
    const s = r.data.startup; if (!s) continue;
    const k = `${keys.platform(r)} · ${s.kind ?? '?'}`;
    if (!groups.has(k)) groups.set(k, { installs: new Set(), items: [] });
    groups.get(k).installs.add(r.install_id); groups.get(k).items.push(s);
  }
  const cell = (items, field) => { const v = items.map(s => s[field]); return `${fmt(quantile(v, 0.5), 0)} / ${fmt(quantile(v, 0.95), 0)}`; };
  return table(['Gruppe · Start', 'Inst.', 'Starts', 'vor Dart p50/p95', 'erstes Bild p50/p95', 'bereit p50/p95', 'Daten p50/p95'],
    [...groups].sort((a, b) => b[1].items.length - a[1].items.length).map(([k, g]) => [k, g.installs.size, g.items.length, cell(g.items, 'preMs'), cell(g.items, 'firstFrameMs'), cell(g.items, 'readyMs'), cell(g.items, 'dataMs')]));
};

const apiTable = (rows, key, limit) => {
  const groups = new Map();
  for (const r of rows) for (const a of r.data.api ?? []) {
    const k = key(r, a);
    if (!groups.has(k)) groups.set(k, { n: 0, err: 0, off: 0, max: 0, hist: new Array(latencyEdges.length + 1).fill(0), installs: new Set() });
    const g = groups.get(k);
    g.n += a.n; g.err += a.err ?? 0; g.off += a.off ?? 0; g.max = Math.max(g.max, a.max ?? 0); g.installs.add(r.install_id);
    a.h?.forEach((x, i) => { g.hist[i] += x; });
  }
  return table(['Aufruf', 'Inst.', 'Anzahl', 'p50 ms', 'p95 ms', 'max ms', 'Fehler', 'offline'],
    [...groups].sort((a, b) => b[1].n - a[1].n).slice(0, limit).map(([k, g]) => [k, g.installs.size, g.n, fmt(histQuantile(g.hist, latencyEdges, 0.5, g.max), 0), fmt(histQuantile(g.hist, latencyEdges, 0.95, g.max), 0), fmt(g.max, 0), pct(g.err, g.n), pct(g.off, g.n)]));
};

const frameTimingTable = rows => {
  const groups = new Map();
  for (const r of rows) {
    const f = r.data.frames; if (!f?.n) continue;
    const k = keys.platform(r);
    if (!groups.has(k)) groups.set(k, { reports: 0, withTimings: 0, b50: [], b95: [], r50: [], r95: [], t95: [] });
    const g = groups.get(k); g.reports++;
    if (f.ft) { g.withTimings++; for (const x of ['b50', 'b95', 'r50', 'r95', 't95']) g[x].push(f[x]); }
  }
  return table(['Gruppe', 'Berichte', 'mit FrameTiming', 'Build p50', 'Build p95', 'Raster p50', 'Raster p95', 'Gesamt p95'],
    [...groups].map(([k, g]) => [k, g.reports, pct(g.withTimings, g.reports), ...['b50', 'b95', 'r50', 'r95', 't95'].map(x => fmt(quantile(g[x], 0.5)))]));
};

const triggers = runs => {
  const counts = new Map(); let worst = 0, quiet = 0;
  for (const r of runs) for (const w of r.data.worst ?? []) {
    if (w.ms < 50) continue;
    worst++;
    const ev = (w.ev ?? '').split(',').filter(Boolean);
    if (!ev.length) quiet++;
    for (const e of new Set(ev)) counts.set(e, (counts.get(e) ?? 0) + 1);
  }
  const rows = [...counts].sort((a, b) => b[1] - a[1]).map(([e, n]) => [e, n, pct(n, worst)]);
  if (quiet) rows.push(['(kein Ereignis im Bild)', quiet, pct(quiet, worst)]);
  return { worst, text: table(['Ereignis im Ruckel-Bild (≥50 ms)', 'Ruckler', 'Anteil'], rows) };
};

const worstTable = (rows, limit) => {
  const all = rows.flatMap(r => (r.data.worst ?? []).map(w => ({ ...w, r: w.r ?? (r.kind === 'stageRunner' ? 'stageRunner' : '?'), row: r })));
  all.sort((a, b) => b.ms - a.ms);
  return table(['ms', 'Kontext', 'Gerät', 'Version', 'Eingabe', 'Ereignisse', 'Zeitpunkt'], all.slice(0, limit).map(w => [fmt(w.ms, 0), w.r, `${keys.platform(w.row)} · ${w.row.browser ?? w.row.data.device?.model ?? ''}`, w.row.app_version ?? '?', w.in ?? '–', w.ev ?? '–', w.m !== undefined ? `${fmt(w.t, 1)} s · ${w.m} m` : `${fmt(w.t, 0)} s nach Start`]));
};

/** The Markdown summary of the last `days` days in `db` (a DatabaseSync). */
export function perfReport(db, { days = 7, now = new Date() } = {}) {
  const since = new Date(+now - days * dayMs).toISOString();
  const rows = db.prepare('SELECT created_at, install_id, session_id, kind, platform, renderer, browser, os, pwa, app_version, app_build, data FROM perf_reports WHERE created_at >= ? ORDER BY created_at').all(since)
    .map(r => { try { return { ...r, data: JSON.parse(r.data) }; } catch { return null; } }).filter(Boolean);
  const app = rows.filter(r => r.kind === 'app'), runs = rows.filter(r => r.kind === 'stageRunner');
  const installs = new Set(rows.map(r => r.install_id)), sessions = new Set(app.map(r => r.session_id).filter(Boolean));
  const out = [`# Performance-Telemetrie: ${since.slice(0, 10)} bis ${now.toISOString().slice(0, 10)} (${days} Tage)`, '',
    `Berichte: ${rows.length} (App ${app.length}, Bühnenlauf ${runs.length}) · Installationen: ${installs.size} · App-Sitzungen: ${sessions.size}`,
    rows.length ? `Zeitraum der Daten: ${rows[0].created_at.slice(0, 16)} bis ${rows.at(-1).created_at.slice(0, 16)} UTC` : '_Keine Berichte im Zeitraum._', '',
    'Bildzeit = Abstand aufeinanderfolgender Bilder, solange die App ununterbrochen zeichnet (Pausen ohne angefordertes Bild zählen nicht). Prozentwerte: Anteil der Bilder über der Grenze. „>50 ms/min“: Ruckler über 50 ms je Minute aktiver Darstellung. Gruppen-Perzentile sind aus groben Histogrammen interpoliert (Näherung); Ruckel-Anteile und max sind exakt.'];
  if (!rows.length) return out.join('\n');
  out.push('', '## App: Bildzeiten nach Plattform und Renderer', frameTable(app, keys.platform));
  out.push('', '## App: nach Browser und Betriebssystem', frameTable(app, keys.browser));
  out.push('', '## App: Web installiert (PWA) oder im Browser-Tab', frameTable(app, keys.pwa));
  out.push('', '## App: nach Gerät (Typ, Speicher, Kerne)', frameTable(app, keys.device));
  out.push('', '## App: nach Bildwiederholrate', frameTable(app, keys.refresh));
  out.push('', '## App: nach App-Version', frameTable(app, keys.version));
  const routeRows = app.flatMap(r => (r.data.routes ?? []).map(x => ({ ...r, data: { frames: x }, route: x.r })));
  out.push('', '## App: nach Bildschirm (alle Plattformen)', frameTable(routeRows, r => r.route, { limit: 30 }));
  out.push('', '## App: nach Bildschirm und Plattform (ab 300 Bildern)', frameTable(routeRows, r => `${r.route} · ${keys.platform(r)}`, { limit: 40, minFrames: 300 }));
  out.push('', '## FrameTiming (Build/Raster, Median über Berichte)', frameTimingTable(app));
  out.push('', '## Start', 'vor Dart: Laden bis zum Start des Dart-Codes (Web: seit Navigation; Android: seit Prozessstart). Erstes Bild, bereit (gespeicherte Daten sichtbar) und Daten (erste Antwort von /snapshot) zählen ab Dart-Start.', startupTable(app));
  out.push('', '## API-Latenzen nach Aufruf', apiTable(rows, (r, a) => `${a.m} ${a.p}`, 25));
  out.push('', '## API-Latenzen nach Plattform und Netz', apiTable(rows, r => `${r.platform} · ${r.data.device?.net ?? '?'}`, 15));
  out.push('', '## Bühnenlauf');
  if (!runs.length) out.push('_Keine Läufe im Zeitraum._');
  else {
    const minutes = runs.reduce((a, r) => a + (r.data.run?.ms ?? 0), 0) / 60000;
    out.push(`Läufe: ${runs.length} · Spielzeit: ${fmt(minutes)} min · Installationen: ${new Set(runs.map(r => r.install_id)).size}`, '');
    out.push('### Bildzeiten der Spielschleife nach Plattform und Renderer', frameTable(runs, keys.platform));
    out.push('', '### nach Browser', frameTable(runs, keys.browser));
    out.push('', '### nach Gerät', frameTable(runs, keys.device));
    out.push('', '### nach Figur', frameTable(runs, r => r.data.run?.character ?? 'Standard', { limit: 15 }));
    out.push('', '### nach Bühnenbild und Effekt', frameTable(runs, r => `${r.data.run?.backdrop ?? 'Standard'} · ${r.data.run?.fx ?? 'ohne'}`, { limit: 15 }));
    const t = triggers(runs);
    out.push('', `### Häufigste Ruckel-Auslöser (${t.worst} Ruckler ≥50 ms aus den je 5 schlimmsten pro Lauf)`, t.text);
  }
  out.push('', '## Schlimmste Ruckler', worstTable(rows, 15));
  return out.join('\n');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2), daysAt = args.indexOf('--days');
  const days = daysAt >= 0 ? Number(args[daysAt + 1]) : 7, path = args.find((a, i) => !a.startsWith('--') && (daysAt < 0 || i !== daysAt + 1));
  if (!path || !Number.isFinite(days) || days <= 0) { console.error('Aufruf: node scripts/perf-report.mjs <db> [--days 7]'); process.exit(2); }
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    const exists = db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='perf_reports'").get();
    console.log(exists ? perfReport(db, { days }) : 'Die Datenbank enthält noch keine Performance-Telemetrie (Tabelle perf_reports fehlt).');
  } finally { db.close(); }
}
