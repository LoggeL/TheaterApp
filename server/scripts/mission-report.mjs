#!/usr/bin/env node
// Summarizes the history of the stage runner's Tagesmissionen (src/runner-mission-log.mjs) as
// Markdown, for balancing. Read-only, aggregates only (no names, no person ids):
//   node scripts/mission-report.mjs <db> [--days 14] [--today]
// In the container: docker exec <container> node scripts/mission-report.mjs /data/theater.sqlite --days 14
// Without --today only complete Berlin days count (yesterday and before): today's open missions
// would look harder than they are.
import { DatabaseSync } from 'node:sqlite';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const dayMs = 24 * 3600000;
const slots = ['easy', 'medium', 'hard'];
const slotNames = { easy: 'leicht', medium: 'mittel', hard: 'schwer' };
// Below these a flag gets a small-sample warning.
export const reportLimits = Object.freeze({ minPlayed: 10, minPlayers: 3, easyCompletion: 0.9, easyRuns: 1, hardCompletion: 0.25 });

const berlinDay = value => new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Berlin' }).format(new Date(value));
const quantile = (values, q) => {
  const v = values.filter(x => Number.isFinite(x)).sort((a, b) => a - b);
  if (!v.length) return null;
  const pos = (v.length - 1) * q, lo = Math.floor(pos), hi = Math.ceil(pos);
  return v[lo] + (v[hi] - v[lo]) * (pos - lo);
};
const fmt = (x, digits = 1) => x === null || x === undefined || !Number.isFinite(x) ? '–' : x.toFixed(digits).replace(/\.0+$/, '').replace(/(\.\d*?)0+$/, '$1');
const pct = (part, whole) => !whole ? '–' : `${Math.round(100 * part / whole)} %`;
const table = (head, rows) => rows.length ? [`| ${head.join(' | ')} |`, `|${head.map(() => '---').join('|')}|`, ...rows.map(r => `| ${r.join(' | ')} |`)].join('\n') : '_keine Daten_';
const parse = data => { try { return JSON.parse(data); } catch { return {}; } };

/** The figures of a group of rows (missions). */
export function missionStats(rows) {
  const played = rows.filter(r => r.runs > 0 || r.done), done = rows.filter(r => r.done);
  const open = played.filter(r => !r.done), runsToDone = done.map(r => r.runs_to_done);
  return {
    offered: rows.length, players: new Set(rows.map(r => r.person_id)).size, played: played.length, done: done.length,
    completion: played.length ? done.length / played.length : null,
    rerolledAway: rows.filter(r => r.rerolled_to).length,
    runs: { p25: quantile(runsToDone, 0.25), p50: quantile(runsToDone, 0.5), p75: quantile(runsToDone, 0.75) },
    minutes: quantile(done.map(r => r.minutes_to_done), 0.5),
    openProgress: quantile(open.map(r => r.target > 0 ? Math.min(1, r.progress / r.target) : null), 0.5),
    ratio: quantile(rows.map(r => r.details.derivation?.ratio), 0.5),
    fromStart: rows.filter(r => r.details.derivation?.source === 'start').length,
  };
}

/** "zu leicht?" / "zu schwer?" with a warning for small samples; empty if neither. */
export function missionFlag(s, limits = reportLimits) {
  if (s.completion === null) return '';
  const flag = s.completion > limits.easyCompletion && s.runs.p50 !== null && s.runs.p50 <= limits.easyRuns ? 'zu leicht?'
    : s.completion < limits.hardCompletion ? 'zu schwer?' : '';
  return flag && (s.played < limits.minPlayed || s.players < limits.minPlayers) ? `${flag} (kleine Stichprobe)` : flag;
}

const head = ['angeboten', 'Spieler', 'gespielt', 'geschafft', 'weggewürfelt', 'Läufe bis geschafft p50 (p25–p75)', 'Min. bis geschafft p50', 'offen: Fortschritt p50', 'Ziel/Bestwert p50', 'Startwert', 'Hinweis'];
const cells = s => [s.offered, s.players, s.played, s.completion === null ? '–' : `${pct(s.done, s.played)} (${s.done})`, pct(s.rerolledAway, s.offered),
  s.runs.p50 === null ? '–' : `${fmt(s.runs.p50)} (${fmt(s.runs.p25)}–${fmt(s.runs.p75)})`, fmt(s.minutes), s.openProgress === null ? '–' : pct(s.openProgress, 1), fmt(s.ratio, 2), pct(s.fromStart, s.offered), missionFlag(s)];

const grouped = (rows, key) => {
  const groups = new Map();
  for (const r of rows) { const k = key(r); if (k === null) continue; if (!groups.has(k)) groups.set(k, []); groups.get(k).push(r); }
  return groups;
};
const slotOrder = (a, b) => slots.indexOf(a) - slots.indexOf(b);

/** The Markdown report of the last [days] Berlin days in [db] (a DatabaseSync); [today]: include today. */
export function missionReport(db, { days = 14, now = new Date(), today = false } = {}) {
  const last = berlinDay(today ? now : +now - dayMs), first = berlinDay(+new Date(`${last}T12:00:00Z`) - (days - 1) * dayMs);
  const rows = db.prepare('SELECT day, person_id, slot, type, kind, target, reward, best, client_stats, rerolled, rerolled_from, rerolled_to, done, runs, runs_to_done, progress, minutes_to_done, crate, data FROM runner_mission_log WHERE day >= ? AND day <= ? ORDER BY day, id')
    .all(first, last).map(r => ({ ...r, details: parse(r.data) }));
  const personDays = grouped(rows, r => `${r.day}:${r.person_id}`);
  const out = [`# Tagesmissionen: ${first} bis ${last} (${days} Tage${today ? ', mit heute' : ', nur abgeschlossene Tage'})`, '',
    `Missionen: ${rows.length} · Spieltage (Person × Tag mit Missionen): ${personDays.size} · Spieler: ${new Set(rows.map(r => r.person_id)).size} · ohne Laufstatistik (ältere Apps): ${pct(rows.filter(r => !r.client_stats).length, rows.length)}`];
  if (!rows.length) return [...out, '', '_Keine Missionen im Zeitraum._'].join('\n');
  out.push('', '„gespielt“: Missionen mit mindestens einem Lauf, solange sie offen waren; „geschafft“ ist der Anteil davon. „weggewürfelt“: Anteil der angebotenen, die neu gewürfelt wurden. „Läufe bis geschafft“: Läufe des Tages mit der offenen Mission bis einschließlich des Laufs, der sie schafft. „Min. bis geschafft“: vom Ende des ersten Laufs des Tages bis zu diesem Lauf (0 = im ersten Lauf). „offen: Fortschritt“: Fortschritt / Ziel der gespielten, nicht geschafften. „Ziel/Bestwert“: Ziel (bei „runs“ die Mindestmeter) durch den gespeicherten Lebenszeit-Bestwert pro Lauf (bei adaptiven Zielen nur Vergleich, nicht Erzeugungsbasis). „Startwert“: Anteil ohne gemessene Basis; konservative Start-Caps und adaptive Quantile werden separat im Verlauf gekennzeichnet.',
    `Hinweise: „zu leicht?“ bei mehr als ${reportLimits.easyCompletion * 100} % geschafft mit höchstens ${reportLimits.easyRuns} Lauf (Median), „zu schwer?“ unter ${reportLimits.hardCompletion * 100} % geschafft; „kleine Stichprobe“ unter ${reportLimits.minPlayed} gespielten Missionen oder ${reportLimits.minPlayers} Spielern.`);
  out.push('', '## Nach Stufe', table(['Stufe', ...head], [...grouped(rows, r => r.slot)].sort(([a], [b]) => slotOrder(a, b)).map(([slot, g]) => [slotNames[slot] ?? slot, ...cells(missionStats(g))])));
  const types = [...grouped(rows, r => `${r.type}\u0000${r.slot}`)].sort(([a], [b]) => { const [ta, sa] = a.split('\u0000'), [tb, sb] = b.split('\u0000'); return ta.localeCompare(tb) || slotOrder(sa, sb); });
  out.push('', '## Nach Typ und Stufe', table(['Typ', 'Stufe', ...head], types.map(([k, g]) => { const [type, slot] = k.split('\u0000'); return [type, slotNames[slot] ?? slot, ...cells(missionStats(g))]; })));
  const kinds = [...grouped(rows.filter(r => r.kind), r => `${r.type}:${r.kind}\u0000${r.slot}`)].sort(([a], [b]) => { const [ta, sa] = a.split('\u0000'), [tb, sb] = b.split('\u0000'); return ta.localeCompare(tb) || slotOrder(sa, sb); });
  if (kinds.length) out.push('', '## Nach Art (Sammeln, Hindernisse, Debüt) und Stufe', table(['Typ:Art', 'Stufe', ...head], kinds.map(([k, g]) => { const [type, slot] = k.split('\u0000'); return [type, slotNames[slot] ?? slot, ...cells(missionStats(g))]; })));
  out.push('', '## Nach App (mit oder ohne Laufstatistik) und Stufe', table(['App', 'Stufe', ...head], [...grouped(rows, r => `${r.client_stats ? 'mit Statistik' : 'ohne Statistik'}\u0000${r.slot}`)]
    .sort(([a], [b]) => { const [ca, sa] = a.split('\u0000'), [cb, sb] = b.split('\u0000'); return ca.localeCompare(cb) || slotOrder(sa, sb); })
    .map(([k, g]) => { const [client, slot] = k.split('\u0000'); return [client, slotNames[slot] ?? slot, ...cells(missionStats(g))]; })));
  const rerolls = [...grouped(rows.filter(r => r.rerolled_to), r => `${r.type} → ${r.rerolled_to}`)].sort((a, b) => b[1].length - a[1].length);
  if (rerolls.length) out.push('', '## Neu gewürfelt (von → zu)', table(['Wechsel', 'Anzahl', 'davor gespielt'], rerolls.slice(0, 20).map(([k, g]) => [k, g.length, pct(g.filter(r => r.runs > 0).length, g.length)])));
  // Missionskiste: all three done on one day.
  const dayRows = [...grouped(rows, r => r.day)].map(([day, g]) => {
    const people = [...grouped(g, r => r.person_id).values()];
    const played = people.filter(p => p.some(r => r.runs > 0 || r.done)), crates = people.filter(p => p.some(r => r.crate));
    const dayRuns = played.map(p => Math.max(...p.map(r => r.details.dayRuns ?? 0)));
    const crateRuns = crates.map(p => p.find(r => Number.isInteger(r.details.crateRuns) && r.details.crateRuns > 0)?.details.crateRuns).filter(Number.isFinite);
    return { day, people: people.length, played: played.length, crates: crates.length, runs: quantile(dayRuns, 0.5),
      crateMedian: quantile(crateRuns, 0.5), measured: crateRuns.length, withinTen: crateRuns.filter(n => n <= 10).length };
  });
  const sum = k => dayRows.reduce((a, d) => a + d[k], 0);
  out.push('', '## Missionskiste je Tag', 'Spieler: Personen mit Missionen an dem Tag; gespielt: davon mit mindestens einem Lauf; Kiste: alle drei geschafft (Anteil der gespielt habenden); Läufe: Median aller gespielten Läufe, NICHT Aufwand bis zur Kiste. Kiste: Läufe p50 zählt nur gemessene Abschlüsse (n). Ziel: die komplette Missionskiste im Median in höchstens 10 Läufen. Kiste bis Lauf 10 ist eine Anzahl, kein Erfolgsanteil nur unter Gewinnern; mit „gespielt“ und fehlenden Messungen zusammen lesen. Alte Kisten ohne Abschlusszähler bleiben unbekannt; bei kleinen Stichproben oder offenen/abgebrochenen Tagen ist kein Zielnachweis möglich.',
    table(['Tag', 'Spieler', 'gespielt', 'Kiste', 'Kistenquote', 'Läufe p50', 'Kiste: Läufe p50', 'Kiste: gemessen n', 'Kiste bis Lauf 10'], [...dayRows.map(d => [d.day, d.people, d.played, d.crates, pct(d.crates, d.played), fmt(d.runs), fmt(d.crateMedian), d.measured, d.withinTen]),
      ['gesamt', sum('people'), sum('played'), sum('crates'), pct(sum('crates'), sum('played')), '', '', sum('measured'), sum('withinTen')]]));
  return out.join('\n');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2), daysAt = args.indexOf('--days');
  const days = daysAt >= 0 ? Number(args[daysAt + 1]) : 14, path = args.find((a, i) => !a.startsWith('--') && (daysAt < 0 || i !== daysAt + 1));
  if (!path || !Number.isInteger(days) || days <= 0) { console.error('Aufruf: node scripts/mission-report.mjs <db> [--days 14] [--today]'); process.exit(2); }
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    const exists = db.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name='runner_mission_log'").get();
    console.log(exists ? missionReport(db, { days, today: args.includes('--today') }) : 'Die Datenbank enthält noch keinen Missionsverlauf (Tabelle runner_mission_log fehlt).');
  } finally { db.close(); }
}
