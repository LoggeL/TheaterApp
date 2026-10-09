import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { setTimeout as pause } from 'node:timers/promises';
import { eventNotificationBody } from './event-notification.mjs';
import { inAudience } from './theater.mjs';

const escapeHtml = value => String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const maxAgeMs = 23 * 3600000; // Resend retains idempotency keys for 24 hours.

export class ResendEmail {
  constructor({ apiKey = '', from = '', replyTo = '', fetchImpl = fetch } = {}) {
    this.apiKey = apiKey; this.from = from; this.replyTo = replyTo; this.fetch = fetchImpl;
    this.configured = !!apiKey && !!from && !/[\r\n]/.test(from + replyTo);
  }
  async send({ to, subject, text, html, idempotencyKey }) {
    if (!this.configured) throw Object.assign(new Error('Email is not configured'), { code: 'email_unavailable', retryable: false });
    const delay = (this.nextSendAt ?? 0) - Date.now();
    if (delay > 0) await pause(delay);
    this.nextSendAt = Date.now() + 600;
    const response = await this.fetch('https://api.resend.com/emails', {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(15000),
      headers: { Authorization: `Bearer ${this.apiKey}`, 'Content-Type': 'application/json', 'Idempotency-Key': idempotencyKey },
      body: JSON.stringify({ from: this.from, to: [to], subject, text, html, ...(this.replyTo ? { reply_to: this.replyTo } : {}) }),
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok || !data.id) throw Object.assign(new Error('Email provider rejected the message'), { code: `resend_${response.status}`, retryable: response.ok || response.status === 429 || response.status >= 500 });
    return data.id;
  }
}

export function emailFromEnvironment(env = process.env) {
  const apiKey = env.RESEND_API_KEY_FILE ? readFileSync(env.RESEND_API_KEY_FILE, 'utf8').trim() : env.RESEND_API_KEY ?? '';
  return new ResendEmail({ apiKey, from: env.EMAIL_FROM ?? '', replyTo: env.EMAIL_REPLY_TO ?? '' });
}

export function eventEmail(job, event, appOrigin) {
  const link = new URL('/', appOrigin);
  if (link.protocol !== 'https:' || link.username || link.password) throw new Error('HTTPS app origin required');
  const subject = (job.test ? 'Theater-App: Test-E-Mail' : `${job.cancelled ? 'Termin abgesagt' : job.newEvent ? 'Neuer Termin' : job.change ? 'Termin aktualisiert' : 'Erinnerung'}: ${event.title}`).replace(/[\r\n]/g, ' ').slice(0, 200);
  if (event) link.searchParams.set('target', `theaterapp://app/events/${encodeURIComponent(event.id)}`);
  const body = job.test ? 'Deine Test-E-Mail ist da.' : eventNotificationBody(event);
  const footer = 'Termin-E-Mails kannst du in der App unter Darstellung & Erinnerungen ausschalten.';
  return { subject, text: `${subject}\n\n${body}\n\nTheater-App öffnen: ${link.href}\n\n${footer}`,
    html: `<!doctype html><html lang="de"><body><h1>${escapeHtml(subject)}</h1><p>${escapeHtml(body)}</p><p><a href="${escapeHtml(link.href)}">Theater-App öffnen</a></p><p>${escapeHtml(footer)}</p></body></html>` };
}

function eligibleRecipient(s, a, job, event) {
  return a?.status === 'approved' && a.personId && a.emailVerified === true && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(a.email ?? '') && !/\.(?:test|invalid)$/i.test(a.email) && s.get('members', a.personId)?.active
    && (!job.recipientPersonIds || job.recipientPersonIds.includes(a.personId))
    && (job.test || (event && s.get('reminders', a.personId)?.emailEnabled === true && inAudience(s.get('members', a.personId), job, s) && inAudience(s.get('members', a.personId), event, s)
      && ((!job.change && !job.cancelled) || (s.get('reminders', a.personId)?.changes ?? true))
      && (job.change || job.newEvent || job.cancelled || s.get('responses', `${event.id}:${a.personId}`)?.status !== 'no')));
}

/** Every recipient is rechecked before sending. Accepted recipients are never retried. */
export async function deliverEmail(theater, email, appOrigin, now = new Date()) {
  if (!theater.emailEnabled || !email?.configured) return;
  const s = theater.store, at = +now;
  let sent = 0;
  for (const job of s.all('emailJobs').filter(j => j.status === 'pending' && Date.parse(j.nextAttemptAt) <= at).sort((a, b) => a.createdAt.localeCompare(b.createdAt)).slice(0, 20)) {
    if (at - Date.parse(job.createdAt) >= maxAgeMs) { s.put('emailJobs', job.id, { ...job, status: 'expired', finishedAt: now.toISOString() }); continue; }
    const event = job.cancelled ? job.event : s.get('events', job.data?.eventId);
    if (!job.test && (!event || Date.parse(event.endsAt ?? event.startsAt) <= at)) { s.put('emailJobs', job.id, { ...job, status: 'obsolete', finishedAt: now.toISOString() }); continue; }
    if (!job.cancelled && job.eventVersion !== undefined && event?.version !== job.eventVersion) { s.put('emailJobs', job.id, { ...job, status: 'obsolete', finishedAt: now.toISOString() }); continue; }
    const accounts = s.accounts().filter(a => eligibleRecipient(s, a, job, event));
    const accepted = new Set(job.acceptedRecipientIds ?? []), permanent = new Set(job.failedRecipientIds ?? []);
    let retry = false, deferred = false;
    for (const a of accounts) {
      const current = s.account(a.uid), currentEvent = job.cancelled ? job.event : s.get('events', job.data?.eventId);
      if (!eligibleRecipient(s, current, job, currentEvent)) continue;
      const recipient = createHash('sha256').update(current.uid + ':' + current.email.toLowerCase()).digest('hex');
      if (accepted.has(recipient) || permanent.has(recipient)) continue;
      if (sent >= 20) { deferred = true; break; }
      sent++;
      try {
        if (!job.payload) { job.payload = eventEmail(job, currentEvent, appOrigin); s.put('emailJobs', job.id, job); }
        await email.send({ to: current.email, ...job.payload, idempotencyKey: `theater-event-${job.id}-${recipient}` });
        accepted.add(recipient);
      } catch (error) {
        job.lastError = error.code ?? 'email_unavailable';
        if (error.retryable === false) permanent.add(recipient); else retry = true;
      }
      s.put('emailJobs', job.id, { ...job, acceptedRecipientIds: [...accepted], failedRecipientIds: [...permanent] });
    }
    const attempts = (job.attempts ?? 0) + (retry ? 1 : 0);
    const pending = deferred || retry && attempts < 6;
    s.put('emailJobs', job.id, { ...job, acceptedRecipientIds: [...accepted], failedRecipientIds: [...permanent], accepted: accepted.size, failed: permanent.size, attempts,
      status: pending ? 'pending' : retry || permanent.size ? 'failed' : accepted.size ? 'accepted_by_provider' : 'no_recipients', nextAttemptAt: new Date(at + 60000 * 2 ** Math.min(attempts - 1, 5)).toISOString(), finishedAt: pending ? null : now.toISOString() });
    if (sent >= 20) break;
  }
}
