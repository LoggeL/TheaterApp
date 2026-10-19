import { createHash, randomBytes } from 'node:crypto';
import { AppError, inAudience } from './theater.mjs';

// Personal calendar subscription ("Kalender-Abo"): every account can get one secret link to an
// iCalendar feed of the events it is invited to. Calendar apps send no credentials, so the
// random token in the path is the only proof. Records (kind `calendarFeeds`) are keyed by the
// SHA-256 of the token like device tokens; the token itself stays readable so that the app can
// show the same link again on every device. Resetting replaces the record, so the old link stops
// working at once. Declined events (also the automatic declines of an absence) are left out, and
// the feed carries no alarms: reminders stay with the app.
export const calendarFeedLimits = Object.freeze({ pastDays: 60, tokenRequests: 60, clientMisses: 30, windowMs: 10 * 60000, maxTracked: 5000 });
// Shared with the single event export of the app (lib/features/events/data/ics_export.dart),
// so a calendar can recognise an event it got both ways.
export const calendarUidDomain = 'kolpingtheater.ramsen';
export const calendarName = 'Kolpingtheater Ramsen';
export const calendarRefresh = 'PT1H';
const tokenPattern = /^[A-Za-z0-9_-]{32}$/;

const fail = (status, message, code) => { throw new AppError(status, message, code); };
const hash = token => createHash('sha256').update(token).digest('hex');
const day = value => new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Berlin' }).format(new Date(value));
const feedOf = (store, uid) => store.all('calendarFeeds').find(f => f.uid === uid) ?? null;

/** The public address of a feed; `appOrigin` is the configured base address of the app. */
export function calendarFeedUrl(appOrigin, token) {
  let origin;
  try { origin = new URL(appOrigin); } catch { origin = null; }
  // Plain HTTP only for a server on this computer (development).
  const local = origin?.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(origin.hostname);
  if (!origin || !(origin.protocol === 'https:' || local) || origin.username || origin.password) fail(409, 'Das Kalender-Abo ist auf diesem Server nicht eingerichtet.', 'calendar_unavailable');
  return new URL(`/api/calendar/${token}.ics`, origin).href;
}

const create = (theater, a) => {
  const token = randomBytes(24).toString('base64url'), feed = { id: hash(token), uid: a.uid, personId: a.personId, token, createdAt: new Date(+theater.clock()).toISOString() };
  theater.store.put('calendarFeeds', feed.id, feed);
  return feed;
};
const view = (feed, appOrigin) => ({ url: calendarFeedUrl(appOrigin, feed.token), createdAt: feed.createdAt });

/** The caller's feed link; the first call creates it. */
export function calendarFeedLink(theater, uid, appOrigin) {
  calendarFeedUrl(appOrigin, 'x'.repeat(32));
  return theater.store.transaction(() => {
    const a = theater.account(uid), current = feedOf(theater.store, uid);
    // A link from an earlier person link of this login is not reused.
    if (current && current.personId === a.personId) return view(current, appOrigin);
    if (current) theater.store.delete('calendarFeeds', current.id);
    return view(create(theater, a), appOrigin);
  });
}

/** Replaces the caller's link; the previous one stops working immediately. */
export function resetCalendarFeed(theater, uid, appOrigin) {
  calendarFeedUrl(appOrigin, 'x'.repeat(32));
  return theater.store.transaction(() => {
    const a = theater.account(uid);
    for (const f of theater.store.all('calendarFeeds').filter(f => f.uid === uid)) theater.store.delete('calendarFeeds', f.id);
    const feed = create(theater, a);
    theater.store.audit(uid, 'calendarFeed.reset', uid);
    return view(feed, appOrigin);
  });
}

/** The approved account behind a token, or null for unknown tokens and blocked, deleted or relinked accounts. */
export function calendarFeedAccount(theater, token) {
  if (typeof token !== 'string' || !tokenPattern.test(token)) return null;
  const feed = theater.store.get('calendarFeeds', hash(token));
  if (!feed || feed.token !== token) return null;
  try {
    const a = theater.account(feed.uid);
    return a.personId === feed.personId ? a : null;
  } catch (e) {
    if (e instanceof AppError) return null;
    throw e;
  }
}

/**
 * Events in the feed of person `personId`: invited (as the app's `addressedToMe`), not declined, and
 * ending at most `pastDays` ago. Without an own answer, an absence covering the day counts as a
 * decline too; an explicit yes despite an absence wins.
 */
export function calendarFeedEvents(theater, personId) {
  const s = theater.store, member = s.get('members', personId), since = +theater.clock() - calendarFeedLimits.pastDays * 86400000;
  const absences = s.all('absences').filter(x => x.personId === personId);
  return s.all('events').filter(e => {
    if (!inAudience(member, e, s) || !(Date.parse(e.endsAt) >= since)) return false;
    const status = s.get('responses', `${e.id}:${personId}`)?.status;
    if (status === 'no') return false;
    if (['yes', 'late'].includes(status)) return true;
    const d = day(e.startsAt);
    return !absences.some(x => x.from <= d && x.to >= d);
  }).sort((x, y) => x.startsAt.localeCompare(y.startsAt) || x.id.localeCompare(y.id));
}

// --- iCalendar (RFC 5545) ---

/** TEXT value: backslash, semicolon, comma and line breaks escaped; other control characters dropped. */
export const icsText = value => String(value ?? '').replace(/\r\n?/g, '\n').replace(/[\u0000-\u0008\u000b-\u001f\u007f]/g, '')
  .replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\n/g, '\\n');
/** UTC date-time, e.g. 20261025T170000Z. */
export const icsTime = value => new Date(value).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}/, '');
/** Folds a content line after 75 octets without splitting a UTF-8 character; continuation lines start with a space. */
export function icsFold(line) {
  let out = '', octets = 0;
  for (const char of line) {
    const size = Buffer.byteLength(char);
    if (octets + size > 75) { out += '\r\n '; octets = 1; }
    out += char; octets += size;
  }
  return out;
}
/** UID of an event, the same in the feed and in the app's single event export. */
export const icsUid = eventId => `${eventId}@${calendarUidDomain}`;
/** SEQUENCE from the event version: the first version is revision 0. */
export const icsSequence = version => Math.max(0, (Number.isInteger(version) ? version : 1) - 1);

const eventLink = (appOrigin, eventId) => {
  try {
    const link = new URL('/', appOrigin);
    link.searchParams.set('target', `theaterapp://app/events/${encodeURIComponent(eventId)}`);
    return link.href;
  } catch { return null; }
};

/**
 * The feed of person `personId` as content lines (unfolded). `stamp` is the DTSTAMP of events
 * without a recorded change time.
 */
export function calendarFeedLines(theater, personId, { appOrigin = null, stamp = new Date(+theater.clock()) } = {}) {
  const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Kolpingtheater Ramsen//Theater-App//DE', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
    `X-WR-CALNAME:${icsText(calendarName)}`, `X-WR-CALDESC:${icsText('Deine Termine aus der Theater-App')}`, 'X-WR-TIMEZONE:Europe/Berlin',
    `REFRESH-INTERVAL;VALUE=DURATION:${calendarRefresh}`, `X-PUBLISHED-TTL:${calendarRefresh}`];
  for (const e of calendarFeedEvents(theater, personId)) {
    const production = e.productionId ? theater.store.get('productions', e.productionId) : null;
    const productionTitle = production?.title?.trim() ?? '';
    const summary = productionTitle && !e.title.toLowerCase().includes(productionTitle.toLowerCase()) ? `${e.title} · ${productionTitle}` : e.title;
    const link = appOrigin ? eventLink(appOrigin, e.id) : null;
    const description = [e.description?.trim(), link ? `In der Theater-App öffnen: ${link}` : ''].filter(Boolean).join('\n\n');
    lines.push('BEGIN:VEVENT', `UID:${icsText(icsUid(e.id))}`, `SEQUENCE:${icsSequence(e.version)}`, `DTSTAMP:${icsTime(e.updatedAt ?? stamp)}`,
      ...(e.updatedAt ? [`LAST-MODIFIED:${icsTime(e.updatedAt)}`] : []),
      `DTSTART:${icsTime(e.startsAt)}`, `DTEND:${icsTime(e.endsAt)}`, `SUMMARY:${icsText(summary)}`,
      ...(e.place?.trim() ? [`LOCATION:${icsText(e.place.trim())}`] : []),
      ...(description ? [`DESCRIPTION:${icsText(description)}`] : []),
      ...(link ? [`URL:${link}`] : []),
      'STATUS:CONFIRMED', 'TRANSP:OPAQUE', 'END:VEVENT');
  }
  lines.push('END:VCALENDAR');
  return lines;
}

/**
 * The feed behind `token`, or null (unknown token or no access). The ETag ignores DTSTAMP values
 * that only reflect the time of the request.
 */
export function calendarFeed(theater, token, { appOrigin = null } = {}) {
  const a = calendarFeedAccount(theater, token);
  if (!a) return null;
  const lines = calendarFeedLines(theater, a.personId, { appOrigin });
  const etag = `"${createHash('sha256').update(lines.filter(l => !l.startsWith('DTSTAMP:')).join('\n')).digest('base64url').slice(0, 27)}"`;
  return { body: `${lines.map(icsFold).join('\r\n')}\r\n`, etag };
}

/**
 * Moderate limits for the public route: requests per valid token, and unknown tokens per client
 * address. Valid links are never blocked by misses from the same address (shared fetchers like
 * Google's). Client addresses are only kept hashed, in memory.
 */
export class CalendarFeedLimiter {
  constructor({ clock = () => Date.now() } = {}) { this.clock = clock; this.hits = new Map(); this.salt = randomBytes(16); }
  /** Counts one request for `key`; returns the seconds to wait when `max` is exceeded, else 0. */
  take(key, max) {
    const at = this.clock(), since = at - calendarFeedLimits.windowMs;
    if (this.hits.size >= calendarFeedLimits.maxTracked) {
      for (const [k, times] of this.hits) if (!times.some(t => t > since)) this.hits.delete(k);
      while (this.hits.size >= calendarFeedLimits.maxTracked) this.hits.delete(this.hits.keys().next().value);
    }
    const recent = (this.hits.get(key) ?? []).filter(t => t > since);
    if (recent.length >= max) return Math.max(1, Math.ceil((recent[0] + calendarFeedLimits.windowMs - at) / 1000));
    this.hits.delete(key); this.hits.set(key, [...recent, at]);
    return 0;
  }
  token(token) { return this.take(`t:${hash(token)}`, calendarFeedLimits.tokenRequests); }
  miss(client) { return this.take(`c:${createHash('sha256').update(this.salt).update(String(client)).digest('base64url').slice(0, 22)}`, calendarFeedLimits.clientMisses); }
}
