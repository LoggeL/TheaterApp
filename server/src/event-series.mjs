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
const dayNumber = p => Math.round(Date.UTC(p.y, p.m, p.d) / dayMs);
const gcd = (x, y) => y ? gcd(y, x % y) : x;

/** `YYYY-MM-DD` of the Europe/Berlin calendar day of an instant. */
export const berlinDay = value => { const p = berlinParts(Date.parse(value)); return isoDay(p.y, p.m, p.d); };

/** The `YYYY-MM-DD` end day of a series, validated. */
export const seriesUntil = until => {
  const valid = typeof until === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(until) ? until : fail('Bitte ein gültiges Enddatum der Serie wählen.');
  const [y, m, d] = valid.split('-').map(Number);
  return isoDay(y, m - 1, d) === valid ? valid : fail('Bitte ein gültiges Enddatum der Serie wählen.');
};

/** The day `k` steps after `base` ({y, m, d}); monthly steps land on `monthDay` or the last day of shorter months. */
const rhythmDay = (base, every, k, monthDay = base.d) => {
  if (every === 'month') {
    const first = new Date(Date.UTC(base.y, base.m + k, 1)), y = first.getUTCFullYear(), m = first.getUTCMonth();
    return { y, m, d: Math.min(monthDay, daysInMonth(y, m)) };
  }
  const shifted = new Date(Date.UTC(base.y, base.m, base.d + k * (every === 'week' ? 7 : 14)));
  return { y: shifted.getUTCFullYear(), m: shifted.getUTCMonth(), d: shifted.getUTCDate() };
};

/** Start and end on another day ({y, m, d}) at the Berlin wall-clock times of `startsAt`/`endsAt`, also overnight. */
const occurrenceOn = (startsAt, endsAt, { y, m, d }) => {
  const start = berlinParts(Date.parse(startsAt)), end = berlinParts(Date.parse(endsAt));
  const s = fromBerlin({ ...start, y, m, d });
  let e = fromBerlin({ ...end, y, m, d: d + dayNumber(end) - dayNumber(start) });
  if (e <= s) e = s + (Date.parse(endsAt) - Date.parse(startsAt)); // only within a skipped DST hour
  return { startsAt: new Date(s).toISOString(), endsAt: new Date(e).toISOString() };
};

/**
 * Start and end of every occurrence of a series, keeping the Europe/Berlin
 * wall-clock time across daylight saving switches. Monthly series stay on the
 * same day of the month, or the last day of shorter months.
 */
export function seriesOccurrences(startsAt, endsAt, repeat) {
  if (!repeat || typeof repeat !== 'object' || Array.isArray(repeat)) fail('Ungültige Wiederholung.');
  if (!seriesRhythms.includes(repeat.every)) fail('Bitte wöchentlich, alle 2 Wochen oder monatlich wiederholen.');
  const until = seriesUntil(repeat.until);
  const start = berlinParts(Date.parse(startsAt));
  const firstDay = isoDay(start.y, start.m, start.d);
  if (until < firstDay) fail('Das Serienende liegt vor dem ersten Termin.');
  if (until > isoDay(start.y + 1, start.m, start.d)) fail('Eine Terminserie darf höchstens ein Jahr umfassen.');
  const occurrences = [];
  for (let k = 0; ; k++) {
    const next = rhythmDay(start, repeat.every, k);
    if (isoDay(next.y, next.m, next.d) > until) break;
    if (occurrences.length === maxSeriesEvents) fail(`Eine Terminserie darf höchstens ${maxSeriesEvents} Termine umfassen.`);
    occurrences.push(occurrenceOn(startsAt, endsAt, next));
  }
  if (occurrences.length < 2) fail('Bis zum Serienende ergibt sich nur ein Termin. Bitte ein späteres Enddatum wählen.');
  return occurrences;
}

/**
 * The rhythm of a series: as stored at creation (`seriesRepeat.every`), else inferred
 * from the Berlin days of its occurrences when unambiguous (older series), else null.
 * Gaps of single deleted occurrences are fine: weekly means a greatest common gap of
 * 7 days, fortnightly of 14, monthly one day of the month (or the last of shorter months).
 */
export function seriesRhythm(events) {
  const stored = events.map(e => e.seriesRepeat?.every).find(x => seriesRhythms.includes(x));
  if (stored) return stored;
  const days = [...new Set(events.map(e => berlinDay(e.startsAt)))].sort().map(x => { const [y, m, d] = x.split('-').map(Number); return { y, m: m - 1, d }; });
  if (days.length < 2) return null;
  const step = days.slice(1).reduce((g, p, i) => gcd(g, dayNumber(p) - dayNumber(days[i])), 0);
  if (step === 7) return 'week';
  if (step === 14) return '2weeks';
  const monthDay = Math.max(...days.map(p => p.d)), months = days.map(p => p.y * 12 + p.m);
  const monthStep = months.slice(1).reduce((g, x, i) => gcd(g, x - months[i]), 0);
  return monthStep === 1 && days.every(p => p.d === Math.min(monthDay, daysInMonth(p.y, p.m))) ? 'month' : null;
}

/**
 * New occurrences after `last`, the latest occurrence of a series, up to the day `until`:
 * in the series rhythm and at the Berlin wall-clock times of `times` ({startsAt, endsAt}).
 * A monthly series on the last day of a shorter month returns to the latest day of the
 * month among `days` (the series' `YYYY-MM-DD` days). Per request as for a new series:
 * one year, 52 dates.
 */
export function seriesExtension(last, every, until, days = [], times = last) {
  if (!seriesRhythms.includes(every)) fail('Der Rhythmus der Serie ist nicht bekannt, sie lässt sich nicht verlängern.');
  until = seriesUntil(until);
  const base = berlinParts(Date.parse(last.startsAt));
  if (until > isoDay(base.y + 1, base.m, base.d)) fail('Eine Serie lässt sich auf einmal um höchstens ein Jahr verlängern.');
  const monthDay = base.d === daysInMonth(base.y, base.m) ? Math.max(base.d, ...days.map(x => +x.slice(8, 10))) : base.d;
  const occurrences = [];
  for (let k = 1; ; k++) {
    const next = rhythmDay(base, every, k, monthDay);
    if (isoDay(next.y, next.m, next.d) > until) break;
    if (occurrences.length === maxSeriesEvents) fail(`Eine Serie lässt sich auf einmal um höchstens ${maxSeriesEvents} Termine verlängern.`);
    occurrences.push(occurrenceOn(times.startsAt, times.endsAt, next));
  }
  if (!occurrences.length) fail('Bis zum neuen Serienende kommt kein Termin hinzu. Bitte ein späteres Enddatum wählen.');
  return occurrences;
}

/**
 * Start and end of occurrence `x` after a whole-series edit from `old` to `e`: a changed
 * start or end time is taken over in Berlin wall-clock time on x's own day, an unchanged
 * one stays as x has it (also an individually moved one).
 */
export function seriesRetime(x, old, e) {
  const clock = v => { const p = berlinParts(Date.parse(v)); return [p.h, p.mi, dayNumber(p)]; };
  const [oh, om, od] = clock(old.startsAt), [nh, nm, nd] = clock(e.startsAt), [oeh, oem, oed] = clock(old.endsAt), [neh, nem, ned] = clock(e.endsAt);
  const startChanged = oh !== nh || om !== nm, endChanged = oeh !== neh || oem !== nem || oed - od !== ned - nd;
  if (!startChanged && !endChanged) return { startsAt: x.startsAt, endsAt: x.endsAt };
  const target = occurrenceOn(e.startsAt, e.endsAt, berlinParts(Date.parse(x.startsAt)));
  const startsAt = startChanged ? target.startsAt : x.startsAt;
  let endsAt = endChanged ? target.endsAt : x.endsAt;
  if (endsAt <= startsAt) endsAt = new Date(Date.parse(startsAt) + Date.parse(e.endsAt) - Date.parse(e.startsAt)).toISOString();
  return { startsAt, endsAt };
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
