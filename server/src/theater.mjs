import { berlinDateTime, customReminderMinutes, defaultReminders, eventNotificationBody } from './event-notification.mjs';
import { berlinParts, fromBerlin, seriesOccurrences, seriesSummary } from './event-series.mjs';
import { compareProductionsNewestFirst } from './production-order.mjs';
import { createHash, randomUUID } from 'node:crypto';

// Machine-readable reasons next to the German message; clients branch on `code`, never on the text.
const defaultCodes = { 400: 'invalid', 401: 'unauthenticated', 403: 'forbidden', 404: 'not_found', 409: 'conflict', 413: 'too_large' };
export class AppError extends Error {
  constructor(status, message, code = defaultCodes[status] ?? 'error') { super(message); this.status = status; this.code = code; }
}
const fail = (status, message, code) => { throw new AppError(status, message, code); };
const text = (value, max = 250) => typeof value === 'string' ? value.trim().slice(0, max) : '';
const required = (value, label, max) => text(value, max) || fail(400, `${label} fehlt.`);
const now = () => new Date().toISOString();
const day = value => new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Berlin' }).format(new Date(value));
const date = value => typeof value === 'string' && Number.isFinite(Date.parse(value)) ? new Date(value).toISOString() : fail(400, 'Ungültige Zeitangabe.');
const id = () => randomUUID();
const list = value => Array.isArray(value) ? value : [];
// Members can still confirm or report a late arrival, but no longer decline.
const declineCutoffMs = 60 * 60 * 1000;
// Changes are pushed only for events in the near future, like the events badge.
export const changePushWindowDays = 14;
// Participation is only summarized for recent, binding events.
export const participationWindowDays = 183;
const voluntaryEventTypes = ['social'];
// Admin reminders (nudges) per message, event, poll or slot pool are rate-limited.
export const remindCooldownMs = 10 * 60 * 1000;
// Declines this close to the start are pushed to admins and the production's directors.
export const lateDeclineWindowMs = 24 * 60 * 60 * 1000;
// Additive API features this server supports; clients only offer what is listed here.
export const apiFeatures = Object.freeze(['addressedToMe', 'absenceOutcome', 'eventDetailsV2', 'pollPush', 'pollRemind', 'pollDelete', 'nudges', 'errorCodes', 'slotNotices', 'lateDeclines', 'seriesEdit']);
const seriesFields = ['title', 'description', 'place', 'type', 'locked', 'roleIds', 'personIds', 'productionIds', 'productionId'];
// Legacy records may lack fields; compare them as event.save would store them.
const sameValue = (field, x, y) => {
  const norm = v => field.endsWith('Ids') ? list(v) : field === 'locked' ? v === true : field === 'type' ? v ?? 'rehearsal' : field === 'productionId' ? v || null : v ?? '';
  return JSON.stringify(norm(x)) === JSON.stringify(norm(y));
};
// Target audiences are person roles; an empty list addresses everyone.
export const inRoles = (member, roleIds) => !list(roleIds).length || list(member?.roleIds).some(x => list(roleIds).includes(x));
// A production's ensemble: its cast, its directors and people added by hand (crew).
// Free-text team functions (e.g. "Licht") only for people on the production's team.
const teamFunctions = (functions, memberIds) => Object.fromEntries(Object.entries(functions ?? {}).filter(([personId, label]) => memberIds.includes(Number(personId)) && typeof label === 'string' && label));
export const productionEnsemble = production => [...new Set([
  ...Object.values(production?.casting ?? {}).filter(x => x != null).map(Number),
  ...list(production?.directorMemberIds).map(Number),
  ...list(production?.memberIds).map(Number),
])];
// A member is addressed by a role, a production ensemble or by name; nothing chosen = everyone.
// Ensembles are resolved through the store, so later casting changes apply.
export const inAudience = (member, item, store) => {
  const roleIds = list(item?.roleIds), personIds = list(item?.personIds), productionIds = list(item?.productionIds);
  if (!roleIds.length && !personIds.length && !productionIds.length) return true;
  return (roleIds.length > 0 && inRoles(member, roleIds)) || personIds.includes(member?.id)
    || (member?.id != null && productionIds.some(id => productionEnsemble(store?.get('productions', id)).includes(member.id)));
};
export const eventTypes = ['rehearsal', 'readthrough', 'technical', 'costume', 'dress', 'performance', 'meeting', 'workshop', 'setup', 'teardown', 'social', 'other'];
const initialRoles = ['Schauspiel', 'Regie', 'Technik', 'Kostüm', 'Maske', 'Bühnenbau', 'Organisation'];
// Free-text groups predate person roles; these names carry no role of their own.
const groupRoleAliases = { ensemble: 'Schauspiel', kostümteam: 'Kostüm' };
const groupsWithoutRole = ['', 'admin', 'alle', 'theaterleitung'];
// One-off move from the old free-text groups to person roles.
export const migrateGroupsToRoles = store => {
  const roles = store.all('personRoles');
  for (const m of store.all('members')) {
    if (!Object.hasOwn(m, 'group')) continue;
    const { group, ...rest } = m;
    const key = text(group).toLowerCase();
    let roleIds = list(m.roleIds);
    if (!groupsWithoutRole.includes(key)) {
      const name = groupRoleAliases[key] ?? text(group);
      let role = roles.find(r => r.name.toLowerCase() === name.toLowerCase());
      if (!role) {
        role = { id: id(), name, version: 1 };
        store.put('personRoles', role.id, role); roles.push(role);
      }
      if (!roleIds.includes(role.id)) roleIds = [...roleIds, role.id];
    }
    store.put('members', m.id, { ...rest, roleIds, version: (m.version ?? 0) + 1 });
  }
  for (const e of store.all('events')) {
    if (!Object.hasOwn(e, 'group')) continue;
    const { group, ...rest } = e;
    store.put('events', e.id, { ...rest, version: (e.version ?? 0) + 1 });
  }
  store.put('settings', 'groupsMigrated', { at: now() });
};
const cancelledEvent = e => ({ id: e.id, title: e.title, startsAt: e.startsAt, endsAt: e.endsAt, place: e.place, roleIds: e.roleIds, personIds: e.personIds, productionIds: e.productionIds });
const initials = name => name.split(/\s+/).filter(Boolean).slice(0, 2).map(n => n[0]).join('').toUpperCase();

export class Theater {
  constructor(store, { bootstrapEmail = '', pushEnabled = false, emailEnabled = false, clock = () => new Date() } = {}) {
    this.store = store; this.bootstrapEmail = bootstrapEmail.trim().toLowerCase(); this.pushEnabled = pushEnabled; this.emailEnabled = emailEnabled; this.clock = clock;
    if (!store.get('settings', 'personRolesInitialized')) store.transaction(() => {
      for (const [i, name] of initialRoles.entries()) store.put('personRoles', `role-${i + 1}`, { id: `role-${i + 1}`, name, version: 1 });
      store.put('settings', 'personRolesInitialized', { at: now() });
    });
    if (!store.get('settings', 'groupsMigrated')) store.transaction(() => migrateGroupsToRoles(store));
  }
  session(identity, registrationName) {
    return this.store.transaction(() => {
      let a = this.store.account(identity.uid);
      const provider = identity.firebase?.sign_in_provider ?? 'password';
      const identityReady = provider !== 'password' || identity.email_verified === true;
      const identityName = text(identity.name, 120);
      let suppliedName;
      if (registrationName !== undefined) {
        if (a && a.status !== 'pending') fail(403, 'Der Name zur Zuordnung kann nur vor der Freigabe geändert werden.');
        if (typeof registrationName !== 'string' || !registrationName.trim() || registrationName.trim().length > 120 || /[\u0000-\u001f\u007f]/.test(registrationName)) fail(400, 'Bitte deinen Namen mit höchstens 120 Zeichen eingeben.');
        suppliedName = registrationName.trim();
      }
      // Keep the association name independent of later provider profile changes.
      const nameProvided = suppliedName !== undefined || a?.nameProvided === true || (a?.nameProvided === undefined && provider === 'password' && !!identityName);
      const name = suppliedName ?? (a?.nameProvided ? a.name : identityName || a?.name || text(identity.email).split('@')[0] || 'Neues Konto');
      const version = a ? a.version + (suppliedName !== undefined && (a.name !== name || !a.nameProvided) ? 1 : 0) : 1;
      const fields = { name, nameProvided, version, email: text(identity.email), emailVerified: identity.email_verified === true, identityReady, provider, lastSeenAt: now() };
      a = a ? { ...a, ...fields } : { uid: identity.uid, personId: null, status: 'pending', role: 'member', createdAt: now(), version: 1, ...fields };
      if (!this.store.get('settings', 'bootstrap') && this.bootstrapEmail && a.email.toLowerCase() === this.bootstrapEmail && a.emailVerified && this.store.accounts().every(x => x.role !== 'admin')) {
        const personId = this.nextPersonId();
        this.store.put('members', personId, { id: personId, name: a.name, initials: initials(a.name), active: true });
        a = { ...a, personId, status: 'approved', role: 'admin', approvedAt: now(), approvedBy: 'bootstrap' };
        this.store.put('settings', 'bootstrap', { uid: a.uid, at: now() });
        this.store.audit('bootstrap', 'account.approve', a.uid);
      }
      // Tell admins once per account, as soon as the registration can actually be linked.
      if (a.status === 'pending' && a.identityReady && a.nameProvided && !a.adminNotifiedAt) {
        a = { ...a, adminNotifiedAt: now() };
        this.enqueuePush({ title: 'Neue Registrierung', body: `${a.name} wartet auf Zuordnung.`, data: { accountUid: a.uid }, adminsOnly: true });
      }
      this.store.saveAccount(a);
      return this.profile(a);
    });
  }
  profile(a) {
    const m = a.personId == null ? null : this.store.get('members', a.personId);
    return { userId: a.uid, displayName: m?.name ?? a.name, email: a.email, needsRegistrationName: a.status === 'pending' && a.nameProvided === false, avatarId: m?.avatarId ?? null, roleIds: list(m?.roleIds), profileVersion: m?.profileVersion ?? 0, role: a.role, personId: a.personId, status: a.status, emailVerified: a.emailVerified, identityReady: a.identityReady, provider: a.provider, mustChangePassword: false, directorProductionIds: this.store.all('productions').filter(p => list(p.directorMemberIds).includes(a.personId)).map(p => p.id) };
  }
  account(uid, admin = false) {
    const a = this.store.account(uid);
    if (!a || a.status !== 'approved' || !a.personId || !a.identityReady || this.store.get('members', a.personId)?.active !== true) fail(403, 'Dein Theaterzugang ist noch nicht freigegeben oder wurde gesperrt.', 'access');
    if (admin && a.role !== 'admin') fail(403, 'Hierfür ist ein Admin-Zugang erforderlich.');
    return a;
  }
  // Ids of deleted people are never handed out again (see forgetMember).
  nextPersonId() { return Math.max(0, this.store.get('settings', 'lastPersonId')?.id ?? 0, ...this.store.all('members').map(m => m.id)) + 1; }
  snapshot(uid) {
    const a = this.account(uid); const admin = a.role === 'admin', member = this.store.get('members', a.personId), nudges = admin ? this.nudges() : null;
    const responses = this.store.all('responses');
    const events = this.store.all('events').filter(e => this.canSee(a, e)).map(e => ({ ...e, eventDate: day(e.startsAt), people: responses.filter(r => r.eventId === e.id && ['yes', 'late'].includes(r.status)).length, addressedToMe: inAudience(member, e, this.store), ...(admin ? this.reminded(nudges, 'event', e.id) : {}) }));
    const own = responses.filter(r => r.personId === a.personId);
    const checkinsByEvent = {}, memberAttendanceByEvent = {}, arrivalsByEvent = {};
    if (admin) {
      for (const c of this.store.all('checkins')) (checkinsByEvent[c.eventId] ??= {})[c.personId] = c.present;
      for (const r of responses) {
        (memberAttendanceByEvent[r.eventId] ??= {})[r.personId] = r.status;
        (arrivalsByEvent[r.eventId] ??= {})[r.personId] = r.expectedArrivalAt;
      }
    }
    const receipts = this.store.all('receipts').filter(r => r.personId === a.personId);
    return { apiVersion: 1, user: this.profile(a), events, attendanceByEvent: Object.fromEntries(own.map(r => [r.eventId, r.status])), declineReasons: Object.fromEntries(own.map(r => [r.eventId, r.reason])), expectedArrivals: Object.fromEntries(own.map(r => [r.eventId, r.expectedArrivalAt])), absences: this.store.all('absences').filter(x => x.personId === a.personId), polls: this.polls(a, nudges), slotPools: this.slotPools(a, nudges), personRoles: this.store.all('personRoles'), members: this.store.all('members'), productions: this.store.all('productions').sort(compareProductionsNewestFirst).map(p => ({ ...p, ensemble: productionEnsemble(p) })), checkinsByEvent, memberAttendanceByEvent, arrivalsByEvent, checkinVersions: admin ? Object.fromEntries(this.store.all('checkins').map(c => [`${c.eventId}:${c.personId}`, c.version])) : {}, reminders: { ...defaultReminders, ...this.store.get('reminders', a.personId) }, messages: this.store.all('messages').filter(m => this.canReadMessage(a, m)).map(m => ({ ...m, read: receipts.some(r => r.messageId === m.id) || m.authorId === a.personId, addressedToMe: this.messageAddresses(member, m), ...(admin ? { ...this.messageReach(m), ...this.reminded(nudges, 'message', m.id) } : {}) })).sort((x, y) => y.createdAt.localeCompare(x.createdAt)), pendingAccounts: admin ? this.store.accounts().filter(x => x.status === 'pending') : [], capabilities: { pushConfigured: this.pushEnabled, emailConfigured: this.emailEnabled, firebaseAuth: true, checkins: true, admin: true, sampleData: this.store.get('settings', 'sampleData')?.enabled === true, features: [...apiFeatures] }, serverTime: now() };
  }
  /** Slot pools ("Terminfinder"): invited people book one time slot each. */
  slotPools(a, nudges = a.role === 'admin' ? this.nudges() : null) {
    const bookings = this.store.all('slotBookings'), member = this.store.get('members', a.personId);
    return this.store.all('slotPools').filter(p => this.canSee(a, p)).map(p => {
      const own = bookings.find(b => b.poolId === p.id && b.personId === a.personId);
      return { ...p, addressedToMe: inAudience(member, p, this.store), ...(nudges ? this.reminded(nudges, 'slotPool', p.id) : {}), myBooking: own?.slotId ?? null, slots: p.slots.map(slot => {
        const people = bookings.filter(b => b.poolId === p.id && b.slotId === slot.id).map(b => ({ personId: b.personId, name: this.store.get('members', b.personId)?.name ?? 'Ehemaliges Mitglied' })).sort((x, y) => x.name.localeCompare(y.name, 'de'));
        return { ...slot, booked: people.length, people };
      }) };
    }).sort((x, y) => y.createdAt.localeCompare(x.createdAt));
  }
  /** Keeps the calendar event of a slot in line with its bookings; booked people respond yes. */
  syncSlotEvent(pool, slot) {
    const s = this.store, eventId = `slot-${pool.id}-${slot.id}`, old = s.get('events', eventId);
    const personIds = s.all('slotBookings').filter(b => b.poolId === pool.id && b.slotId === slot.id).map(b => b.personId).sort((x, y) => x - y);
    for (const kind of ['responses', 'checkins']) for (const x of s.all(kind).filter(x => x.eventId === eventId && !personIds.includes(x.personId))) s.delete(kind, `${eventId}:${x.personId}`);
    if (!personIds.length) { if (old) s.delete('events', eventId); return; }
    s.put('events', eventId, { id: eventId, title: pool.title, description: pool.description, startsAt: slot.startsAt, endsAt: slot.endsAt, place: pool.place, type: pool.type, locked: false, productionId: null, sceneIds: [], roleIds: [], personIds, slotPoolId: pool.id, version: (old?.version ?? 0) + 1 });
    for (const personId of personIds) if (s.get('responses', `${eventId}:${personId}`)?.status !== 'yes') s.put('responses', `${eventId}:${personId}`, { eventId, personId, status: 'yes', reason: '', expectedArrivalAt: null, updatedAt: now() });
  }
  bookSlot(pool, personId, slotId) {
    const s = this.store, key = `${pool.id}:${personId}`, previous = s.get('slotBookings', key);
    if (slotId === null) { if (previous) { s.delete('slotBookings', key); this.syncSlotEvent(pool, pool.slots.find(x => x.id === previous.slotId)); } return; }
    const slot = pool.slots.find(x => x.id === slotId);
    if (!slot) fail(404, 'Zeitfenster nicht gefunden.');
    if (Date.parse(slot.startsAt) <= +this.clock()) fail(409, 'Dieses Zeitfenster hat schon begonnen.', 'closed');
    if (previous?.slotId === slotId) return;
    if (s.all('slotBookings').filter(b => b.poolId === pool.id && b.slotId === slotId).length >= slot.capacity) fail(409, 'Dieses Zeitfenster ist schon voll.', 'full');
    s.put('slotBookings', key, { poolId: pool.id, slotId, personId, bookedAt: now() });
    if (previous) this.syncSlotEvent(pool, pool.slots.find(x => x.id === previous.slotId));
    this.syncSlotEvent(pool, slot);
  }
  polls(a, nudges = a.role === 'admin' ? this.nudges() : null) {
    const votes = this.store.all('pollVotes'), member = this.store.get('members', a.personId);
    return this.store.all('polls').filter(p => !p.deleted && this.canSee(a, p)).map(p => {
      const own = votes.find(v => v.pollId === p.id && v.personId === a.personId);
      const responses = votes.filter(v => v.pollId === p.id);
      const anonymous = p.anonymous !== false, eligible = nudges ? new Set(this.audienceIds(p)) : null;
      // Admins see how many can vote and how many of them did; who voted stays hidden for anonymous polls.
      return { ...p, anonymous, closed: this.pollClosed(p), choice: own?.optionId ?? null, totalVotes: responses.length, addressedToMe: inAudience(member, p, this.store), ...(nudges ? { eligibleCount: eligible.size, eligibleVotes: responses.filter(v => eligible.has(v.personId)).length, ...this.reminded(nudges, 'poll', p.id) } : {}), options: p.options.map(o => {
        const selected = responses.filter(v => v.optionId === o.id);
        return { id: o.id, label: o.label, votes: selected.length, ...(!anonymous ? { voters: selected.map(v => ({ personId: v.personId, name: this.store.get('members', v.personId)?.name ?? 'Ehemaliges Mitglied' })).sort((a, b) => a.name.localeCompare(b.name, 'de')) } : {}) };
      }) };
    }).sort((x, y) => y.createdAt.localeCompare(x.createdAt));
  }
  canSee(a, item) { return a.role === 'admin' || inAudience(this.store.get('members', a.personId), item, this.store); }
  // Roles are resolved when reading, so later role members see the message too.
  canReadMessage(a, m) { return a.role === 'admin' || this.messageAddresses(this.store.get('members', a.personId), m); }
  /** Whether a message is addressed to the member, without the admin bypass. */
  messageAddresses(member, m) {
    if (m.audience === 'all' || (member?.id != null && list(m.recipientPersonIds).includes(member.id))) return true;
    return (list(m.roleIds).length > 0 && inRoles(member, m.roleIds)) || (list(m.productionIds).length > 0 && inAudience(member, { productionIds: m.productionIds }, this.store));
  }
  /** Active members an event, poll or slot pool is addressed to. */
  audienceIds(item) { return this.store.all('members').filter(m => m.active !== false && inAudience(m, item, this.store)).map(m => m.id); }
  pollClosed(p) { return p.closed || (!!p.closesAt && Date.parse(p.closesAt) <= +this.clock()); }
  /** Last admin reminders, keyed `<kind>:<targetId>` (kind: message, event, poll, slotPool). */
  nudges() { return new Map(this.store.db.prepare("SELECT id, data FROM entities WHERE kind = 'nudges'").all().map(r => [r.id, JSON.parse(r.data)])); }
  reminded(nudges, kind, targetId) { const n = nudges.get(`${kind}:${targetId}`); return { lastRemindedAt: n?.at ?? null, remindCount: n?.count ?? 0 }; }
  /** Rejects a reminder within the cooldown; nudges never bump the target's version (queued emails would go stale). */
  checkCooldown(kind, targetId) {
    const last = this.store.get('nudges', `${kind}:${targetId}`);
    if (last && +this.clock() - Date.parse(last.at) < remindCooldownMs) fail(409, 'Die letzte Erinnerung ist gerade erst rausgegangen. Bitte später erneut versuchen.', 'cooldown');
  }
  recordNudge(a, kind, targetId, recipients) {
    const key = `${kind}:${targetId}`, at = new Date(+this.clock()).toISOString();
    this.store.put('nudges', key, { at, by: a.personId, recipients, count: (this.store.get('nudges', key)?.count ?? 0) + 1 });
    return at;
  }
  /** Active members a message or push is addressed to: everyone, or roles, ensembles and named people. */
  messageRecipients(m) {
    const active = this.store.all('members').filter(x => x.active);
    if (m.audience === 'all') return active.map(x => x.id);
    const ensembles = new Set(list(m.productionIds).flatMap(x => productionEnsemble(this.store.get('productions', x))));
    const people = list(m.recipientPersonIds);
    return active.filter(x => (list(m.roleIds).length && inRoles(x, m.roleIds)) || ensembles.has(x.id) || people.includes(x.id)).map(x => x.id);
  }
  /** Who should read a message and who already did; admins only. */
  messageReach(m) {
    const recipientIds = this.messageRecipients(m);
    const read = new Set(this.store.all('receipts').filter(r => r.messageId === m.id).map(r => r.personId));
    // Authors have read their own message (computed, so older messages are covered too).
    return { recipientIds, readerIds: recipientIds.filter(x => read.has(x) || (m.authorId != null && x === m.authorId)) };
  }
  /** Validated audience of an admin message or push. */
  messageTarget(b) {
    const audience = ['selected', 'roles'].includes(b.audience) ? 'selected' : 'all';
    const people = audience === 'all' ? [] : [...new Set(list(b.recipientPersonIds).map(Number))];
    if (people.some(m => !this.store.get('members', m)?.active)) fail(400, 'Bitte gültige Empfänger auswählen.');
    const target = { audience, roleIds: audience === 'all' ? [] : this.audience(b.roleIds), productionIds: audience === 'all' ? [] : this.productionAudience(b.productionIds), recipientPersonIds: people };
    const recipients = this.messageRecipients(target);
    if (!recipients.length) fail(400, audience === 'all' ? 'Bitte gültige Empfänger auswählen.' : 'Bitte mindestens eine Rolle, ein Stück oder eine Person mit aktiven Mitgliedern auswählen.');
    return { target, recipients };
  }
  audience(value) {
    const roleIds = [...new Set(list(value).map(String))];
    if (roleIds.some(x => !this.store.get('personRoles', x))) fail(400, 'Unbekannte Rolle ausgewählt.');
    return roleIds;
  }
  productionAudience(value) {
    const ids = [...new Set(list(value).map(String))];
    if (ids.length > 20 || ids.some(x => !this.store.get('productions', x))) fail(400, 'Unbekanntes Stück ausgewählt.');
    return ids;
  }
  invitedPeople(value, previous = []) {
    const personIds = [...new Set(list(value).map(Number))];
    // People invited earlier may stay invited after they became inactive.
    if (personIds.length > 200 || personIds.some(x => !(this.store.get('members', x)?.active || list(previous).includes(x)))) fail(400, 'Bitte gültige Personen auswählen.');
    return personIds;
  }
  script(uid, productionId) {
    this.account(uid);
    const p = this.store.get('productions', productionId), doc = this.store.get('scripts', productionId);
    if (!p || !doc) fail(404, 'Das Drehbuch ist nicht verfügbar.');
    return { ...doc, roles: doc.roles.map(r => { const personId = p.casting?.[r.id]; const member = this.store.get('members', personId); return { ...r, personId: personId ?? null, actor: member?.name ?? r.actor ?? '' }; }), fetchedAt: now(), stale: false };
  }
  adminData(uid) { this.account(uid, true); return { accounts: this.store.accounts(), members: this.store.all('members'), productions: this.store.all('productions').sort(compareProductionsNewestFirst) }; }
  eventDetails(uid, eventId) {
    this.account(uid, true);
    const e = this.store.get('events', eventId);
    if (!e) fail(404, 'Termin nicht gefunden.');
    const d = day(e.startsAt), responses = this.store.all('responses').filter(r => r.eventId === eventId), absences = this.store.all('absences').filter(x => x.from <= d && x.to >= d);
    const invitedIds = this.audienceIds(e), answered = new Set(responses.filter(r => ['yes', 'late', 'no'].includes(r.status)).map(r => r.personId)), absent = new Set(absences.map(x => x.personId));
    return { responses, checkins: this.store.all('checkins').filter(r => r.eventId === eventId), absences, invitedIds, openIds: invitedIds.filter(x => !answered.has(x)), absentIds: invitedIds.filter(x => absent.has(x)), ...this.reminded(this.nudges(), 'event', eventId) };
  }
  /** Deletes a login and its link; the person and their theater data stay. `deleteIdentity` removes the Firebase user. */
  async deleteAccount(uid, targetUid, version, deleteIdentity = null) {
    const check = () => {
      const a = this.account(uid, true), target = this.store.account(targetUid);
      if (!target || target.version !== version) fail(409, 'Das Konto hat sich geändert. Bitte neu laden.', 'version_conflict');
      if (target.uid === a.uid) fail(409, 'Das eigene Konto hier nicht löschen.');
      if (target.role === 'admin' && target.status === 'approved' && this.store.accounts().filter(x => x.status === 'approved' && x.role === 'admin').length <= 1) fail(409, 'Der letzte Admin muss erhalten bleiben.');
    };
    check();
    // Remove the login first: a failure leaves a complete, still deletable account.
    if (deleteIdentity) await deleteIdentity(targetUid);
    this.store.transaction(() => { check(); this.forgetAccount(targetUid, uid); });
    return { ok: true };
  }
  forgetAccount(targetUid, actor) {
    for (const d of this.store.all('devices').filter(d => d.uid === targetUid)) this.store.delete('devices', d.id);
    this.store.db.prepare('DELETE FROM requests WHERE uid = ?').run(targetUid);
    this.store.deleteAccount(targetUid);
    this.store.audit(actor, 'account.delete', targetUid);
  }
  /** Recent response and attendance counts; members see their own, admins see all active people. */
  participation(uid) {
    const a = this.account(uid), at = +this.clock(), since = at - participationWindowDays * 86400000;
    const events = this.store.all('events').filter(e => !voluntaryEventTypes.includes(e.type) && Date.parse(e.endsAt) < at && Date.parse(e.startsAt) >= since);
    const responses = new Map(this.store.all('responses').map(r => [`${r.eventId}:${r.personId}`, r.status]));
    const checkins = new Map(this.store.all('checkins').map(c => [`${c.eventId}:${c.personId}`, c.present]));
    const linkedSince = new Map(this.store.accounts().filter(x => x.status === 'approved' && x.personId != null).map(x => [x.personId, Date.parse(x.approvedAt ?? x.createdAt)]));
    const summary = member => {
      const counts = { events: 0, answerable: 0, answered: 0, recorded: 0, attended: 0, missedAfterCommitment: 0, missedUnannounced: 0 };
      for (const e of events.filter(e => inAudience(member, e, this.store))) {
        const key = `${e.id}:${member.id}`, status = responses.get(key), present = checkins.get(key);
        // Only people with an app account at that time could respond in the app.
        const answerable = Date.parse(e.startsAt) > (linkedSince.get(member.id) ?? Infinity);
        counts.events++;
        if (answerable) { counts.answerable++; if (['yes', 'late', 'no'].includes(status)) counts.answered++; }
        if (typeof present !== 'boolean') continue;
        // A timely decline is reliable behaviour and never counts as missing.
        counts.recorded++;
        if (present) counts.attended++;
        else if (['yes', 'late'].includes(status)) counts.missedAfterCommitment++;
        else if (status !== 'no' && answerable) counts.missedUnannounced++;
      }
      return counts;
    };
    const own = summary(this.store.get('members', a.personId));
    const people = a.role === 'admin' ? this.store.all('members').filter(m => m.active).map(m => ({ personId: m.id, name: m.name, ...summary(m) })).sort((x, y) => x.name.localeCompare(y.name, 'de')) : undefined;
    return { since: new Date(since).toISOString(), own, ...(people ? { people } : {}) };
  }
  action(uid, body, requestId) {
    if (!requestId || requestId.length > 150) fail(400, 'Ein gültiger Änderungsschlüssel fehlt.');
    const hash = createHash('sha256').update(JSON.stringify(body)).digest('hex');
    return this.store.transaction(() => {
      const a = this.account(uid);
      const previous = this.store.db.prepare('SELECT hash,result FROM requests WHERE uid=? AND request_id=?').get(uid, requestId);
      if (previous) { if (previous.hash !== hash) fail(409, 'Dieser Änderungsschlüssel wurde bereits für andere Daten benutzt.', 'request_reused'); return JSON.parse(previous.result); }
      const result = { ok: true, ...this.apply(a, body) };
      this.store.db.prepare('INSERT INTO requests VALUES(?,?,?,?,?)').run(uid, requestId, hash, JSON.stringify(result), now());
      this.store.audit(uid, text(body.action), body.eventId ?? body.uid ?? body.id ?? result.id ?? '');
      return result;
    });
  }
  apply(a, b) {
    const s = this.store, admin = () => this.account(a.uid, true);
    switch (b.action) {
      case 'attendance': {
        const e = s.get('events', b.eventId);
        if (!e || !this.canSee(a, e)) fail(404, 'Termin nicht gefunden.');
        if (e.slotPoolId) fail(409, 'Diesen Termin bitte im Terminfinder umbuchen oder freigeben.', 'closed');
        if (e.locked || Date.parse(e.endsAt) < +this.clock()) fail(409, 'Die Rückmeldefrist ist vorbei.', 'closed');
        if (!['yes', 'late', 'no', 'open'].includes(b.status)) fail(400, 'Ungültige Rückmeldung.');
        if (['no', 'open'].includes(b.status) && Date.parse(e.startsAt) - declineCutoffMs <= +this.clock()) fail(409, 'Ab einer Stunde vor Beginn ist keine Absage mehr möglich.', 'closed');
        const previous = s.get('responses', `${e.id}:${a.personId}`)?.status;
        const expectedArrivalAt = b.status === 'late' && b.expectedArrivalAt ? date(b.expectedArrivalAt) : null;
        if (expectedArrivalAt && (expectedArrivalAt <= e.startsAt || expectedArrivalAt >= e.endsAt)) fail(400, 'Die Ankunft muss zwischen Beginn und Ende der Probe liegen.');
        const r = { eventId: e.id, personId: a.personId, status: b.status, expectedArrivalAt, reason: b.status === 'no' ? text(b.reason, 600) : '', updatedAt: now() };
        s.put('responses', `${e.id}:${a.personId}`, r);
        if (b.status === 'no' && previous !== 'no') this.notifyLateDecline(e, a.personId);
        return { response: r };
      }
      case 'absence.create': {
        if (!/^\d{4}-\d{2}-\d{2}$/.test(b.from ?? '') || !/^\d{4}-\d{2}-\d{2}$/.test(b.to ?? '') || b.from > b.to || day(`${b.from}T12:00:00Z`) !== b.from || day(`${b.to}T12:00:00Z`) !== b.to) fail(400, 'Bitte einen gültigen Zeitraum angeben.');
        const entry = { id: id(), personId: a.personId, from: b.from, to: b.to, reason: text(b.reason, 600) };
        s.put('absences', entry.id, entry);
        // Declines written here carry the absence id, so deleting the absence can reopen them.
        // A decline that already exists stays the member's own (with its own reason).
        const declinedEventIds = [];
        for (const e of s.all('events')) {
          if (e.locked || e.slotPoolId || !inAudience(s.get('members', a.personId), e, s) || Date.parse(e.startsAt) - declineCutoffMs <= +this.clock() || day(e.startsAt) < b.from || day(e.startsAt) > b.to) continue;
          if (s.get('responses', `${e.id}:${a.personId}`)?.status === 'no') continue;
          s.put('responses', `${e.id}:${a.personId}`, { eventId: e.id, personId: a.personId, status: 'no', reason: entry.reason, expectedArrivalAt: null, absenceId: entry.id, updatedAt: now() });
          declinedEventIds.push(e.id);
          this.notifyLateDecline(e, a.personId);
        }
        return { id: entry.id, declinedEventIds };
      }
      case 'absence.delete': {
        // An absence that is already gone counts as deleted; `reopen` withdraws the declines it wrote.
        const x = s.get('absences', b.id);
        if (x && x.personId !== a.personId) fail(404, 'Abwesenheit nicht gefunden.');
        if (x) s.delete('absences', b.id);
        if (b.reopen !== true) return {};
        const reopenedEventIds = [];
        if (x) for (const r of s.all('responses').filter(r => r.personId === a.personId && r.absenceId === x.id && r.status === 'no')) {
          const e = s.get('events', r.eventId);
          if (!e || e.locked || e.slotPoolId || Date.parse(e.startsAt) - declineCutoffMs <= +this.clock()) continue;
          // Another absence still covering the day keeps the decline, now on its behalf.
          const other = s.all('absences').find(o => o.personId === a.personId && o.from <= day(e.startsAt) && o.to >= day(e.startsAt));
          if (other) { s.put('responses', `${r.eventId}:${a.personId}`, { ...r, reason: other.reason, absenceId: other.id }); continue; }
          s.delete('responses', `${r.eventId}:${a.personId}`); reopenedEventIds.push(r.eventId);
        }
        return { reopenedEventIds };
      }
      case 'settings.reminders': {
        const v = b.value ?? {}, customMinutes = v.customMinutes ?? null;
        if (customMinutes !== null && (!Number.isInteger(customMinutes) || customMinutes < customReminderMinutes.min || customMinutes > customReminderMinutes.max)) fail(400, 'Bitte eine Vorlaufzeit zwischen 15 Minuten und einer Woche wählen.');
        const emailEnabled = v.emailEnabled === undefined ? s.get('reminders', a.personId)?.emailEnabled === true : v.emailEnabled === true;
        if (emailEnabled && (!this.emailEnabled || !a.emailVerified)) fail(409, 'Termin-E-Mails benötigen einen eingerichteten Versand und eine bestätigte E-Mail-Adresse.');
        // Older clients send the whole record without newer keys; those keep their stored value.
        const lateDeclines = v.lateDeclines === undefined ? s.get('reminders', a.personId)?.lateDeclines !== false : v.lateDeclines === true;
        s.put('reminders', a.personId, { dayBefore: v.dayBefore === true, twoHours: v.twoHours === true, changes: v.changes === true, emailEnabled, customMinutes, lateDeclines }); return {};
      }
      case 'account.approve': {
        admin(); const target = s.account(required(b.uid, 'Konto')); const member = s.get('members', Number(b.personId));
        if (!target || target.status !== 'pending' || target.version !== b.version) fail(409, 'Die Kontoanfrage hat sich geändert. Bitte neu laden.', 'version_conflict');
        if (!target.identityReady) fail(409, 'Die E-Mail-Adresse muss zuerst bestätigt werden.');
        if (target.nameProvided === false) fail(409, 'Das Konto muss zuerst einen Namen zur Zuordnung angeben.');
        if (!member?.active) fail(400, 'Bitte eine aktive Person auswählen.');
        if (s.accounts().some(x => x.personId === member.id && x.uid !== target.uid)) fail(409, 'Diese Person ist bereits mit einem Konto verknüpft.');
        if (!['member', 'admin'].includes(b.role)) fail(400, 'Ungültige Berechtigung.');
        s.saveAccount({ ...target, personId: member.id, status: 'approved', role: b.role, approvedBy: a.uid, approvedAt: now(), version: target.version + 1 }); return {};
      }
      case 'account.status': {
        admin(); const target = s.account(b.uid);
        if (!target || target.version !== b.version) fail(409, 'Das Konto hat sich geändert.', 'version_conflict');
        if (target.uid === a.uid) fail(409, 'Den eigenen Zugang hier nicht sperren.');
        if (!['rejected', 'suspended', 'approved'].includes(b.status)) fail(400, 'Ungültiger Kontostatus.');
        if (b.status === 'approved' && (!target.personId || !target.identityReady)) fail(409, 'Das Konto benötigt erst eine bestätigte Identität und Personenzuordnung.');
        if (target.role === 'admin' && target.status === 'approved' && s.accounts().filter(x => x.status === 'approved' && x.role === 'admin').length <= 1) fail(409, 'Der letzte Admin muss erhalten bleiben.');
        s.saveAccount({ ...target, status: b.status, statusChangedAt: now(), version: target.version + 1 }); return {};
      }
      case 'account.reconsider': {
        admin(); const target = s.account(b.uid);
        if (!target || target.version !== b.version) fail(409, 'Das Konto hat sich geändert.', 'version_conflict');
        if (target.status !== 'rejected') fail(409, 'Nur abgelehnte Konten können erneut geprüft werden.');
        const { approvedAt, approvedBy, ...pending } = target;
        s.saveAccount({ ...pending, status: 'pending', personId: null, role: 'member', version: target.version + 1 }); return {};
      }
      case 'profile.save': {
        const m = s.get('members', a.personId);
        if ((m.profileVersion ?? 0) !== b.profileVersion) fail(409, 'Dein Profil wurde inzwischen geändert. Bitte neu laden.', 'version_conflict');
        const avatarId = b.avatarId || null;
        if (avatarId) {
          const image = s.get('media', avatarId);
          if (!image || image.kind !== 'profile' || image.ownerPersonId !== a.personId) fail(403, 'Dieses Profilbild gehört nicht zu deinem Konto.');
        }
        s.put('members', m.id, { ...m, avatarId, tagline: '', profileVersion: (m.profileVersion ?? 0) + 1, version: (m.version ?? 1) + 1 });
        return {};
      }
      case 'member.save': {
        admin(); const memberId = b.id == null ? this.nextPersonId() : Number(b.id), old = s.get('members', memberId);
        if (b.id != null && !old) fail(404, 'Person nicht gefunden.');
        if (old && old.version !== b.version && (old.version ?? 1) !== b.version) fail(409, 'Die Person wurde zwischenzeitlich geändert.', 'version_conflict');
        const name = required(b.name, 'Name');
        if (memberId === a.personId && b.active === false) fail(409, 'Den eigenen Zugang hier nicht deaktivieren.');
        const roleIds = b.roleIds === undefined ? list(old?.roleIds) : [...new Set(list(b.roleIds))];
        if (roleIds.length > 30 || roleIds.some(r => typeof r !== 'string' || !s.get('personRoles', r))) fail(400, 'Bitte gültige Rollen auswählen.');
        s.put('members', memberId, { ...old, id: memberId, name, roleIds, initials: initials(name), active: b.active !== false, version: (old?.version ?? 0) + 1 }); return { id: memberId };
      }
      case 'member.delete': {
        // Linked logins are deleted beforehand via DELETE /admin/accounts/:uid,
        // which also removes the Firebase identity, devices and stored requests.
        admin(); const memberId = Number(b.id), m = s.get('members', memberId);
        if (!m) fail(404, 'Person nicht gefunden.');
        if (memberId === a.personId) fail(409, 'Die eigene Person kann nicht gelöscht werden.');
        if (b.version !== undefined && (m.version ?? 1) !== b.version) fail(409, 'Die Person wurde zwischenzeitlich geändert.', 'version_conflict');
        if (s.accounts().some(x => x.personId === memberId)) fail(409, 'Diese Person ist noch mit einem App-Konto verknüpft. Bitte das Konto zuerst löschen.');
        this.forgetMember(memberId); return {};
      }
      case 'personRole.save': {
        admin(); const roleId = b.id || id(), old = s.get('personRoles', roleId);
        if (b.id && !old) fail(404, 'Rolle nicht gefunden.');
        if (old && old.version !== b.version) fail(409, 'Die Rolle wurde inzwischen geändert.', 'version_conflict');
        const name = required(b.name, 'Rollenname', 60);
        if (s.all('personRoles').some(r => r.id !== roleId && r.name.toLocaleLowerCase('de') === name.toLocaleLowerCase('de'))) fail(409, 'Diese Rolle gibt es bereits.');
        s.put('personRoles', roleId, { id: roleId, name, version: (old?.version ?? 0) + 1 }); return { id: roleId };
      }
      case 'personRole.delete': {
        admin(); const r = s.get('personRoles', b.id);
        if (!r) fail(404, 'Rolle nicht gefunden.');
        if (r.version !== b.version) fail(409, 'Die Rolle wurde inzwischen geändert.', 'version_conflict');
        if (s.all('members').some(m => list(m.roleIds).includes(r.id))) fail(409, 'Diese Rolle ist noch Personen zugeordnet. Bitte die Zuordnungen zuerst entfernen.');
        s.delete('personRoles', r.id); return {};
      }
      case 'poll.save': {
        admin(); const pollId = b.id || id(), old = s.get('polls', pollId);
        if (b.id && (!old || old.deleted)) fail(404, 'Abstimmung nicht gefunden.');
        if (old && old.version !== b.version) fail(409, 'Die Abstimmung wurde inzwischen geändert.', 'version_conflict');
        const labels = list(b.options).map(o => required(o.label, 'Antwort', 200));
        if (labels.length < 2 || labels.length > 12 || new Set(labels.map(x => x.toLocaleLowerCase('de'))).size !== labels.length) fail(400, 'Bitte 2 bis 12 unterschiedliche Antworten eingeben.');
        const hasVotes = old && s.all('pollVotes').some(v => v.pollId === pollId);
        if (hasVotes && JSON.stringify(old.options.map(o => o.label)) !== JSON.stringify(labels)) fail(409, 'Nach der ersten Stimme können die Antworten nicht mehr geändert werden.');
        if (b.anonymous !== undefined && typeof b.anonymous !== 'boolean') fail(400, 'Bitte anonym oder namentlich auswählen.');
        const anonymous = b.anonymous ?? old?.anonymous ?? true;
        if (hasVotes && anonymous !== (old.anonymous !== false)) fail(409, 'Nach der ersten Stimme bleibt die Abstimmung anonym oder namentlich.');
        const closesAt = b.closesAt === undefined ? old?.closesAt ?? null : b.closesAt ? date(b.closesAt) : null;
        if (closesAt && Date.parse(closesAt) <= +this.clock() && Date.parse(closesAt) !== Date.parse(old?.closesAt)) fail(400, 'Das Abstimmungsende muss in der Zukunft liegen.');
        const options = labels.map((label, i) => ({ id: old?.options[i]?.label === label ? old.options[i].id : id(), label }));
        const roleIds = b.roleIds === undefined ? list(old?.roleIds) : this.audience(b.roleIds);
        const personIds = b.personIds === undefined ? list(old?.personIds) : this.invitedPeople(b.personIds, old?.personIds);
        const productionIds = b.productionIds === undefined ? list(old?.productionIds) : this.productionAudience(b.productionIds);
        const poll = s.put('polls', pollId, { id: pollId, title: required(b.title, 'Frage'), description: text(b.description, 3000), roleIds, personIds, productionIds, anonymous, options, closesAt, closed: old?.closed ?? false, createdAt: old?.createdAt ?? now(), version: (old?.version ?? 0) + 1 });
        // A push announces new polls only; `pollId` data opens the poll and has no email mirror.
        const push = b.push === true && !old;
        if (push) this.enqueuePush({ title: `Neue Abstimmung: ${poll.title}`, body: closesAt ? `Abstimmen bis ${berlinDateTime(closesAt)}` : 'Deine Stimme ist gefragt.', data: { pollId }, roleIds, personIds, productionIds });
        return { id: pollId, pushQueued: push && this.pushEnabled };
      }
      case 'poll.vote': {
        const p = s.get('polls', b.pollId);
        if (!p || p.deleted || !this.canSee(a, p)) fail(404, 'Abstimmung nicht gefunden.');
        if (this.pollClosed(p)) fail(409, 'Die Abstimmung ist bereits beendet.', 'closed');
        if (!p.options.some(o => o.id === b.optionId)) fail(400, 'Diese Antwort gehört nicht zur Abstimmung.');
        s.put('pollVotes', `${p.id}:${a.personId}`, { pollId: p.id, personId: a.personId, optionId: b.optionId, updatedAt: now() }); return {};
      }
      case 'poll.close': {
        admin(); const p = s.get('polls', b.id);
        if (!p || p.deleted) fail(404, 'Abstimmung nicht gefunden.');
        if (p.version !== b.version) fail(409, 'Die Abstimmung wurde inzwischen geändert.', 'version_conflict');
        // Reopening drops the deadline unless a new, future one is given.
        const closesAt = b.closed !== false ? p.closesAt : b.closesAt ? date(b.closesAt) : null;
        if (b.closed === false && closesAt && Date.parse(closesAt) <= +this.clock()) fail(400, 'Das Abstimmungsende muss in der Zukunft liegen.');
        s.put('polls', p.id, { ...p, closed: b.closed !== false, closesAt, version: p.version + 1 }); return {};
      }
      case 'poll.delete': {
        // Soft delete, so older snapshots' filters keep working; the votes go for good.
        admin(); const p = s.get('polls', b.id);
        if (!p || p.deleted) return {};
        if (p.version !== b.version) fail(409, 'Die Abstimmung wurde inzwischen geändert.', 'version_conflict');
        s.put('polls', p.id, { ...p, deleted: true, version: p.version + 1 });
        this.forgetPollVotes(p.id); s.delete('nudges', `poll:${p.id}`); return {};
      }
      case 'poll.remindOpen': {
        // Nudges only the addressed people who have not voted yet.
        admin(); if (!this.pushEnabled) fail(409, 'Der Push-Versand ist noch nicht eingerichtet.', 'push_unavailable');
        const p = s.get('polls', b.id); if (!p || p.deleted) fail(404, 'Abstimmung nicht gefunden.');
        if (this.pollClosed(p)) fail(409, 'Die Abstimmung ist bereits beendet.', 'closed');
        this.checkCooldown('poll', p.id);
        const open = this.audienceIds(p).filter(x => !s.get('pollVotes', `${p.id}:${x}`));
        if (!open.length) fail(409, 'Alle haben schon abgestimmt.', 'nothing_open');
        this.enqueuePush({ title: `Abstimmung offen: ${p.title}`, body: p.closesAt ? `Abstimmen bis ${berlinDateTime(p.closesAt)}` : 'Deine Stimme ist gefragt.', data: { pollId: p.id }, recipientPersonIds: open, remindPoll: true });
        return { queued: true, recipients: open.length, lastRemindedAt: this.recordNudge(a, 'poll', p.id, open.length) };
      }
      case 'event.save': {
        admin(); const eventId = b.id || id(), old = s.get('events', eventId);
        if (b.id && !old) fail(404, 'Termin nicht gefunden.');
        if (old?.slotPoolId) fail(409, 'Dieser Termin wird vom Terminfinder verwaltet.', 'closed');
        if (old && (old.version ?? 1) !== b.version) fail(409, 'Der Termin wurde zwischenzeitlich geändert.', 'version_conflict');
        const startsAt = date(b.startsAt), endsAt = date(b.endsAt);
        if (endsAt <= startsAt) fail(400, 'Das Ende muss nach dem Beginn liegen.');
        if (b.productionId && !s.get('productions', b.productionId)) fail(400, 'Produktion nicht gefunden.');
        const sceneIds = [...new Set(list(b.sceneIds).map(String))];
        if (b.productionId && sceneIds.some(x => !s.get('scripts', b.productionId)?.scenes.some(scene => scene.id === x))) fail(400, 'Eine ausgewählte Szene gehört nicht zur Produktion.');
        if (b.type != null && !eventTypes.includes(b.type)) fail(400, 'Unbekannte Terminart.');
        const roleIds = b.roleIds === undefined ? list(old?.roleIds) : this.audience(b.roleIds);
        const personIds = b.personIds === undefined ? list(old?.personIds) : this.invitedPeople(b.personIds, old?.personIds);
        const productionIds = b.productionIds === undefined ? list(old?.productionIds) : this.productionAudience(b.productionIds);
        if (b.repeat != null && old) fail(400, 'Eine Wiederholung lässt sich nur beim Anlegen eines Termins festlegen.');
        if (b.series !== undefined && b.series !== 'following') fail(400, 'Unbekannte Auswahl für die Terminserie.');
        if (b.series === 'following' && !old?.seriesId) fail(400, 'Dieser Termin gehört zu keiner Terminserie.');
        const e = { id: eventId, title: required(b.title, 'Titel'), description: text(b.description ?? old?.description, 5000), startsAt, endsAt, place: text(b.place), type: eventTypes.includes(b.type) ? b.type : 'rehearsal', locked: b.locked === true, productionId: b.productionId || null, sceneIds: b.productionId ? sceneIds : [], roleIds, personIds, productionIds, ...(old?.seriesId ? { seriesId: old.seriesId } : {}), version: (old?.version ?? 0) + 1 };
        if (b.repeat != null) {
          // A series is a set of independent events sharing a seriesId; each is
          // edited on its own later. Every occurrence gets the usual absence
          // declines, but the invitees hear about the series only once: one push
          // (when requested) and one email job, both for the first occurrence
          // with the series summary. Per-occurrence emails would flood inboxes.
          const occurrences = seriesOccurrences(startsAt, endsAt, b.repeat), seriesId = id();
          const events = occurrences.map((o, i) => this.storeEvent({ ...e, id: i ? id() : eventId, ...o, seriesId }));
          const series = { id: seriesId, count: events.length, every: b.repeat.every, until: b.repeat.until };
          const notice = { title: `Neue Terminserie: ${e.title}`, body: seriesSummary(occurrences, b.repeat.every), data: { eventId }, roleIds, personIds, productionIds, newEvent: true, series };
          if (b.push === true) this.enqueuePush({ ...notice, announce: 'new' });
          else this.enqueueEmail(notice);
          return { id: eventId, ids: events.map(x => x.id), pushQueued: b.push === true && this.pushEnabled, pushSkipped: b.push === true && !this.pushEnabled ? 'disabled' : null };
        }
        this.storeEvent(e);
        // An explicit push replaces the automatic change notification; its email mirror keeps the usual rules.
        const near = at => { const until = Date.parse(at) - +this.clock(); return until > 0 && until <= changePushWindowDays * 86400000; };
        const pushSkipped = soon => b.push !== true ? null : !this.pushEnabled ? 'disabled' : soon ? null : 'far_future';
        if (b.series === 'following') {
          // "This and all following": later occurrences take over only the fields changed
          // here, so their own edits survive; times move by the Berlin wall-clock delta.
          const followers = this.seriesFollowers(old, e);
          if (followers.length) {
            const touched = [old.startsAt, startsAt, ...followers.flatMap(x => [x.before.startsAt, x.after.startsAt])];
            // Moving a near event far away still concerns those who expect it soon.
            const soon = touched.some(near);
            const notice = { title: `Terminserie geändert: ${e.title}`, body: `Gilt für ${followers.length + 1} Termine ab ${eventNotificationBody(e)}`, data: { eventId }, roleIds, personIds, productionIds, change: true, soon, series: { id: old.seriesId, count: followers.length + 1 } };
            this.enqueuePush(b.push === true ? { ...notice, announce: 'changed' } : notice);
            return { id: eventId, ids: [eventId, ...followers.map(x => x.after.id)], pushQueued: b.push === true && this.pushEnabled && soon, pushSkipped: pushSkipped(soon) };
          }
        }
        // Moving a near event far away still concerns those who expect it soon.
        const soon = !old || near(old.startsAt) || near(startsAt);
        const kind = old ? { change: true, soon } : { newEvent: true };
        if (b.push === true) this.enqueuePush({ title: `${old ? 'Termin geändert' : 'Neuer Termin'}: ${e.title}`, body: eventNotificationBody(e), data: { eventId }, roleIds, personIds, productionIds, ...kind, announce: old ? 'changed' : 'new' });
        else if (old) this.enqueuePush({ title: `Termin aktualisiert: ${e.title}`, body: eventNotificationBody(e), data: { eventId }, roleIds, personIds, productionIds, change: true, soon });
        else this.enqueueEmail({ data: { eventId }, roleIds, personIds, productionIds, newEvent: true });
        return { id: eventId, ...(b.series === 'following' ? { ids: [eventId] } : {}), pushQueued: b.push === true && this.pushEnabled && soon, pushSkipped: pushSkipped(soon) };
      }
      case 'event.delete': {
        admin(); const e = s.get('events', b.id); if (!e) fail(404, 'Termin nicht gefunden.');
        if (e.slotPoolId) fail(409, 'Dieser Termin wird vom Terminfinder verwaltet.', 'closed');
        if ((e.version ?? 1) !== b.version) fail(409, 'Der Termin wurde zwischenzeitlich geändert.', 'version_conflict');
        if (b.series !== undefined && b.series !== 'following') fail(400, 'Unbekannte Auswahl für die Terminserie.');
        if (b.series !== 'following' || !e.seriesId) {
          this.enqueueEmail({ data: { eventId: e.id }, roleIds: e.roleIds, personIds: e.personIds, productionIds: e.productionIds, cancelled: true, event: cancelledEvent(e) });
          this.removeEvent(e.id);
          return { ids: [e.id] };
        }
        // "This and all following": later occurrences of the series go, too
        // (each was saved independently, so later edits do not protect them).
        const doomed = s.all('events').filter(x => x.seriesId === e.seriesId && !x.slotPoolId && x.startsAt >= e.startsAt).sort((x, y) => x.startsAt.localeCompare(y.startsAt));
        // One cancellation email for the series, naming the next affected date.
        const upcoming = doomed.filter(x => Date.parse(x.endsAt) > +this.clock());
        if (upcoming.length) { const first = upcoming[0]; this.enqueueEmail({ data: { eventId: first.id }, roleIds: first.roleIds, personIds: first.personIds, productionIds: first.productionIds, cancelled: true, event: cancelledEvent(first), ...(upcoming.length > 1 ? { seriesCount: upcoming.length } : {}) }); }
        for (const x of doomed) this.removeEvent(x.id);
        return { ids: doomed.map(x => x.id) };
      }
      case 'checkin.save': {
        admin(); if (!s.get('events', b.eventId)) fail(404, 'Termin nicht gefunden.');
        for (const c of list(b.members)) {
          const memberId = Number(c.id), key = `${b.eventId}:${memberId}`, old = s.get('checkins', key);
          if (!s.get('members', memberId)?.active) fail(400, 'Person nicht verfügbar.');
          if (c.present !== null && typeof c.present !== 'boolean') fail(400, 'Anwesenheit muss da, fehlt oder nicht erfasst sein.');
          if ((old?.version ?? 0) !== (c.version ?? 0)) fail(409, 'Ein Anwesenheitseintrag wurde gleichzeitig geändert. Bitte neu laden.', 'version_conflict');
          s.put('checkins', key, { eventId: b.eventId, personId: memberId, present: c.present, version: (old?.version ?? 0) + 1, updatedAt: now() });
        }
        return {};
      }
      case 'event.script': {
        admin(); const e = s.get('events', b.eventId); if (!e) fail(404, 'Termin nicht gefunden.');
        // Installed older clients do not yet send an event version.
        if (b.version !== undefined && (e.version ?? 1) !== b.version) fail(409, 'Der Termin wurde zwischenzeitlich geändert.', 'version_conflict');
        const doc = b.productionId ? s.get('scripts', b.productionId) : null;
        if (b.productionId && !doc) fail(400, 'Drehbuch nicht gefunden.');
        const sceneIds = [...new Set(list(b.sceneIds).map(String))];
        if (doc && sceneIds.some(x => !doc.scenes.some(scene => scene.id === x))) fail(400, 'Szene nicht gefunden.');
        s.put('events', e.id, { ...e, productionId: b.productionId || null, sceneIds: doc ? sceneIds : [], version: (e.version ?? 1) + 1 }); return {};
      }
      case 'production.archive': {
        admin(); const p = s.get('productions', b.id);
        if (!p) fail(404, 'Produktion nicht gefunden.');
        if ((p.version ?? 1) !== b.version) fail(409, 'Die Produktion wurde zwischenzeitlich geändert.', 'version_conflict');
        if (typeof b.archived !== 'boolean') fail(400, 'Bitte einen gültigen Archivstatus wählen.');
        s.put('productions', p.id, { ...p, archived: b.archived, version: (p.version ?? 1) + 1 });
        return {};
      }
      case 'production.save': {
        admin(); const productionId = b.id || id(), old = s.get('productions', productionId);
        if (b.id && !old) fail(404, 'Produktion nicht gefunden.');
        if (old && (old.version ?? 1) !== b.version) fail(409, 'Die Produktion wurde zwischenzeitlich geändert.', 'version_conflict');
        // Omitted casting or directors stay as they are (casting is edited with production.cast).
        const casting = b.casting === undefined ? { ...old?.casting } : {};
        for (const [roleId, memberId] of Object.entries(b.casting ?? {})) {
          if (!old?.roles.some(r => r.id === roleId)) fail(400, 'Rolle gehört nicht zur Produktion.');
          if (memberId != null && !s.get('members', Number(memberId))?.active) fail(400, 'Besetzte Person nicht verfügbar.');
          if (memberId != null) casting[roleId] = Number(memberId);
        }
        const directors = b.directorMemberIds === undefined ? list(old?.directorMemberIds).map(Number) : list(b.directorMemberIds).map(Number);
        // Crew and other helpers who belong to the production without a script role.
        const memberIds = b.memberIds === undefined ? list(old?.memberIds) : [...new Set(list(b.memberIds).map(Number))];
        if (b.memberIds !== undefined && memberIds.some(m => !s.get('members', m) || (!s.get('members', m).active && !list(old?.memberIds).includes(m)))) fail(400, 'Mitwirkende Person nicht verfügbar.');
        if (b.directorMemberIds !== undefined && directors.some(m => !s.get('members', m)?.active)) fail(400, 'Regieperson nicht verfügbar.');
        const premiereAt = b.premiereAt === undefined ? old?.premiereAt ?? null : b.premiereAt ? date(b.premiereAt) : null;
        s.put('productions', productionId, { ...old, id: productionId, title: required(b.title, 'Titel'), subtitle: text(b.subtitle), premiereAt, createdAt: old?.createdAt ?? now(), roles: old?.roles ?? [], sceneCount: old?.sceneCount ?? 0, revision: old?.revision ?? '', casting, directorMemberIds: [...new Set(directors)], memberIds, ...(old?.memberFunctions ? { memberFunctions: teamFunctions(old.memberFunctions, memberIds) } : {}), version: (old?.version ?? 0) + 1 });
        return { id: productionId };
      }
      case 'production.cast': {
        // Single casting and team changes, so assigning one role neither needs
        // nor overwrites the whole production. A role change may state the
        // person it expects (`previous`) to catch a parallel recasting.
        admin(); const p = s.get('productions', b.id);
        if (!p) fail(404, 'Produktion nicht gefunden.');
        const changes = list(b.changes);
        if (!changes.length || changes.length > 200) fail(400, 'Bitte 1 bis 200 Änderungen angeben.');
        const casting = { ...p.casting }, directors = new Set(list(p.directorMemberIds).map(Number)), memberIds = new Set(list(p.memberIds).map(Number)), functions = { ...p.memberFunctions };
        const person = (value, previously) => {
          const personId = Number(value);
          if (!Number.isInteger(personId) || !s.get('members', personId) || (!s.get('members', personId).active && !previously)) fail(400, 'Person nicht verfügbar.');
          return personId;
        };
        for (const c of changes) {
          if (c?.on !== undefined && typeof c.on !== 'boolean') fail(400, 'Bitte hinzufügen oder entfernen wählen.');
          switch (c?.kind) {
            case 'role': {
              const role = list(p.roles).find(r => r.id === c.roleId) ?? fail(400, 'Rolle gehört nicht zur Produktion.');
              if (c.previous !== undefined && (casting[role.id] ?? null) !== (c.previous == null ? null : Number(c.previous))) fail(409, `Die Rolle „${role.name || role.id}“ wurde inzwischen anders besetzt. Bitte neu laden.`, 'version_conflict');
              if (c.personId == null) delete casting[role.id];
              else casting[role.id] = person(c.personId, casting[role.id] === Number(c.personId));
              break;
            }
            case 'director': {
              const personId = c.on === false ? Number(c.personId) : person(c.personId, directors.has(Number(c.personId)));
              if (c.on === false) directors.delete(personId); else directors.add(personId);
              break;
            }
            case 'member': {
              const personId = c.on === false ? Number(c.personId) : person(c.personId, memberIds.has(Number(c.personId)));
              if (c.on === false) { memberIds.delete(personId); delete functions[personId]; break; }
              memberIds.add(personId);
              if (c.function !== undefined) {
                if (c.function !== null && typeof c.function !== 'string') fail(400, 'Ungültige Funktion.');
                const label = text(c.function ?? '', 60);
                if (label) functions[personId] = label; else delete functions[personId];
              }
              break;
            }
            default: fail(400, 'Unbekannte Besetzungsänderung.');
          }
        }
        s.put('productions', p.id, { ...p, casting, directorMemberIds: [...directors], memberIds: [...memberIds], memberFunctions: teamFunctions(functions, [...memberIds]), version: (p.version ?? 1) + 1 });
        return { ensemble: productionEnsemble(s.get('productions', p.id)) };
      }
      case 'message.send': {
        // A targeted message reaches everyone with one of the roles, in one of the ensembles, plus the people chosen by name.
        admin(); const { target, recipients } = this.messageTarget(b);
        const link = text(b.link, 2000);
        if (link && !/^https?:\/\/[^\s]+$/i.test(link)) fail(400, 'Bitte einen gültigen Link mit https:// angeben.');
        const m = { id: id(), title: required(b.title, 'Betreff'), body: required(b.body, 'Nachricht', 10000), ...(link ? { link, linkLabel: text(b.linkLabel, 80) } : {}), ...target, authorId: a.personId, authorName: s.get('members', a.personId).name, createdAt: now() };
        s.put('messages', m.id, m);
        if (b.push === true) this.enqueuePush({ title: m.title, body: m.body.slice(0, 200), data: { messageId: m.id }, recipientPersonIds: recipients });
        return { id: m.id, pushQueued: b.push === true && this.pushEnabled, recipients: recipients.length };
      }
      case 'message.remind': {
        // Nudges only the recipients who have not opened the message yet.
        admin(); if (!this.pushEnabled) fail(409, 'Der Push-Versand ist noch nicht eingerichtet.', 'push_unavailable');
        const m = s.get('messages', b.id); if (!m) fail(404, 'Mitteilung nicht gefunden.');
        this.checkCooldown('message', m.id);
        const { recipientIds, readerIds } = this.messageReach(m);
        const open = recipientIds.filter(x => !readerIds.includes(x) && x !== m.authorId);
        if (!open.length) fail(409, 'Alle Empfänger haben die Mitteilung schon gelesen.', 'nothing_open');
        this.enqueuePush({ title: `Erinnerung: ${m.title}`, body: m.body.slice(0, 200), data: { messageId: m.id }, recipientPersonIds: open });
        return { queued: true, recipients: open.length, lastRemindedAt: this.recordNudge(a, 'message', m.id, open.length) };
      }
      case 'event.remindOpen': {
        // Nudges only the invited people who have not answered the event yet.
        admin(); if (!this.pushEnabled) fail(409, 'Der Push-Versand ist noch nicht eingerichtet.', 'push_unavailable');
        const e = s.get('events', b.eventId); if (!e) fail(404, 'Termin nicht gefunden.');
        if (e.locked || e.slotPoolId || Date.parse(e.endsAt ?? e.startsAt) < +this.clock()) fail(409, 'Für diesen Termin sind keine Rückmeldungen mehr möglich.', 'closed');
        this.checkCooldown('event', e.id);
        const open = this.audienceIds(e).filter(x => !['yes', 'late', 'no'].includes(s.get('responses', `${e.id}:${x}`)?.status));
        if (!open.length) fail(409, 'Alle Eingeladenen haben sich schon zurückgemeldet.', 'nothing_open');
        this.enqueuePush({ title: `Rückmeldung fehlt: ${e.title}`, body: eventNotificationBody(e), data: { eventId: e.id }, recipientPersonIds: open, remindOpen: true });
        return { queued: true, recipients: open.length, lastRemindedAt: this.recordNudge(a, 'event', e.id, open.length) };
      }
      case 'message.delete': {
        // A message that is already gone counts as deleted.
        admin(); const m = s.get('messages', b.id); if (!m) return {};
        for (const r of s.all('receipts').filter(r => r.messageId === m.id)) s.delete('receipts', `${r.messageId}:${r.personId}`);
        s.delete('messages', m.id); s.delete('nudges', `message:${m.id}`); return {};
      }
      case 'message.readAll': {
        for (const m of s.all('messages').filter(m => this.canReadMessage(a, m))) if (!s.get('receipts', `${m.id}:${a.personId}`)) s.put('receipts', `${m.id}:${a.personId}`, { messageId: m.id, personId: a.personId, readAt: now() });
        return {};
      }
      case 'message.read': {
        // Reading a message deleted meanwhile is done; one that exists but is not addressed stays hidden.
        const m = s.get('messages', b.id); if (!m) return {};
        if (!this.canReadMessage(a, m)) fail(404, 'Mitteilung nicht gefunden.');
        s.put('receipts', `${m.id}:${a.personId}`, { messageId: m.id, personId: a.personId, readAt: now() }); return {};
      }
      case 'comment.save': {
        const doc = s.get('scripts', b.productionId);
        if (!doc || doc.revision !== b.revision || !doc.cues.some(c => c.id === b.cueId)) fail(409, 'Diese Textstelle gehört nicht zur aktuellen Fassung.', 'version_conflict');
        const commentId = b.id || id(), old = s.get('comments', commentId);
        if (b.id && (!old || old.authorId !== a.personId)) fail(403, 'Du kannst nur eigene Kommentare bearbeiten.');
        const comment = { id: commentId, productionId: b.productionId, cueId: b.cueId, revision: b.revision, text: required(b.text, 'Kommentar', 3000), authorId: a.personId, authorName: this.profile(a).displayName, createdAt: old?.createdAt ?? now(), updatedAt: now() };
        s.put('comments', commentId, comment); return { id: commentId };
      }
      case 'comment.delete': { const comment = s.get('comments', b.id); if (!comment || (comment.authorId !== a.personId && a.role !== 'admin')) fail(403, 'Diesen Kommentar kannst du nicht entfernen.'); s.delete('comments', b.id); return {}; }
      case 'slotPool.save': {
        admin(); const poolId = b.id || id(), old = s.get('slotPools', poolId);
        if (b.id && !old) fail(404, 'Terminfinder nicht gefunden.');
        if (old && old.version !== b.version) fail(409, 'Der Terminfinder wurde inzwischen geändert.', 'version_conflict');
        const input = list(b.slots);
        if (!input.length || input.length > 100) fail(400, 'Bitte 1 bis 100 Zeitfenster anlegen.');
        const slots = input.map(x => {
          const startsAt = date(x?.startsAt), endsAt = date(x?.endsAt);
          if (endsAt <= startsAt) fail(400, 'Ein Zeitfenster muss nach seinem Beginn enden.');
          if (!Number.isInteger(x.capacity) || x.capacity < 1 || x.capacity > 50) fail(400, 'Bitte 1 bis 50 Plätze je Zeitfenster angeben.');
          return { id: old?.slots.some(o => o.id === x.id) ? x.id : id(), startsAt, endsAt, capacity: x.capacity };
        }).sort((x, y) => x.startsAt.localeCompare(y.startsAt));
        const bookings = s.all('slotBookings').filter(x => x.poolId === poolId);
        for (const slot of old?.slots ?? []) {
          const booked = bookings.filter(x => x.slotId === slot.id).length, next = slots.find(x => x.id === slot.id);
          if (booked && (!next || next.capacity < booked)) fail(409, 'Gebuchte Zeitfenster bleiben erhalten und behalten genug Plätze.');
        }
        if (b.type != null && !eventTypes.includes(b.type)) fail(400, 'Unbekannte Terminart.');
        const roleIds = b.roleIds === undefined ? list(old?.roleIds) : this.audience(b.roleIds);
        const personIds = b.personIds === undefined ? list(old?.personIds) : this.invitedPeople(b.personIds, old?.personIds);
        const productionIds = b.productionIds === undefined ? list(old?.productionIds) : this.productionAudience(b.productionIds);
        const pool = { id: poolId, title: required(b.title, 'Titel'), description: text(b.description, 3000), place: text(b.place), type: b.type ?? old?.type ?? 'other', roleIds, personIds, productionIds, slots, closed: old?.closed ?? false, createdAt: old?.createdAt ?? now(), version: (old?.version ?? 0) + 1 };
        s.put('slotPools', poolId, pool);
        for (const slot of slots) this.syncSlotEvent(pool, slot);
        if (!old) this.enqueuePush({ title: `Terminfinder: ${pool.title}`, body: 'Bitte wähle dein Zeitfenster.', data: { slotPoolId: poolId }, roleIds, personIds, productionIds });
        // People booked into a future slot hear when its time moves (`slotPoolId` data: no email mirror, own title).
        for (const slot of slots) {
          const before = old?.slots.find(x => x.id === slot.id), booked = bookings.filter(x => x.slotId === slot.id).map(x => x.personId);
          if (before && booked.length && (before.startsAt !== slot.startsAt || before.endsAt !== slot.endsAt) && Date.parse(slot.startsAt) > +this.clock()) this.enqueuePush({ title: `Terminfinder: ${pool.title}`, body: `Zeitfenster verschoben: ${eventNotificationBody({ ...slot, place: pool.place })}`, data: { slotPoolId: poolId }, recipientPersonIds: booked });
        }
        return { id: poolId };
      }
      case 'slotPool.close': {
        admin(); const pool = s.get('slotPools', b.id);
        if (!pool) fail(404, 'Terminfinder nicht gefunden.');
        if (pool.version !== b.version) fail(409, 'Der Terminfinder wurde inzwischen geändert.', 'version_conflict');
        s.put('slotPools', pool.id, { ...pool, closed: b.closed !== false, version: pool.version + 1 }); return {};
      }
      case 'slotPool.delete': {
        admin(); const pool = s.get('slotPools', b.id);
        if (!pool) fail(404, 'Terminfinder nicht gefunden.');
        if (pool.version !== b.version) fail(409, 'Der Terminfinder wurde inzwischen geändert.', 'version_conflict');
        const bookings = s.all('slotBookings').filter(x => x.poolId === pool.id);
        // Future bookings are cancelled with a notice; the pool is gone, so there is no deep link.
        for (const slot of pool.slots.filter(x => Date.parse(x.startsAt) > +this.clock())) {
          const booked = bookings.filter(x => x.slotId === slot.id).map(x => x.personId);
          if (booked.length) this.enqueuePush({ title: `Terminfinder entfällt: ${pool.title}`, body: `Dein Zeitfenster entfällt: ${eventNotificationBody({ ...slot, place: pool.place })}`, data: {}, recipientPersonIds: booked });
        }
        for (const x of bookings) s.delete('slotBookings', `${pool.id}:${x.personId}`);
        for (const slot of pool.slots) this.syncSlotEvent(pool, slot);
        s.delete('slotPools', pool.id); s.delete('nudges', `slotPool:${pool.id}`); return {};
      }
      case 'slotPool.remindOpen': {
        // Nudges invitees without a booking while a future slot is still free.
        admin(); if (!this.pushEnabled) fail(409, 'Der Push-Versand ist noch nicht eingerichtet.', 'push_unavailable');
        const pool = s.get('slotPools', b.id); if (!pool) fail(404, 'Terminfinder nicht gefunden.');
        const bookings = s.all('slotBookings').filter(x => x.poolId === pool.id);
        if (pool.closed || !pool.slots.some(x => Date.parse(x.startsAt) > +this.clock() && bookings.filter(y => y.slotId === x.id).length < x.capacity)) fail(409, 'In diesem Terminfinder ist kein freies Zeitfenster mehr buchbar.', 'closed');
        this.checkCooldown('slotPool', pool.id);
        const open = this.audienceIds(pool).filter(x => !bookings.some(y => y.personId === x));
        if (!open.length) fail(409, 'Alle Eingeladenen haben schon ein Zeitfenster gebucht.', 'nothing_open');
        this.enqueuePush({ title: `Terminfinder: ${pool.title}`, body: 'Bitte wähle noch dein Zeitfenster.', data: { slotPoolId: pool.id }, recipientPersonIds: open, remindSlot: true });
        return { queued: true, recipients: open.length, lastRemindedAt: this.recordNudge(a, 'slotPool', pool.id, open.length) };
      }
      case 'slot.book': case 'slot.cancel': {
        const pool = s.get('slotPools', b.poolId);
        if (!pool || !inAudience(s.get('members', a.personId), pool, s)) fail(404, 'Terminfinder nicht gefunden.');
        if (pool.closed) fail(409, 'Die Buchung ist geschlossen.', 'closed');
        const own = s.get('slotBookings', `${pool.id}:${a.personId}`), ownSlot = pool.slots.find(x => x.id === own?.slotId);
        if (ownSlot && Date.parse(ownSlot.startsAt) <= +this.clock()) fail(409, 'Dein Zeitfenster hat schon begonnen.', 'closed');
        this.bookSlot(pool, a.personId, b.action === 'slot.book' ? required(b.slotId, 'Zeitfenster') : null); return {};
      }
      case 'slot.assign': {
        admin(); const pool = s.get('slotPools', b.poolId), personId = Number(b.personId);
        if (!pool) fail(404, 'Terminfinder nicht gefunden.');
        if (!s.get('members', personId)?.active && b.slotId !== null) fail(400, 'Person nicht verfügbar.');
        const before = s.get('slotBookings', `${pool.id}:${personId}`)?.slotId ?? null, beforeSlot = pool.slots.find(x => x.id === before);
        this.bookSlot(pool, personId, b.slotId === null ? null : required(b.slotId, 'Zeitfenster'));
        // The person hears about an admin's change to their future slot; their own changes stay quiet.
        const after = s.get('slotBookings', `${pool.id}:${personId}`)?.slotId ?? null, slot = pool.slots.find(x => x.id === after);
        let push = null;
        if (personId !== a.personId && after !== before) {
          if (slot) push = `Du bist eingeteilt: ${eventNotificationBody({ ...slot, place: pool.place })}`;
          else if (beforeSlot && Date.parse(beforeSlot.startsAt) > +this.clock()) push = 'Dein Zeitfenster wurde freigegeben.';
        }
        if (push) this.enqueuePush({ title: `Terminfinder: ${pool.title}`, body: push, data: { slotPoolId: pool.id }, recipientPersonIds: [personId] });
        return { pushQueued: !!push && this.pushEnabled };
      }
      case 'email.test': { if (!this.emailEnabled || !a.emailVerified) fail(409, 'Der E-Mail-Versand benötigt eine bestätigte Anmeldeadresse.'); this.enqueueEmail({ test: true, data: {}, recipientPersonIds: [a.personId] }); return { queued: true }; }
      case 'push.send': {
        // An on-demand push without a stored message, e.g. "Probe fällt aus, Details folgen".
        admin(); if (!this.pushEnabled) fail(409, 'Der Push-Versand ist noch nicht eingerichtet.', 'push_unavailable');
        const title = required(b.title, 'Titel', 120), body = required(b.body, 'Text', 500);
        const { recipients } = this.messageTarget(b);
        const reached = new Set(s.accounts().filter(x => x.status === 'approved' && recipients.includes(x.personId)).map(x => x.uid));
        this.enqueuePush({ title, body, data: {}, recipientPersonIds: recipients, manual: true, authorName: s.get('members', a.personId)?.name ?? a.name });
        return { queued: true, recipients: recipients.length, withDevice: new Set(s.all('devices').filter(d => reached.has(d.uid)).map(d => d.uid)).size };
      }
      case 'push.test': { if (!this.pushEnabled) fail(409, 'Der Push-Versand ist noch nicht eingerichtet.', 'push_unavailable'); this.enqueuePush({ title: 'Theater-App', body: 'Deine Testbenachrichtigung ist da.', data: {}, recipientPersonIds: [a.personId] }); return { queued: true }; }
      default: fail(400, 'Diese Aktion wird nicht unterstützt.');
    }
  }
  importScript(uid, production, document) {
    this.account(uid, true);
    if (!production?.id || !document?.revision || !Array.isArray(document.cues) || !Array.isArray(document.scenes) || !Array.isArray(document.roles)) fail(400, 'Ungültiges Drehbuch.');
    return this.store.transaction(() => {
      const old = this.store.get('productions', production.id);
      this.store.put('productions', production.id, { ...production, archived: old?.archived === true, premiereAt: old?.premiereAt ?? (production.premiereAt ? date(production.premiereAt) : null), createdAt: old?.createdAt ?? now(), roles: document.roles, sceneCount: document.scenes.length, revision: document.revision, casting: Object.fromEntries(Object.entries(old?.casting ?? {}).filter(([role]) => document.roles.some(r => r.id === role))), directorMemberIds: old?.directorMemberIds ?? [], ...(old?.memberIds ? { memberIds: old.memberIds } : {}), ...(old?.memberFunctions ? { memberFunctions: old.memberFunctions } : {}), version: (old?.version ?? 0) + 1 });
      this.store.put('scripts', production.id, document);
      this.store.delete('focus', production.id);
      this.store.audit(uid, 'script.import', production.id);
      return { ok: true, id: production.id, sceneCount: document.scenes.length, cueCount: document.cues.length };
    });
  }
  focus(uid, productionId, body = null) {
    const a = this.account(uid), p = this.store.get('productions', productionId), doc = this.store.get('scripts', productionId);
    if (!p || !doc) fail(404, 'Produktion nicht gefunden.');
    const current = this.store.get('focus', productionId) ?? { productionId, revision: doc.revision, sequence: 0, cueId: null, director: null };
    const canDirect = a.role === 'admin' || list(p.directorMemberIds).includes(a.personId);
    if (!body) return { ...current, canDirect };
    if (a.role !== 'admin' && !list(p.directorMemberIds).includes(a.personId)) fail(403, 'Du hast keine Regieberechtigung für dieses Stück.');
    if (body.revision !== doc.revision) fail(409, 'Die Drehbuchfassung hat sich geändert.', 'version_conflict');
    if (body.cueId != null && !doc.cues.some(c => c.id === body.cueId)) fail(400, 'Textstelle nicht gefunden.');
    if (body.sequence != null && body.sequence !== current.sequence) fail(409, 'Die Regiemarkierung wurde zwischenzeitlich geändert.', 'version_conflict');
    const cue = doc.cues.find(c => c.id === body.cueId);
    return { ...this.store.put('focus', productionId, { productionId, revision: doc.revision, sequence: current.sequence + 1, cueId: body.cueId ?? null, cueOrdinal: cue?.ordinal ?? null, sceneId: cue?.sceneId ?? null, updatedBy: uid, director: { id: uid, name: this.profile(a).displayName }, updatedAt: now() }), canDirect };
  }
  device(uid, token, platform, remove = false, notificationActions = false) {
    this.account(uid); if (typeof token !== 'string' || token.length < 20 || token.length > 4096) fail(400, 'Ungültiges Gerätetoken.');
    const key = createHash('sha256').update(token).digest('hex');
    if (remove) { if (this.store.get('devices', key)?.uid === uid) this.store.delete('devices', key); }
    else { if (!['android', 'ios', 'web'].includes(platform)) fail(400, 'Ungültige Plattform.'); this.store.put('devices', key, { id: key, uid, token, platform, notificationActions: platform === 'android' && notificationActions === true, updatedAt: now() }); }
    return { ok: true, pushEnabled: this.pushEnabled };
  }
  /** Saves an event and settles its responses: arrivals outside the new time are cleared, absences decline. */
  storeEvent(e) {
    const s = this.store, eventId = e.id;
    s.put('events', eventId, e);
    for (const r of s.all('responses').filter(r => r.eventId === eventId && r.expectedArrivalAt && (r.expectedArrivalAt <= e.startsAt || r.expectedArrivalAt >= e.endsAt))) s.put('responses', `${eventId}:${r.personId}`, { ...r, expectedArrivalAt: null });
    for (const absence of s.all('absences')) if (inAudience(s.get('members', absence.personId), e, s) && absence.from <= day(e.startsAt) && absence.to >= day(e.startsAt) && !s.get('responses', `${eventId}:${absence.personId}`)) s.put('responses', `${eventId}:${absence.personId}`, { eventId, personId: absence.personId, status: 'no', expectedArrivalAt: null, reason: absence.reason, absenceId: absence.id, updatedAt: now() });
    return e;
  }
  /**
   * Later, not yet ended occurrences of the series take over the fields changed from `old` to `e`.
   * Times move by the Europe/Berlin wall-clock delta (days and minutes), so DST switches keep the time.
   */
  seriesFollowers(old, e) {
    const s = this.store, at = +this.clock();
    const changed = seriesFields.filter(f => !sameValue(f, old[f], e[f]));
    const shift = (from, to) => {
      const x = berlinParts(Date.parse(from)), y = berlinParts(Date.parse(to));
      return { days: Math.round((Date.UTC(y.y, y.m, y.d) - Date.UTC(x.y, x.m, x.d)) / 86400000), minutes: y.h * 60 + y.mi - (x.h * 60 + x.mi) };
    };
    const move = (value, { days, minutes }) => { const p = berlinParts(Date.parse(value)); return new Date(fromBerlin({ ...p, d: p.d + days, h: 0, mi: p.h * 60 + p.mi + minutes })).toISOString(); };
    const start = shift(old.startsAt, e.startsAt), end = shift(old.endsAt, e.endsAt), retime = start.days || start.minutes || end.days || end.minutes;
    // Nothing to take over: the following occurrences keep their versions and nobody hears of a series change.
    if (!changed.length && !retime) return [];
    return s.all('events').filter(x => x.seriesId === old.seriesId && x.id !== e.id && !x.slotPoolId && Date.parse(x.startsAt) > Date.parse(old.startsAt) && Date.parse(x.endsAt) > at)
      .sort((x, y) => x.startsAt.localeCompare(y.startsAt)).map(before => {
        const next = { ...before, version: (before.version ?? 1) + 1 };
        for (const f of changed) next[f] = e[f];
        if (changed.includes('productionId')) next.sceneIds = [];
        if (retime) {
          next.startsAt = move(before.startsAt, start); next.endsAt = move(before.endsAt, end);
          if (next.endsAt <= next.startsAt) next.endsAt = new Date(Date.parse(next.startsAt) + Date.parse(e.endsAt) - Date.parse(e.startsAt)).toISOString();
        }
        return { before, after: this.storeEvent(next) };
      });
  }
  /** Tells admins and the production's directors when someone cancels within a day of the start; once per person and start time. */
  notifyLateDecline(e, personId) {
    const s = this.store, until = Date.parse(e.startsAt) - +this.clock();
    if (!this.pushEnabled || until <= 0 || until > lateDeclineWindowMs) return;
    const key = `${e.id}:${e.startsAt}:${personId}:lateDecline`;
    if (s.get('reminderSent', key)) return;
    const directors = list(s.get('productions', e.productionId)?.directorMemberIds).map(Number);
    const recipients = [...new Set([...s.accounts().filter(x => x.status === 'approved' && x.role === 'admin' && x.personId != null).map(x => x.personId), ...directors])]
      .filter(x => x !== personId && s.get('reminders', x)?.lateDeclines !== false);
    if (!recipients.length) return;
    // Never the reason: it may be health information on a lock screen.
    this.enqueuePush({ title: `Kurzfristige Absage: ${e.title}`, body: `${s.get('members', personId)?.name ?? 'Jemand'} kommt nicht · ${eventNotificationBody(e)}`, data: { eventId: e.id }, recipientPersonIds: recipients, fixedText: true, email: false });
    s.put('reminderSent', key, { at: now() });
  }
  forgetPollVotes(pollId) { this.store.db.prepare("DELETE FROM entities WHERE kind = 'pollVotes' AND json_extract(data, '$.pollId') = ?").run(pollId); }
  removeEvent(eventId) {
    const s = this.store;
    s.delete('events', eventId); s.delete('nudges', `event:${eventId}`);
    for (const kind of ['responses', 'checkins']) for (const item of s.all(kind).filter(x => x.eventId === eventId)) s.delete(kind, `${item.eventId}:${item.personId}`);
  }
  /**
   * Deletes a person with their personal data and every reference to them.
   * Anything addressed to them alone goes, too: emptied audiences would otherwise mean "everyone".
   * Anonymous poll votes stay without a person; named votes, comments and receipts are removed.
   * Queued push/email jobs keep their recipient lists; delivery only reaches existing accounts.
   */
  forgetMember(personId) {
    const s = this.store, others = ids => list(ids).filter(x => Number(x) !== personId);
    const named = item => list(item.personIds).some(x => Number(x) === personId);
    const onlyThem = item => !list(item.roleIds).length && !list(item.productionIds).length && !others(item.personIds).length;
    const removeBookings = (pool, keep = () => false) => {
      for (const x of s.all('slotBookings').filter(x => x.poolId === pool.id && !keep(x))) {
        s.delete('slotBookings', `${pool.id}:${x.personId}`);
        const slot = pool.slots.find(slot => slot.id === x.slotId);
        if (slot) this.syncSlotEvent(pool, slot);
      }
    };
    for (const pool of s.all('slotPools')) {
      if (!named(pool)) { removeBookings(pool, x => x.personId !== personId); continue; }
      if (onlyThem(pool)) { removeBookings(pool); s.delete('slotPools', pool.id); s.delete('nudges', `slotPool:${pool.id}`); continue; }
      s.put('slotPools', pool.id, { ...pool, personIds: others(pool.personIds), version: pool.version + 1 });
      removeBookings(pool, x => x.personId !== personId);
    }
    for (const e of s.all('events').filter(named)) {
      if (onlyThem(e)) this.removeEvent(e.id);
      else s.put('events', e.id, { ...e, personIds: others(e.personIds), version: (e.version ?? 1) + 1 });
    }
    for (const p of s.all('polls').filter(named)) {
      if (onlyThem(p)) { this.forgetPollVotes(p.id); s.delete('polls', p.id); s.delete('nudges', `poll:${p.id}`); }
      else s.put('polls', p.id, { ...p, personIds: others(p.personIds), version: p.version + 1 });
    }
    for (const v of s.all('pollVotes').filter(v => v.personId === personId)) {
      s.delete('pollVotes', `${v.pollId}:${personId}`);
      const p = s.get('polls', v.pollId);
      // Anonymous results keep their counts; a named vote cannot exist without the name.
      if (p && p.anonymous !== false) s.put('pollVotes', `${v.pollId}:former-${id()}`, { pollId: v.pollId, personId: null, optionId: v.optionId });
    }
    for (const m of s.all('messages')) {
      const author = m.authorId === personId;
      if (!author && !list(m.recipientPersonIds).includes(personId)) continue;
      const next = { ...m, recipientPersonIds: others(m.recipientPersonIds), ...(author ? { authorId: null, authorName: 'Ehemaliges Mitglied' } : {}) };
      if (m.audience === 'all' || !onlyThem({ ...next, personIds: next.recipientPersonIds })) { s.put('messages', m.id, next); continue; }
      for (const r of s.all('receipts').filter(r => r.messageId === m.id)) s.delete('receipts', `${r.messageId}:${r.personId}`);
      s.delete('messages', m.id); s.delete('nudges', `message:${m.id}`);
    }
    for (const p of s.all('productions')) {
      const casting = Object.fromEntries(Object.entries(p.casting ?? {}).filter(([, x]) => Number(x) !== personId));
      const directorMemberIds = others(p.directorMemberIds), memberIds = others(p.memberIds);
      if (Object.keys(casting).length === Object.keys(p.casting ?? {}).length && directorMemberIds.length === list(p.directorMemberIds).length && memberIds.length === list(p.memberIds).length) continue;
      s.put('productions', p.id, { ...p, casting, directorMemberIds, memberIds, ...(p.memberFunctions ? { memberFunctions: teamFunctions(p.memberFunctions, memberIds) } : {}), version: (p.version ?? 1) + 1 });
    }
    for (const kind of ['responses', 'checkins']) for (const x of s.all(kind).filter(x => x.personId === personId)) s.delete(kind, `${x.eventId}:${personId}`);
    for (const r of s.all('receipts').filter(r => r.personId === personId)) s.delete('receipts', `${r.messageId}:${personId}`);
    for (const x of s.all('absences').filter(x => x.personId === personId)) s.delete('absences', x.id);
    for (const c of s.all('comments').filter(c => c.authorId === personId)) s.delete('comments', c.id);
    // Reminder keys are `${eventId}:${startsAt}:${personId}:${kind}`; startsAt contains colons itself.
    for (const { id: key } of s.db.prepare("SELECT id FROM entities WHERE kind = 'reminderSent'").all()) if (key.split(':').at(-2) === String(personId)) s.delete('reminderSent', key);
    s.delete('reminders', personId);
    for (const { id: key, data } of s.db.prepare("SELECT id, data FROM entities WHERE kind = 'nudges'").all()) { const n = JSON.parse(data); if (n.by === personId) s.put('nudges', key, { ...n, by: null }); }
    // An orphaned profile image is purged by the retention job (it also removes the file).
    for (const m of s.all('media').filter(m => m.ownerPersonId === personId)) s.put('media', m.id, { ...m, ownerPersonId: null });
    s.delete('members', personId);
    s.put('settings', 'lastPersonId', { id: Math.max(personId, s.get('settings', 'lastPersonId')?.id ?? 0) });
  }
  enqueuePush(message) {
    // Event jobs are mirrored to email unless they opt out (`email: false`).
    if (message.data?.eventId && message.email !== false) this.enqueueEmail(message);
    if (!this.pushEnabled) return;
    const job = { id: id(), ...message, attempts: 0, status: 'pending', createdAt: now(), nextAttemptAt: now() };
    this.store.put('pushJobs', job.id, job);
  }
  enqueueEmail(message) {
    if (!this.emailEnabled) return;
    const eventVersion = this.store.get('events', message.data?.eventId)?.version;
    const job = { id: id(), ...message, ...(eventVersion !== undefined ? { eventVersion } : {}), attempts: 0, status: 'pending', createdAt: now(), nextAttemptAt: now() };
    this.store.put('emailJobs', job.id, job);
  }
}
