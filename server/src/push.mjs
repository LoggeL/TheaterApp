import { customReminderMinutes, defaultReminders, eventNotificationBody } from './event-notification.mjs';
import { pushWanted } from './push-kinds.mjs';
import { implicitYes, inAudience, plannedReminderLeadMs, plannedReminderMinLeadMs } from './theater.mjs';

export { plannedReminderLeadMs, plannedReminderMinLeadMs };

const hourMs = 3600000;
const attendanceText = new Map([
  ['yes', 'Du hast zugesagt.'],
  ['late', 'Du kommst später.'],
]);
const implicitText = 'Du bist eingeplant. Kannst du nicht? Bitte absagen.';
const declineCutoffMs = hourMs;

/** Only the reminder slot closest to the start is due; a personal slot wins over an equal fixed one. */
function dueReminder(preferences, until) {
  const custom = Number.isInteger(preferences.customMinutes) ? [{ kind: `custom-${preferences.customMinutes}`, lead: preferences.customMinutes * 60000, enabled: true }] : [];
  const slots = [...custom, { kind: 'twoHours', lead: 2 * hourMs, enabled: preferences.twoHours === true }, { kind: 'dayBefore', lead: 24 * hourMs, enabled: preferences.dayBefore === true }].sort((x, y) => x.lead - y.lead);
  const slot = slots.find(x => until <= x.lead);
  return slot?.enabled ? slot.kind : null;
}

export function scheduleReminders(theater, now = new Date()) {
  if (!theater.pushEnabled && !theater.emailEnabled) return;
  const s = theater.store, absences = s.all('absences');
  for (const event of s.all('events')) {
    const until = Date.parse(event.startsAt) - +now;
    if (until <= 0 || until > customReminderMinutes.max * 60000) continue;
    for (const a of s.accounts().filter(x => x.status === 'approved' && x.personId && inAudience(s.get('members', x.personId), event, s))) {
      const preferences = { ...defaultReminders, ...s.get('reminders', a.personId) };
      const kind = dueReminder(preferences, until);
      const status = s.get('responses', `${event.id}:${a.personId}`)?.status ?? null;
      // Auto-accepted events: whoever has not declined attends (see implicitYes).
      const implicit = implicitYes(s, event, s.get('members', a.personId), status, absences);
      // "Du bist eingeplant" once per start time, two days ahead (or at once for events created or moved
      // closer), with the decline. An ordinary reminder due in the same tick is not sent on top.
      if (implicit && !event.locked && until <= plannedReminderLeadMs && until > plannedReminderMinLeadMs && pushWanted(preferences, { pushKind: 'eventPlanned' })) {
        const plannedKey = `${event.id}:${event.startsAt}:${a.personId}:planned`;
        if (!s.get('reminderSent', plannedKey)) s.transaction(() => {
          theater.enqueuePush({ title: `Du bist eingeplant: ${event.title}`, body: eventNotificationBody(event), data: { eventId: event.id, intent: 'decline' }, recipientPersonIds: [a.personId], planned: true, pushKind: 'eventPlanned' });
          s.put('reminderSent', plannedKey, { at: now.toISOString() });
          if (kind) s.put('reminderSent', `${event.id}:${event.startsAt}:${a.personId}:${kind}`, { at: now.toISOString() });
        });
      }
      if (!kind || status === 'no') continue;
      const attending = ['yes', 'late'].includes(status) || implicit;
      const key = `${event.id}:${event.startsAt}:${a.personId}:${kind}`;
      if (s.get('reminderSent', key)) continue;
      // Open invitations can still receive opted-in email reminders. Keep their
      // marker separate so a later acceptance can receive its first push.
      const emailKey = `${key}-email`;
      if (!attending && (!theater.emailEnabled || !preferences.emailEnabled || s.get('reminderSent', emailKey))) continue;
      s.transaction(() => {
        const notice = { title: event.title, body: eventNotificationBody(event), data: { eventId: event.id }, recipientPersonIds: [a.personId] };
        if (attending) theater.enqueuePush({ ...notice, ...(s.get('reminderSent', emailKey) ? { email: false } : {}) });
        else theater.enqueueEmail(notice);
        s.put('reminderSent', attending ? key : emailKey, { at: now.toISOString() });
      });
    }
  }
}

// Changes only reach people who plan to attend the event, and only for events
// within the next two weeks (`soon`); open invitations stay quiet.
// A reminder for open invitations (`remindOpen`) skips everyone who answered meanwhile;
// poll and slot reminders (`remindPoll`, `remindSlot`) skip who voted or booked meanwhile.
// On auto-accepted events, people without an own answer attend implicitly and count as accepted here.
const answered = (s, job, personId) => ['yes', 'late', 'no'].includes(s.get('responses', `${job.data?.eventId}:${personId}`)?.status);
const attendsImplicitly = (s, job, personId) => implicitYes(s, s.get('events', job.data?.eventId), s.get('members', personId), s.get('responses', `${job.data?.eventId}:${personId}`)?.status ?? null);
function eventPushEligible(s, job, personId) {
  if (!job.data?.eventId || job.fixedText) return true;
  const status = s.get('responses', `${job.data.eventId}:${personId}`)?.status;
  if (status === 'no') return false;
  // "Du bist eingeplant" is void once the person answered (or an absence covers the day).
  if (job.planned && !attendsImplicitly(s, job, personId)) return false;
  // Announcements and explicit requests for an answer may reach open invitees.
  // Ordinary reminders (including previously queued jobs) require acceptance.
  return job.newEvent || job.announce === 'new' || job.remindOpen || ['yes', 'late'].includes(status) || attendsImplicitly(s, job, personId);
}

export async function deliverPush(theater, messaging, appOrigin = process.env.APP_ORIGIN) {
  if (!theater.pushEnabled || !messaging) return;
  const s = theater.store;
  for (const job of s.all('pushJobs').filter(j => j.status === 'pending' && Date.parse(j.nextAttemptAt) <= Date.now()).slice(0, 20)) {
    const accounts = s.accounts().filter(a => a.status === 'approved' && a.personId && s.get('members', a.personId)?.active && (!job.recipientPersonIds || job.recipientPersonIds.includes(a.personId)) && (!job.adminsOnly || a.role === 'admin') && inAudience(s.get('members', a.personId), job, s) && pushWanted(s.get('reminders', a.personId), job) && (!job.change || (job.soon !== false && (answered(s, job, a.personId) || attendsImplicitly(s, job, a.personId)))) && (!job.remindOpen || (!answered(s, job, a.personId) && !attendsImplicitly(s, job, a.personId)))
      && eventPushEligible(s, job, a.personId) && (!job.remindPoll || !s.get('pollVotes', `${job.data?.pollId}:${a.personId}`)) && (!job.remindSlot || !s.get('slotBookings', `${job.data?.slotPoolId}:${a.personId}`)));
    const uids = new Set(accounts.map(a => a.uid));
    const accountsByUid = new Map(accounts.map(a => [a.uid, a]));
    const devices = s.all('devices').filter(d => uids.has(d.uid));
    if (!devices.length) { s.put('pushJobs', job.id, { ...job, status: 'no_devices', finishedAt: new Date().toISOString() }); continue; }
    let accepted = 0, failed = 0;
    const already = new Set(job.acceptedDeviceIds ?? []);
    try {
      const pending = devices.filter(d => !already.has(d.id));
      // Keep the OS-rendered payload for older clients. Only upgraded Android
      // devices opt into data messages that their background handler displays.
      // Single-event notifications include the recipient's current response,
      // so even OS-rendered notifications must be grouped by account.
      const personalEvent = job.data?.eventId && !job.fixedText && !job.series;
      const groups = Map.groupBy(pending, d => d.platform === 'android' && d.notificationActions === true ? `actions:${d.uid}` : personalEvent ? `standard:${d.uid}` : 'standard');
      for (const [group, groupDevices] of groups) {
        for (let i = 0; i < groupDevices.length; i += 500) {
          const chunk = groupDevices.slice(i, i + 500).filter(d => eventPushEligible(s, job, accountsByUid.get(d.uid).personId));
          if (!chunk.length) continue;
          const custom = group.startsWith('actions:');
          // Fixed texts (e.g. late declines to the direction) keep their title and offer no quick answer.
          const event = job.data?.eventId && !job.fixedText ? s.get('events', job.data.eventId) : null;
          // A series push keeps its summary; the event is only its first occurrence.
          const title = event && !job.series ? (job.planned ? `Du bist eingeplant: ${event.title}` : job.remindOpen ? `Rückmeldung fehlt: ${event.title}` : job.announce ? `${job.announce === 'new' ? 'Neuer Termin' : 'Termin geändert'}: ${event.title}` : job.change ? `Termin aktualisiert: ${event.title}` : event.title) : job.title;
          const personId = accountsByUid.get(chunk[0].uid).personId;
          const response = event && !job.series ? s.get('responses', `${event.id}:${personId}`) : null;
          // An implicit attendee reads "Du bist eingeplant"; until an hour before the start the card offers
          // "Ok" (an explicit yes) and "Komme nicht".
          const implicit = !!event && !job.series && implicitYes(s, event, s.get('members', personId), response?.status ?? null);
          const responseText = attendanceText.get(response?.status) ?? (implicit ? implicitText : undefined);
          const body = event && !job.series ? `${eventNotificationBody(event)}${responseText ? `\n${responseText}` : ''}` : job.body;
          const canRespond = event && !job.series && !responseText && !event.locked && !event.slotPoolId && Date.parse(event.endsAt ?? event.startsAt) > Date.now();
          const planned = implicit && !event.locked && Date.parse(event.startsAt) - declineCutoffMs > Date.now();
          // Older apps compare against 'true' and show no buttons for 'planned'.
          const actions = canRespond ? 'true' : planned ? 'planned' : null;
          const target = job.data?.eventId ? ['events', job.data.eventId] : job.data?.messageId ? ['messages', job.data.messageId] : job.data?.pollId ? ['polls', job.data.pollId] : job.data?.productionId ? ['productions', job.data.productionId] : job.data?.accountUid ? ['accounts', job.data.accountUid] : job.data?.slotPoolId ? ['slots', job.data.slotPoolId] : job.data?.feedbackId ? ['feedback', job.data.feedbackId] : job.data?.adminFeedbackId ? ['admin-feedback', job.data.adminFeedbackId] : null;
          const link = appOrigin ? new URL('/', appOrigin) : null;
          // Older apps ignore the query and just open the event; `checkin` opens its attendance check-in.
          if (link && target) link.searchParams.set('target', `theaterapp://app/${target[0]}/${encodeURIComponent(target[1])}${target[0] === 'events' && ['decline', 'checkin'].includes(job.data?.intent) ? `?intent=${job.data.intent}` : ''}`);
          const result = await messaging.sendEachForMulticast({ tokens: chunk.map(d => d.token), ...(custom ? { data: { ...job.data, title, body, notificationId: job.id, recipientUid: chunk[0].uid, ...(actions ? { attendanceActions: actions } : {}) } } : { notification: { title, body }, data: job.data ?? {} }), ...(link?.protocol === 'https:' ? { webpush: { fcmOptions: { link: link.href } } } : {}), android: { priority: 'high', ...(custom ? {} : { notification: { channelId: 'theater_updates' } }) }, apns: { payload: { aps: { sound: 'default' } } } });
          result.responses.forEach((r, index) => {
            if (r.success) { accepted++; already.add(chunk[index].id); }
            else if (['messaging/registration-token-not-registered', 'messaging/invalid-registration-token'].includes(r.error?.code)) { s.delete('devices', chunk[index].id); already.add(chunk[index].id); }
            else failed++;
          });
          s.put('pushJobs', job.id, { ...job, acceptedDeviceIds: [...already] });
        }
      }
      s.put('pushJobs', job.id, { ...job, acceptedDeviceIds: [...already], accepted: (job.accepted ?? 0) + accepted, failed, attempts: job.attempts + 1, status: failed === 0 ? 'accepted_by_provider' : job.attempts >= 4 ? 'failed' : 'pending', nextAttemptAt: new Date(Date.now() + 60000 * 2 ** job.attempts).toISOString(), finishedAt: failed ? null : new Date().toISOString() });
    } catch (error) {
      s.put('pushJobs', job.id, { ...job, acceptedDeviceIds: [...already], attempts: job.attempts + 1, status: job.attempts >= 4 ? 'failed' : 'pending', lastError: error.code ?? 'push_unavailable', nextAttemptAt: new Date(Date.now() + 60000 * 2 ** job.attempts).toISOString() });
    }
  }
}
