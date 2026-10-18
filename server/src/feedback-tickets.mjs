import { randomUUID } from 'node:crypto';
import { AppError } from './theater.mjs';

// Member feedback as simple support tickets: every feedback carries a conversation between its
// author and the admins. Records keep the kind `feedback`; `message` stays the first text so that
// older admin clients still show it.
//
// Status:
//   open      waiting for the admins (new, or the author wrote last)
//   answered  an admin wrote last, waiting for the author
//   closed    done; only possible after at least one admin answer
// Author and admins may close. A new message from the author reopens the same ticket, so the
// context stays together; an admin answer on a closed ticket reopens it as `answered`.

export const feedbackMaxLength = 4000, feedbackPerHour = 10;
// Follow-up messages by the author, per account and hour, across all their tickets.
export const feedbackRepliesPerHour = 30;
// Upper bound for one conversation; afterwards a new feedback is the better place.
export const feedbackMaxMessages = 100;
export const feedbackTicketsMigrationId = 'feedback-tickets-v1';
export const feedbackCategories = ['idea', 'bug', 'other'];
export const feedbackTicketStatuses = ['open', 'answered', 'closed'];

const fail = (status, message, code) => { throw new AppError(status, message, code); };
const list = value => Array.isArray(value) ? value : [];
const excerpt = (value, max = 120) => { const short = value.replace(/\s+/g, ' '); return short.length > max ? `${short.slice(0, max - 1).trimEnd()}…` : short; };
const firstMessage = f => ({ id: `${f.id}-0`, from: 'member', text: f.message, at: f.createdAt, byUid: f.authorUid ?? null, byPersonId: f.authorPersonId ?? null, byName: f.authorName ?? '' });
// Records written before the tickets carry no conversation yet.
const messagesOf = f => Array.isArray(f.messages) ? f.messages : [firstMessage(f)];
const answered = f => messagesOf(f).some(m => m.from === 'admin');
const lastActivity = f => f.lastActivityAt ?? messagesOf(f).at(-1)?.at ?? f.createdAt;
// Admin messages the author has not opened yet: `authorSeen` counts the messages they have seen.
const unreadFor = f => messagesOf(f).slice(f.authorSeen ?? 1).filter(m => m.from === 'admin').length;
const byActivity = (x, y) => lastActivity(y).localeCompare(lastActivity(x)) || y.createdAt.localeCompare(x.createdAt);
const memberName = (theater, personId, fallback) => (personId != null && theater.store.get('members', personId)?.name) || fallback || '';

/**
 * One-off move of existing feedback to tickets: the text becomes the first message. Feedback the
 * admins had already marked `done` becomes `closed` right away (closed by the admins at its last
 * change), the only case of a closed ticket without an admin answer. Everything else starts as
 * `open`. The old status stays in `legacyStatus`. Safe to run again.
 */
export function migrateFeedbackTickets(store, at = new Date().toISOString()) {
  const done = store.get('migrations', feedbackTicketsMigrationId);
  if (done) return { ...done.report, alreadyApplied: true };
  const report = { converted: 0, closed: 0 };
  for (const f of store.all('feedback')) {
    if (Array.isArray(f.messages)) continue;
    const { status, ...rest } = f;
    const closed = status === 'done' ? { status: 'closed', closedAt: f.updatedAt ?? f.createdAt, closedBy: { role: 'admin', uid: null, personId: null, name: '' } } : { status: 'open' };
    store.put('feedback', f.id, { ...rest, ...closed, ...(status && status !== 'new' ? { legacyStatus: status } : {}), messages: [firstMessage(f)], lastActivityAt: f.createdAt, version: (f.version ?? 1) + 1 });
    report.converted++;
    if (closed.status === 'closed') report.closed++;
  }
  store.put('migrations', feedbackTicketsMigrationId, { report, appliedAt: at });
  return report;
}

/** Removes a deleted login from all tickets; the person stays linked. */
export function forgetFeedbackAccount(store, uid) {
  for (const f of store.all('feedback')) {
    const messages = messagesOf(f), touched = f.authorUid === uid || messages.some(m => m.byUid === uid) || f.closedBy?.uid === uid;
    if (!touched) continue;
    store.put('feedback', f.id, { ...f, authorUid: f.authorUid === uid ? null : f.authorUid, ...(Array.isArray(f.messages) ? { messages: messages.map(m => m.byUid === uid ? { ...m, byUid: null } : m) } : {}), ...(f.closedBy?.uid === uid ? { closedBy: { ...f.closedBy, uid: null } } : {}) });
  }
}

/** Deletes the tickets of a deleted person; their answers in other tickets stay without name. */
export function forgetFeedbackPerson(store, personId) {
  for (const f of store.all('feedback')) {
    if (f.authorPersonId === personId) { store.delete('feedback', f.id); continue; }
    const mine = m => m.byPersonId === personId;
    if (!list(f.messages).some(mine) && f.closedBy?.personId !== personId) continue;
    store.put('feedback', f.id, { ...f, messages: list(f.messages).map(m => mine(m) ? { ...m, byPersonId: null, byUid: null, byName: '' } : m), ...(f.closedBy?.personId === personId ? { closedBy: { ...f.closedBy, personId: null, uid: null, name: '' } } : {}) });
  }
}

const isOwner = (a, f) => (a.personId != null && f.authorPersonId === a.personId) || (f.authorUid != null && f.authorUid === a.uid);

/** The ticket as its author or the admins see it; current names win over the saved ones. */
export function ticketView(theater, f, { admin = false } = {}) {
  const messages = messagesOf(f).map(m => ({ id: m.id, from: m.from, text: m.text, at: m.at, author: { personId: m.byPersonId ?? null, name: m.from === 'member' ? memberName(theater, f.authorPersonId, f.authorName) : memberName(theater, m.byPersonId, m.byName) } }));
  const closedBy = f.closedBy ? { role: f.closedBy.role, name: f.closedBy.role === 'member' ? memberName(theater, f.authorPersonId, f.authorName) : memberName(theater, f.closedBy.personId, f.closedBy.name) } : null;
  const view = { id: f.id, message: f.message, category: f.category, status: feedbackTicketStatuses.includes(f.status) ? f.status : 'open', createdAt: f.createdAt, updatedAt: f.updatedAt, version: f.version, appVersion: f.appVersion ?? null, platform: f.platform ?? null, messages, answered: answered(f), lastActivityAt: lastActivity(f), closedAt: f.closedAt ?? null, closedBy };
  if (admin) return { ...view, author: { uid: f.authorUid ?? null, personId: f.authorPersonId ?? null, name: memberName(theater, f.authorPersonId, f.authorName) } };
  return { ...view, unread: unreadFor(f) };
}

const messageText = b => {
  const value = typeof b?.text === 'string' ? b.text.trim() : typeof b?.message === 'string' ? b.message.trim() : '';
  if (!value) fail(400, 'Bitte eine Nachricht eingeben.');
  if (value.length > feedbackMaxLength) fail(400, `Die Nachricht darf höchstens ${feedbackMaxLength} Zeichen lang sein.`);
  return value;
};
const ticket = (theater, ticketId) => theater.store.get('feedback', ticketId) ?? fail(404, 'Feedback nicht gefunden.');
const ownTicket = (theater, a, ticketId) => {
  const f = theater.store.get('feedback', ticketId);
  // Someone else's ticket is reported as missing, so ids reveal nothing.
  if (!f || !isOwner(a, f)) fail(404, 'Feedback nicht gefunden.');
  return f;
};
const checkVersion = (f, version) => { if (f.version !== version) fail(409, 'Das Feedback wurde inzwischen geändert. Bitte neu laden.', 'version_conflict'); };
const tooLong = f => { if (messagesOf(f).length >= feedbackMaxMessages) fail(409, 'Dieser Verlauf ist sehr lang geworden. Bitte schick ein neues Feedback.', 'too_many_messages'); };

/** Stores member feedback as a new ticket and notifies the admins; at most `feedbackPerHour` per account. */
export function submitFeedback(theater, uid, b) {
  return theater.store.transaction(() => {
    const s = theater.store, a = theater.account(uid), message = typeof b.message === 'string' ? b.message.trim() : '';
    if (!message) fail(400, 'Bitte eine Nachricht eingeben.');
    if (message.length > feedbackMaxLength) fail(400, `Die Nachricht darf höchstens ${feedbackMaxLength} Zeichen lang sein.`);
    const category = b.category ?? 'other', platform = b.platform ?? null;
    if (!feedbackCategories.includes(category)) fail(400, 'Ungültige Kategorie.');
    if (platform !== null && !['android', 'ios', 'web'].includes(platform)) fail(400, 'Ungültige Plattform.');
    if (b.appVersion != null && (typeof b.appVersion !== 'string' || b.appVersion.trim().length > 40)) fail(400, 'Ungültige App-Version.');
    const at = theater.clock(), since = new Date(+at - 3600000).toISOString();
    if (s.all('feedback').filter(f => f.authorUid === uid && f.createdAt > since).length >= feedbackPerHour) fail(429, 'Du hast in der letzten Stunde schon viel Feedback geschickt. Bitte versuche es später noch einmal.', 'rate_limited');
    const name = s.get('members', a.personId)?.name ?? a.name, createdAt = at.toISOString(), feedbackId = randomUUID();
    const record = { id: feedbackId, message, category, status: 'open', createdAt, updatedAt: createdAt, version: 1, appVersion: (typeof b.appVersion === 'string' && b.appVersion.trim()) || null, platform, authorUid: uid, authorPersonId: a.personId, authorName: name, lastActivityAt: createdAt, authorSeen: 1 };
    s.put('feedback', feedbackId, { ...record, messages: [firstMessage(record)] });
    theater.enqueuePush({ title: 'Neues Feedback', body: `${name}: ${excerpt(message)}`, data: { adminFeedbackId: feedbackId }, adminsOnly: true });
    s.audit(uid, 'feedback.create', feedbackId);
    return { ok: true, id: feedbackId };
  });
}

/** The caller's own tickets, most recent activity first, with the number of unread answers. */
export function ownFeedback(theater, uid) {
  const a = theater.account(uid);
  const tickets = theater.store.all('feedback').filter(f => isOwner(a, f)).sort(byActivity).map(f => ticketView(theater, f));
  return { tickets, unread: tickets.filter(t => t.unread > 0).length };
}
export function ownTicketView(theater, uid, ticketId) { const a = theater.account(uid); return { ticket: ticketView(theater, ownTicket(theater, a, ticketId)) }; }

/** Marks the admins' answers as read by the author; no version change, nothing else moves. */
export function markFeedbackRead(theater, uid, ticketId) {
  return theater.store.transaction(() => {
    const a = theater.account(uid), f = ownTicket(theater, a, ticketId);
    const next = unreadFor(f) ? theater.store.put('feedback', f.id, { ...f, authorSeen: messagesOf(f).length }) : f;
    return { ticket: ticketView(theater, next) };
  });
}

const append = (f, entry, at) => ({ ...f, messages: [...messagesOf(f), entry], lastActivityAt: at, updatedAt: at, version: f.version + 1 });

/**
 * A follow-up by the author. It reopens an answered or closed ticket, and only that change
 * notifies the admins: further messages to a ticket that already waits for them stay silent.
 */
export function replyAsMember(theater, uid, ticketId, b) {
  return theater.store.transaction(() => {
    const s = theater.store, a = theater.account(uid), f = ownTicket(theater, a, ticketId), value = messageText(b);
    tooLong(f);
    const at = theater.clock(), since = new Date(+at - 3600000).toISOString();
    const recent = s.all('feedback').flatMap(x => list(x.messages)).filter(m => m.from === 'member' && m.byUid === uid && m.at > since && !m.id.endsWith('-0')).length;
    if (recent >= feedbackRepliesPerHour) fail(429, 'Du hast in der letzten Stunde schon viele Nachrichten geschickt. Bitte versuche es später noch einmal.', 'rate_limited');
    const iso = at.toISOString(), name = s.get('members', a.personId)?.name ?? a.name;
    const reopened = f.status === 'closed';
    const next = s.put('feedback', f.id, { ...append(f, { id: randomUUID(), from: 'member', text: value, at: iso, byUid: uid, byPersonId: a.personId ?? null, byName: name }, iso), status: 'open', authorSeen: messagesOf(f).length + 1, closedAt: null, closedBy: null });
    if (f.status !== 'open') theater.enqueuePush({ title: reopened ? 'Feedback wieder geöffnet' : 'Rückmeldung zum Feedback', body: `${name}: ${excerpt(value)}`, data: { adminFeedbackId: f.id }, adminsOnly: true });
    s.audit(uid, reopened ? 'feedback.reopen' : 'feedback.reply', f.id);
    return { ticket: ticketView(theater, next) };
  });
}

/**
 * An admin answer; the author hears about it by push. While an earlier answer is still unread,
 * further answers do not push again.
 */
export function replyAsAdmin(theater, uid, ticketId, b) {
  return theater.store.transaction(() => {
    const s = theater.store, a = theater.account(uid, true), f = ticket(theater, ticketId), value = messageText(b);
    tooLong(f);
    const iso = theater.clock().toISOString(), name = s.get('members', a.personId)?.name ?? a.name;
    const next = s.put('feedback', f.id, { ...append(f, { id: randomUUID(), from: 'admin', text: value, at: iso, byUid: uid, byPersonId: a.personId ?? null, byName: name }, iso), status: 'answered', closedAt: null, closedBy: null, answeredAt: f.answeredAt ?? iso });
    // No push for an admin's own ticket, and none while an earlier answer is still unread.
    if (f.authorPersonId != null && !isOwner(a, f) && !unreadFor(f)) theater.enqueuePush({ title: 'Antwort auf dein Feedback', body: `${name}: ${excerpt(value)}`, data: { feedbackId: f.id }, recipientPersonIds: [f.authorPersonId] });
    s.audit(uid, 'feedback.answer', f.id);
    return { feedback: ticketView(theater, next, { admin: true }) };
  });
}

const close = (theater, a, f, role) => {
  if (!answered(f)) fail(409, 'Schließen geht erst, nachdem die Theaterleitung geantwortet hat.', 'not_answered');
  if (f.status === 'closed') return f;
  const iso = theater.clock().toISOString();
  return theater.store.put('feedback', f.id, { ...f, status: 'closed', closedAt: iso, closedBy: { role, uid: a.uid, personId: a.personId ?? null, name: theater.store.get('members', a.personId)?.name ?? a.name }, updatedAt: iso, version: f.version + 1 });
};

/** The author closes their own ticket (after an admin answer). */
export function closeOwnFeedback(theater, uid, ticketId, b) {
  return theater.store.transaction(() => {
    const a = theater.account(uid), f = ownTicket(theater, a, ticketId);
    if (b.status !== 'closed') fail(400, 'Ungültiger Status.');
    checkVersion(f, b.version);
    const next = close(theater, a, f, 'member');
    theater.store.audit(uid, 'feedback.close', f.id);
    return { ticket: ticketView(theater, next) };
  });
}

/**
 * Admins close or reopen a ticket. Older admin apps still send `done` and `new`; they mean
 * `closed` and `open`.
 */
export function setFeedbackStatus(theater, uid, ticketId, b) {
  return theater.store.transaction(() => {
    const a = theater.account(uid, true);
    const status = { done: 'closed', new: 'open' }[b.status] ?? b.status;
    if (!['open', 'closed'].includes(status)) fail(400, 'Ungültiger Status.');
    const f = ticket(theater, ticketId);
    checkVersion(f, b.version);
    let next = f;
    if (status === 'closed') next = close(theater, a, f, 'admin');
    else if (f.status === 'closed') {
      const iso = theater.clock().toISOString();
      next = theater.store.put('feedback', f.id, { ...f, status: 'open', closedAt: null, closedBy: null, updatedAt: iso, version: f.version + 1 });
    }
    theater.store.audit(uid, 'feedback.status', f.id);
    return { feedback: ticketView(theater, next, { admin: true }) };
  });
}

/** All tickets for the admins, most recent activity first, with counters per status. */
export function feedbackList(theater, uid) {
  theater.account(uid, true);
  const all = theater.store.all('feedback').sort(byActivity);
  const counts = Object.fromEntries(feedbackTicketStatuses.map(x => [x, 0]));
  for (const f of all) counts[feedbackTicketStatuses.includes(f.status) ? f.status : 'open']++;
  return { feedback: all.map(f => ticketView(theater, f, { admin: true })), counts };
}
export function adminTicketView(theater, uid, ticketId) { theater.account(uid, true); return { feedback: ticketView(theater, ticket(theater, ticketId), { admin: true }) }; }
