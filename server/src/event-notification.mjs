const dateFormat = new Intl.DateTimeFormat('de-DE', {
  timeZone: 'Europe/Berlin', weekday: 'short', day: '2-digit', month: '2-digit', year: 'numeric',
});
const timeFormat = new Intl.DateTimeFormat('de-DE', {
  timeZone: 'Europe/Berlin', hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
});

export const defaultReminders = Object.freeze({ dayBefore: false, twoHours: true, changes: true });

export function eventNotificationBody(event) {
  const start = new Date(event.startsAt);
  if (!Number.isFinite(+start)) return event.title;
  return `${dateFormat.format(start)}, ${timeFormat.format(start)} Uhr${event.place ? ` · ${event.place}` : ''}`;
}
