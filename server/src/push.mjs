import { defaultReminders, eventNotificationBody } from './event-notification.mjs';

export function scheduleReminders(theater, now = new Date()) {
  if (!theater.pushEnabled) return;
  const s = theater.store;
  for (const event of s.all('events')) {
    const until = Date.parse(event.startsAt) - +now;
    if (until <= 0 || until > 24 * 3600000) continue;
    const kind = until <= 2 * 3600000 ? 'twoHours' : 'dayBefore';
    for (const a of s.accounts().filter(x => x.status === 'approved' && x.personId)) {
      const preferences = { ...defaultReminders, ...s.get('reminders', a.personId) };
      if (preferences[kind] !== true || s.get('responses', `${event.id}:${a.personId}`)?.status === 'no') continue;
      const key = `${event.id}:${event.startsAt}:${a.personId}:${kind}`;
      if (s.get('reminderSent', key)) continue;
      s.transaction(() => {
        theater.enqueuePush({ title: event.title, body: eventNotificationBody(event), data: { eventId: event.id }, recipientPersonIds: [a.personId] });
        s.put('reminderSent', key, { at: now.toISOString() });
      });
    }
  }
}

export async function deliverPush(theater, messaging, appOrigin = process.env.APP_ORIGIN) {
  if (!theater.pushEnabled || !messaging) return;
  const s = theater.store;
  for (const job of s.all('pushJobs').filter(j => j.status === 'pending' && Date.parse(j.nextAttemptAt) <= Date.now()).slice(0, 20)) {
    const accounts = s.accounts().filter(a => a.status === 'approved' && a.personId && s.get('members', a.personId)?.active && (!job.recipientPersonIds || job.recipientPersonIds.includes(a.personId)) && (!job.change || (s.get('reminders', a.personId)?.changes ?? true)));
    const uids = new Set(accounts.map(a => a.uid));
    const devices = s.all('devices').filter(d => uids.has(d.uid));
    if (!devices.length) { s.put('pushJobs', job.id, { ...job, status: 'no_devices', finishedAt: new Date().toISOString() }); continue; }
    let accepted = 0, failed = 0;
    const already = new Set(job.acceptedDeviceIds ?? []);
    try {
      const pending = devices.filter(d => !already.has(d.id));
      // Keep the OS-rendered payload for older clients. Only upgraded Android
      // devices opt into data messages that their background handler displays.
      const groups = Map.groupBy(pending, d => d.platform === 'android' && d.notificationActions === true ? `actions:${d.uid}` : 'standard');
      for (const [group, groupDevices] of groups) {
        for (let i = 0; i < groupDevices.length; i += 500) {
          const chunk = groupDevices.slice(i, i + 500);
          const custom = group !== 'standard';
          const event = job.data?.eventId ? s.get('events', job.data.eventId) : null;
          const title = event ? (job.change ? `Termin aktualisiert: ${event.title}` : event.title) : job.title;
          const body = event ? eventNotificationBody(event) : job.body;
          const canRespond = event && !event.locked && Date.parse(event.endsAt ?? event.startsAt) > Date.now();
          const target = job.data?.eventId ? ['events', job.data.eventId] : job.data?.messageId ? ['messages', job.data.messageId] : job.data?.productionId ? ['productions', job.data.productionId] : null;
          const link = appOrigin ? new URL('/', appOrigin) : null;
          if (link && target) link.searchParams.set('target', `theaterapp://app/${target[0]}/${encodeURIComponent(target[1])}`);
          const result = await messaging.sendEachForMulticast({ tokens: chunk.map(d => d.token), ...(custom ? { data: { ...job.data, title, body, notificationId: job.id, recipientUid: chunk[0].uid, ...(canRespond ? { attendanceActions: 'true' } : {}) } } : { notification: { title, body }, data: job.data ?? {} }), ...(link?.protocol === 'https:' ? { webpush: { fcmOptions: { link: link.href } } } : {}), android: { priority: 'high', ...(custom ? {} : { notification: { channelId: 'theater_updates' } }) }, apns: { payload: { aps: { sound: 'default' } } } });
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
