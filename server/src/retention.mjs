import { unlink } from 'node:fs/promises';
import { resolve } from 'node:path';

const dayMs = 24 * 3600000;
// Deletion periods promised in the privacy notice (web/privacy.html#speicherdauer).
export const retention = Object.freeze({
  requestDays: 14,
  pushJobDays: 30,
  reasonDays: 28,
  absenceDays: 28,
  orphanProfileImageDays: 1,
  rejectedAccountDays: 180,
});

const day = value => new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Berlin' }).format(new Date(value));

/** Deletes data that is no longer needed. `deleteIdentity` removes the Firebase login of a rejected account. */
export async function purgeExpired(theater, { now = new Date(), mediaDirectory = null, deleteIdentity = null } = {}) {
  const s = theater.store, at = +now, before = days => new Date(at - days * dayMs).toISOString();
  const counts = { requests: 0, pushJobs: 0, reminderSent: 0, reasons: 0, absences: 0, profileImages: 0, rejectedAccounts: 0 };
  s.transaction(() => {
    // Stored idempotency results can contain decline reasons.
    counts.requests = Number(s.db.prepare('DELETE FROM requests WHERE created_at < ?').run(before(retention.requestDays)).changes);
    for (const job of s.all('pushJobs').filter(j => j.createdAt < before(retention.pushJobDays))) { s.delete('pushJobs', job.id); counts.pushJobs++; }
    s.db.prepare("DELETE FROM entities WHERE kind = 'reminderSent' AND json_extract(data, '$.at') < ?").run(before(retention.pushJobDays));
    const events = new Map(s.all('events').map(e => [e.id, e]));
    for (const r of s.all('responses')) {
      const e = events.get(r.eventId);
      if (r.reason && e && Date.parse(e.endsAt) < at - retention.reasonDays * dayMs) { s.put('responses', `${r.eventId}:${r.personId}`, { ...r, reason: '' }); counts.reasons++; }
    }
    const lastAbsenceDay = day(at - retention.absenceDays * dayMs);
    for (const x of s.all('absences').filter(x => x.to < lastAbsenceDay)) { s.delete('absences', x.id); counts.absences++; }
  });
  if (mediaDirectory) {
    const avatars = new Set(s.all('members').map(m => m.avatarId).filter(Boolean));
    for (const m of s.all('media').filter(m => m.kind === 'profile' && !avatars.has(m.id) && m.createdAt < before(retention.orphanProfileImageDays))) {
      await unlink(resolve(mediaDirectory, `${m.id}.webp`)).catch(e => { if (e.code !== 'ENOENT') throw e; });
      s.delete('media', m.id); counts.profileImages++;
    }
  }
  for (const a of s.accounts().filter(a => a.status === 'rejected' && (a.statusChangedAt ?? a.lastSeenAt ?? a.createdAt) < before(retention.rejectedAccountDays))) {
    // Remove the login first so a failure leaves the account for the next run.
    if (deleteIdentity) await deleteIdentity(a.uid);
    s.transaction(() => {
      if (s.account(a.uid)?.status !== 'rejected') return;
      theater.forgetAccount(a.uid, 'retention');
      counts.rejectedAccounts++;
    });
  }
  return counts;
}
