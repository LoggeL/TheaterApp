import { berlinDateTime, eventNotificationBody } from './event-notification.mjs';
import { can, inAudience } from './theater.mjs';

// "Termin-Kiste" of the stage runner (`runnerEventCrates`): whoever was there at an event gets one
// private crate for it in the wardrobe, a normal costume crate with a shine chance of its own
// (`dupes.shinyChance.event`).
//
// - Being there is the attendance (`checkins`): recorded by an admin or a holder of the events right
//   ("Termine verwalten") with `checkin.save`, whatever the person answered before. A commitment
//   alone brings no crate; the app only tells that one waits after the event.
// - Nobody records the attendance: `attendanceRules.autoAdoptAfterMs` (24 h) after the end the own
//   answers `yes`/`late` are written down as attendance (`checkins` with `source: 'auto'`), and these
//   people get their crate. The implicit yes of an auto-accepted event is no own answer and counts
//   not. As soon as an admin recorded anyone as there or missing, their list applies and nothing is
//   adopted, also not for the people they left unrecorded: who records only some has usually marked
//   those present (the app offers "Alle Zugesagten als da markieren") and left out who was not
//   there; filling the gaps from the answers would undo that. Terminfinder slots (their yes is the
//   booking, also one set by an admin) are not adopted.
// - Corrections later on: marked as there brings the crate, marked as missing (or unrecorded) lets a
//   crate not opened yet lapse (`withdrawn`); marked as there again brings the same crate back. An
//   opened crate stays. One crate per person and event (`runnerEventCrates`, key `eventId:personId`).
// - Reminders: `reminderAfterMs` (30 min) after the end the people responsible get "Anwesenheit
//   erfassen" with a link to the check-in, once, and `secondReminderBeforeMs` (2 h) before the
//   adoption a second time; neither once anyone is recorded. Responsible: the event's creator and
//   the directors of its productions, if they hold the events right; else invited holders of the
//   right; else all of them. Not for social events (attendance there is nobody's duty).
// - Only events ending after the Termin-Kisten came (`settings/eventCratesSince`): no crates, no
//   adoption and no reminders for earlier ones. The job (`settleAttendance`) runs with the push
//   worker every 15 s; its state per event (`attendanceSettle`) is in the database, so a restart
//   catches up and nothing is sent or adopted twice.
// - The crate keeps the event's title and start; deleting the person deletes their crates.
// - No game limit: the rule only keeps it to one crate per event.

export const attendanceRules = Object.freeze({ autoAdoptAfterMs: 24 * 3600000, reminderAfterMs: 30 * 60000, secondReminderBeforeMs: 2 * 3600000 });
const kind = 'runnerEventCrates';
const settleKind = 'attendanceSettle';
const committed = status => status === 'yes' || status === 'late';
const key = (eventId, personId) => `${eventId}:${personId}`;
const rulesOf = t => ({ ...attendanceRules, ...t.attendanceRules });

/** When the Termin-Kisten came: set on first use, so earlier events never bring one. */
export function eventCratesSince(t) {
  const saved = t.store.get('settings', 'eventCratesSince');
  return saved ? Date.parse(saved.at) : Date.parse(t.store.put('settings', 'eventCratesSince', { at: t.clock().toISOString() }).at);
}
const counts = (t, e) => !e.slotPoolId && Date.parse(e.endsAt) > eventCratesSince(t);

/**
 * Settles the Termin-Kiste of [personId] after their attendance at [e] was set to [present]
 * (`true`, `false` or `null`) by a check-in (`source` `checkin`) or the adoption (`auto`).
 * Returns what changed: `{ granted }`, `{ withdrawn }` or null.
 */
export function settleCheckinCrate(t, personId, e, present, source = 'checkin') {
  if (!e || !counts(t, e)) return null;
  const s = t.store, at = t.clock().toISOString(), old = s.get(kind, key(e.id, personId));
  if (present !== true) {
    if (old?.state !== 'waiting') return null;
    s.put(kind, key(e.id, personId), { ...old, state: 'withdrawn', withdrawnAt: at });
    return { withdrawn: true };
  }
  if (old?.state === 'waiting' || old?.state === 'opened') return null;
  // A lapsed crate comes back as it was (same grant), with the event's current title and start.
  s.put(kind, key(e.id, personId), { eventId: e.id, personId, grantedAt: old?.grantedAt ?? at, source, title: e.title, startsAt: e.startsAt, state: 'waiting' });
  return { granted: true };
}

/**
 * What the reply to an own answer tells about the Termin-Kiste: `{ pending: true, player }` when
 * the answer became a commitment to an event still to come that can bring one, else null. `player`
 * says whether the person knows the game: the app only points to the wardrobe then.
 */
export function eventCrateNotice(t, personId, e, previous, status) {
  const s = t.store;
  if (!committed(status) || committed(previous ?? null) || !counts(t, e) || Date.parse(e.endsAt) <= +t.clock()) return null;
  if (!inAudience(s.get('members', personId), e, s) || s.get(kind, key(e.id, personId))?.state === 'opened') return null;
  return { pending: true, player: !!(s.get('runnerProgress', personId) || s.get('runnerScores', personId)) };
}

/** Termin-Kisten [personId] has waiting, the earliest event first. */
export function waitingEventCrates(t, personId) {
  return t.store.all(kind).filter(x => x.personId === personId && x.state === 'waiting')
    .sort((x, y) => String(x.startsAt).localeCompare(String(y.startsAt)) || String(x.eventId).localeCompare(String(y.eventId)));
}

/** What the app shows of a crate. */
export const crateView = x => ({ eventId: x.eventId, title: x.title, startsAt: x.startsAt });

/** The waiting crate of [eventId], or the earliest waiting one without; null if there is none. */
export function nextEventCrate(t, personId, eventId = null) {
  const waiting = waitingEventCrates(t, personId);
  return eventId == null ? waiting[0] ?? null : waiting.find(x => x.eventId === String(eventId)) ?? null;
}

/** Marks [crate] as opened with the drawn [itemId]. */
export function markEventCrateOpened(t, crate, itemId) {
  t.store.put(kind, key(crate.eventId, crate.personId), { ...crate, state: 'opened', openedAt: t.clock().toISOString(), itemId });
}

/** Deletes all crates of [personId] (with the person). */
export function forgetEventCrates(store, personId) {
  for (const x of store.all(kind).filter(x => x.personId === personId)) store.delete(kind, key(x.eventId, personId));
}

/** Person ids with an adopted attendance per event, for the check-in view (`autoCheckinsByEvent`). */
export function autoCheckins(store) {
  const byEvent = {};
  for (const c of store.all('checkins')) if (c.source === 'auto' && c.present === true) (byEvent[c.eventId] ??= []).push(c.personId);
  return byEvent;
}

/** Who is reminded to record the attendance of [e] (see the rules above). */
export function attendanceRecorders(t, e) {
  const s = t.store;
  const holders = s.accounts().filter(a => a.status === 'approved' && a.personId != null && s.get('members', a.personId)?.active === true && can(a, 'events')).map(a => a.personId);
  const productions = [...new Set([e.productionId, ...(Array.isArray(e.productionIds) ? e.productionIds : [])].filter(Boolean))];
  const responsible = new Set([e.createdBy, ...productions.flatMap(id => s.get('productions', id)?.directorMemberIds ?? [])].filter(x => x != null).map(Number));
  const first = holders.filter(x => responsible.has(x));
  if (first.length) return first;
  const invited = holders.filter(x => inAudience(s.get('members', x), e, s));
  return invited.length ? invited : holders;
}

/**
 * The attendance job, run with the push worker: reminds the people responsible to record the
 * attendance and adopts the own commitments of events nobody recorded. Idempotent per event.
 */
export function settleAttendance(t, now = t.clock()) {
  const s = t.store, at = +now, rules = rulesOf(t);
  const since = s.transaction(() => eventCratesSince(t));
  const recorded = new Set(s.all('checkins').filter(c => typeof c.present === 'boolean' && c.source !== 'auto').map(c => c.eventId));
  const state = new Map(s.all(settleKind).map(x => [x.eventId, x]));
  for (const e of s.all('events')) {
    const end = Date.parse(e.endsAt);
    if (e.slotPoolId || !(end > since) || at < end + rules.reminderAfterMs) continue;
    const done = state.get(e.id) ?? { eventId: e.id };
    if (done.adoptedAt) continue;
    const adoptAt = end + rules.autoAdoptAfterMs;
    s.transaction(() => {
      if (s.get(settleKind, e.id)?.adoptedAt) return;
      const next = { ...done };
      if (at >= adoptAt) {
        // The own commitments become the attendance, unless an admin recorded anyone.
        next.adoptedAt = now.toISOString(); next.adopted = 0;
        if (!recorded.has(e.id)) for (const r of s.all('responses').filter(r => r.eventId === e.id && committed(r.status))) {
          if (s.get('members', r.personId)?.active !== true || typeof s.get('checkins', key(e.id, r.personId))?.present === 'boolean') continue;
          const old = s.get('checkins', key(e.id, r.personId));
          s.put('checkins', key(e.id, r.personId), { eventId: e.id, personId: r.personId, present: true, source: 'auto', version: (old?.version ?? 0) + 1, updatedAt: now.toISOString() });
          settleCheckinCrate(t, r.personId, e, true, 'auto');
          next.adopted++;
        }
        else next.recorded = true;
      } else if (!recorded.has(e.id) && t.pushEnabled && e.type !== 'social') {
        const second = rules.secondReminderBeforeMs != null && at >= adoptAt - rules.secondReminderBeforeMs;
        if (second ? !next.secondReminderAt : !next.reminderAt) {
          const recipients = attendanceRecorders(t, e);
          const body = second ? `Bitte Anwesenheit für „${e.title}“ erfassen. Sonst werden am ${berlinDateTime(adoptAt)} die Zusagen übernommen.` : `Bitte Anwesenheit für „${e.title}“ erfassen · ${eventNotificationBody(e)}`;
          if (recipients.length) t.enqueuePush({ title: 'Anwesenheit erfassen', body, data: { eventId: e.id, intent: 'checkin' }, recipientPersonIds: recipients, fixedText: true, email: false, pushKind: 'attendanceCheckin' });
          // The second one makes a first one still due (after a pause of the server) superfluous.
          next.reminderAt ??= now.toISOString();
          if (second) next.secondReminderAt = now.toISOString();
        }
      }
      if (JSON.stringify(next) !== JSON.stringify(done)) s.put(settleKind, e.id, next);
    });
  }
}
