import { leadPushKinds, memberPushKinds } from './push-kinds.mjs';

const dateFormat = new Intl.DateTimeFormat('de-DE', {
  timeZone: 'Europe/Berlin', weekday: 'short', day: '2-digit', month: '2-digit', year: 'numeric',
});
const timeFormat = new Intl.DateTimeFormat('de-DE', {
  timeZone: 'Europe/Berlin', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
});

// Every switchable push kind (see push-kinds.mjs) is on unless switched off.
export const defaultReminders = Object.freeze({ dayBefore: false, twoHours: true, changes: true, emailEnabled: false, customMinutes: null, ...Object.fromEntries([...memberPushKinds, ...leadPushKinds].map(kind => [kind, true])) });
// A personal reminder lead time from 15 minutes to one week.
export const customReminderMinutes = Object.freeze({ min: 15, max: 7 * 24 * 60 });

/** Europe/Berlin date and time, e.g. "Mo., 14.09.2026, 19:00 Uhr". */
export function berlinDateTime(ts) {
  const at = new Date(ts);
  return Number.isFinite(+at) ? `${dateFormat.format(at)}, ${timeFormat.format(at)} Uhr` : '';
}

export function eventNotificationBody(event) {
  const start = new Date(event.startsAt);
  if (!Number.isFinite(+start)) return event.title;
  return `${berlinDateTime(start)}${event.place ? ` · ${event.place}` : ''}`;
}

/**
 * Whether a job about one event is void because of its cancellation (`event.cancel`): every job
 * of a cancelled event except its own cancellation notice, and that notice once the cancellation
 * was withdrawn (or renewed). Series notices only name their first occurrence and stay.
 */
export function voidedByCancellation(s, job) {
  const event = job.data?.eventId && !job.series ? s.get('events', job.data.eventId) : null;
  if (!event) return false;
  return job.cancelledAt ? event.cancelledAt !== job.cancelledAt : !!event.cancelledAt;
}
