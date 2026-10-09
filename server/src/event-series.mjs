import { AppError } from './theater.mjs';

const fail = message => { throw new AppError(400, message); };
const dayMs = 86400000;
export const seriesRhythms = ['week', '2weeks', 'month'];
export const maxSeriesEvents = 52;

const berlinFormat = new Intl.DateTimeFormat('en-US', {
  timeZone: 'Europe/Berlin', hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit',
});

/** Europe/Berlin wall-clock parts of an instant (month is 0-based). */
export function berlinParts(ms) {
  const p = Object.fromEntries(berlinFormat.formatToParts(new Date(ms)).map(x => [x.type, x.value]));
  return { y: +p.year, m: +p.month - 1, d: +p.day, h: +p.hour, mi: +p.minute, s: +p.second, ms: ((ms % 1000) + 1000) % 1000 };
}
const asUtc = p => Date.UTC(p.y, p.m, p.d, p.h, p.mi, p.s, p.ms);
const offset = ms => asUtc(berlinParts(ms)) - ms;

/** The instant at which Berlin's clocks show the given wall time. */
export function fromBerlin(p) {
  const wall = asUtc(p);
  // Two passes settle on the offset valid at the target; a wall time skipped
  // by the spring switch lands one hour later, as clocks do.
  const first = wall - offset(wall);
  return wall - offset(first);
}

const daysInMonth = (y, m) => new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
const isoDay = (y, m, d) => new Date(Date.UTC(y, m, d)).toISOString().slice(0, 10);

/**
 * Start and end of every occurrence of a series, keeping the Europe/Berlin
 * wall-clock time across daylight saving switches. Monthly series stay on the
 * same day of the month, or the last day of shorter months.
 */
export function seriesOccurrences(startsAt, endsAt, repeat) {
  if (!repeat || typeof repeat !== 'object' || Array.isArray(repeat)) fail('Ungültige Wiederholung.');
  if (!seriesRhythms.includes(repeat.every)) fail('Bitte wöchentlich, alle 2 Wochen oder monatlich wiederholen.');
  const until = typeof repeat.until === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(repeat.until) ? repeat.until : fail('Bitte ein gültiges Enddatum der Serie wählen.');
  const [uy, um, ud] = until.split('-').map(Number);
  if (isoDay(uy, um - 1, ud) !== until) fail('Bitte ein gültiges Enddatum der Serie wählen.');
  const start = berlinParts(Date.parse(startsAt)), end = berlinParts(Date.parse(endsAt));
  const firstDay = isoDay(start.y, start.m, start.d);
  if (until < firstDay) fail('Das Serienende liegt vor dem ersten Termin.');
  if (until > isoDay(start.y + 1, start.m, start.d)) fail('Eine Terminserie darf höchstens ein Jahr umfassen.');
  const endDays = Math.round((Date.UTC(end.y, end.m, end.d) - Date.UTC(start.y, start.m, start.d)) / dayMs);
  const occurrences = [];
  for (let k = 0; ; k++) {
    let y = start.y, m = start.m, d = start.d;
    if (repeat.every === 'month') { const first = new Date(Date.UTC(y, m + k, 1)); y = first.getUTCFullYear(); m = first.getUTCMonth(); d = Math.min(d, daysInMonth(y, m)); }
    else { const shifted = new Date(Date.UTC(y, m, d + k * (repeat.every === 'week' ? 7 : 14))); y = shifted.getUTCFullYear(); m = shifted.getUTCMonth(); d = shifted.getUTCDate(); }
    if (isoDay(y, m, d) > until) break;
    if (occurrences.length === maxSeriesEvents) fail(`Eine Terminserie darf höchstens ${maxSeriesEvents} Termine umfassen.`);
    const s = fromBerlin({ ...start, y, m, d });
    let e = fromBerlin({ ...end, y, m, d: d + endDays });
    if (e <= s) e = s + (Date.parse(endsAt) - Date.parse(startsAt)); // only within a skipped DST hour
    occurrences.push({ startsAt: new Date(s).toISOString(), endsAt: new Date(e).toISOString() });
  }
  if (occurrences.length < 2) fail('Bis zum Serienende ergibt sich nur ein Termin. Bitte ein späteres Enddatum wählen.');
  return occurrences;
}

const weekdays = ['sonntags', 'montags', 'dienstags', 'mittwochs', 'donnerstags', 'freitags', 'samstags'];
const pad = n => String(n).padStart(2, '0');

/** Push text for a new series, e.g. "12 Termine, dienstags 19:00, ab 15.9.". */
export function seriesSummary(occurrences, every) {
  const first = berlinParts(Date.parse(occurrences[0].startsAt));
  const time = `${pad(first.h)}:${pad(first.mi)}`;
  const weekday = weekdays[new Date(Date.UTC(first.y, first.m, first.d)).getUTCDay()];
  const rhythm = every === 'month' ? `monatlich am ${first.d}. um ${time}` : `${every === '2weeks' ? 'alle 2 Wochen ' : ''}${weekday} ${time}`;
  return `${occurrences.length} Termine, ${rhythm}, ab ${first.d}.${first.m + 1}.`;
}
