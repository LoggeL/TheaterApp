import { createHash, randomUUID } from 'node:crypto';

export class AppError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
const fail = (status, message) => { throw new AppError(status, message); };
const text = (value, max = 250) => typeof value === 'string' ? value.trim().slice(0, max) : '';
const required = (value, label, max) => text(value, max) || fail(400, `${label} fehlt.`);
const now = () => new Date().toISOString();
const day = value => new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Berlin' }).format(new Date(value));
const date = value => typeof value === 'string' && Number.isFinite(Date.parse(value)) ? new Date(value).toISOString() : fail(400, 'Ungültige Zeitangabe.');
const id = () => randomUUID();
const list = value => Array.isArray(value) ? value : [];
const initials = name => name.split(/\s+/).filter(Boolean).slice(0, 2).map(n => n[0]).join('').toUpperCase();

export class Theater {
  constructor(store, { bootstrapEmail = '', pushEnabled = false, clock = () => new Date() } = {}) {
    this.store = store; this.bootstrapEmail = bootstrapEmail.trim().toLowerCase(); this.pushEnabled = pushEnabled; this.clock = clock;
  }
  session(identity) {
    return this.store.transaction(() => {
      let a = this.store.account(identity.uid);
      const provider = identity.firebase?.sign_in_provider ?? 'password';
      const identityReady = provider !== 'password' || identity.email_verified === true;
      const fields = { name: text(identity.name) || text(identity.email).split('@')[0] || 'Neues Konto', email: text(identity.email), emailVerified: identity.email_verified === true, identityReady, provider, lastSeenAt: now() };
      a = a ? { ...a, ...fields } : { uid: identity.uid, personId: null, status: 'pending', role: 'member', createdAt: now(), version: 1, ...fields };
      if (!this.store.get('settings', 'bootstrap') && this.bootstrapEmail && a.email.toLowerCase() === this.bootstrapEmail && a.emailVerified && this.store.accounts().every(x => x.role !== 'admin')) {
        const personId = this.nextPersonId();
        this.store.put('members', personId, { id: personId, name: a.name, group: 'Theaterleitung', initials: initials(a.name), active: true });
        a = { ...a, personId, status: 'approved', role: 'admin', approvedAt: now(), approvedBy: 'bootstrap' };
        this.store.put('settings', 'bootstrap', { uid: a.uid, at: now() });
        this.store.audit('bootstrap', 'account.approve', a.uid);
      }
      this.store.saveAccount(a);
      return this.profile(a);
    });
  }
  profile(a) {
    const m = a.personId == null ? null : this.store.get('members', a.personId);
    return { userId: a.uid, displayName: m?.name ?? a.name, email: a.email, role: a.role, group: m?.group ?? '', personId: a.personId, status: a.status, emailVerified: a.emailVerified, identityReady: a.identityReady, provider: a.provider, mustChangePassword: false, directorProductionIds: this.store.all('productions').filter(p => list(p.directorMemberIds).includes(a.personId)).map(p => p.id) };
  }
  account(uid, admin = false) {
    const a = this.store.account(uid);
    if (!a || a.status !== 'approved' || !a.personId || !a.identityReady || this.store.get('members', a.personId)?.active !== true) fail(403, 'Dein Theaterzugang ist noch nicht freigegeben oder wurde gesperrt.');
    if (admin && a.role !== 'admin') fail(403, 'Hierfür ist ein Admin-Zugang erforderlich.');
    return a;
  }
  nextPersonId() { return Math.max(0, ...this.store.all('members').map(m => m.id)) + 1; }
  snapshot(uid) {
    const a = this.account(uid); const admin = a.role === 'admin';
    const responses = this.store.all('responses');
    const events = this.store.all('events').map(e => ({ ...e, eventDate: day(e.startsAt), people: responses.filter(r => r.eventId === e.id && ['yes', 'late'].includes(r.status)).length }));
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
    return { apiVersion: 1, user: this.profile(a), events, attendanceByEvent: Object.fromEntries(own.map(r => [r.eventId, r.status])), declineReasons: Object.fromEntries(own.map(r => [r.eventId, r.reason])), expectedArrivals: Object.fromEntries(own.map(r => [r.eventId, r.expectedArrivalAt])), absences: this.store.all('absences').filter(x => x.personId === a.personId), polls: [], members: this.store.all('members'), productions: this.store.all('productions'), checkinsByEvent, memberAttendanceByEvent, arrivalsByEvent, checkinVersions: admin ? Object.fromEntries(this.store.all('checkins').map(c => [`${c.eventId}:${c.personId}`, c.version])) : {}, reminders: this.store.get('reminders', a.personId) ?? { dayBefore: true, twoHours: true, changes: true }, messages: this.store.all('messages').filter(m => this.canReadMessage(a, m)).map(m => ({ ...m, read: receipts.some(r => r.messageId === m.id) })).sort((x, y) => y.createdAt.localeCompare(x.createdAt)), pendingAccounts: admin ? this.store.accounts().filter(x => x.status === 'pending') : [], capabilities: { pushConfigured: this.pushEnabled, firebaseAuth: true, checkins: true, admin: true, sampleData: this.store.get('settings', 'sampleData')?.enabled === true }, serverTime: now() };
  }
  canReadMessage(a, m) { return a.role === 'admin' || m.audience === 'all' || list(m.recipientPersonIds).includes(a.personId); }
  script(uid, productionId) {
    this.account(uid);
    const p = this.store.get('productions', productionId), doc = this.store.get('scripts', productionId);
    if (!p || !doc) fail(404, 'Das Drehbuch ist nicht verfügbar.');
    return { ...doc, roles: doc.roles.map(r => { const personId = p.casting?.[r.id]; const member = this.store.get('members', personId); return { ...r, personId: personId ?? null, actor: member?.name ?? r.actor ?? '' }; }), fetchedAt: now(), stale: false };
  }
  adminData(uid) { this.account(uid, true); return { accounts: this.store.accounts(), members: this.store.all('members'), productions: this.store.all('productions') }; }
  eventDetails(uid, eventId) {
    this.account(uid, true);
    if (!this.store.get('events', eventId)) fail(404, 'Termin nicht gefunden.');
    return { responses: this.store.all('responses').filter(r => r.eventId === eventId), checkins: this.store.all('checkins').filter(r => r.eventId === eventId), absences: this.store.all('absences').filter(x => { const d = day(this.store.get('events', eventId).startsAt); return x.from <= d && x.to >= d; }) };
  }
  action(uid, body, requestId) {
    if (!requestId || requestId.length > 150) fail(400, 'Ein gültiger Änderungsschlüssel fehlt.');
    const hash = createHash('sha256').update(JSON.stringify(body)).digest('hex');
    return this.store.transaction(() => {
      const a = this.account(uid);
      const previous = this.store.db.prepare('SELECT hash,result FROM requests WHERE uid=? AND request_id=?').get(uid, requestId);
      if (previous) { if (previous.hash !== hash) fail(409, 'Dieser Änderungsschlüssel wurde bereits für andere Daten benutzt.'); return JSON.parse(previous.result); }
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
        if (!e) fail(404, 'Termin nicht gefunden.');
        if (e.locked || Date.parse(e.endsAt) < +this.clock()) fail(409, 'Die Rückmeldefrist ist vorbei.');
        if (!['yes', 'late', 'no', 'open'].includes(b.status)) fail(400, 'Ungültige Rückmeldung.');
        const expectedArrivalAt = b.status === 'late' && b.expectedArrivalAt ? date(b.expectedArrivalAt) : null;
        if (expectedArrivalAt && (expectedArrivalAt <= e.startsAt || expectedArrivalAt >= e.endsAt)) fail(400, 'Die Ankunft muss zwischen Beginn und Ende der Probe liegen.');
        const r = { eventId: e.id, personId: a.personId, status: b.status, expectedArrivalAt, reason: b.status === 'no' ? text(b.reason, 600) : '', updatedAt: now() };
        s.put('responses', `${e.id}:${a.personId}`, r); return { response: r };
      }
      case 'absence.create': {
        if (!/^\d{4}-\d{2}-\d{2}$/.test(b.from ?? '') || !/^\d{4}-\d{2}-\d{2}$/.test(b.to ?? '') || b.from > b.to || day(`${b.from}T12:00:00Z`) !== b.from || day(`${b.to}T12:00:00Z`) !== b.to) fail(400, 'Bitte einen gültigen Zeitraum angeben.');
        const entry = { id: id(), personId: a.personId, from: b.from, to: b.to, reason: text(b.reason, 600) };
        s.put('absences', entry.id, entry);
        for (const e of s.all('events')) if (!e.locked && Date.parse(e.endsAt) >= +this.clock() && day(e.startsAt) >= b.from && day(e.startsAt) <= b.to) s.put('responses', `${e.id}:${a.personId}`, { eventId: e.id, personId: a.personId, status: 'no', reason: entry.reason, expectedArrivalAt: null, updatedAt: now() });
        return { id: entry.id };
      }
      case 'absence.delete': { const x = s.get('absences', b.id); if (!x || x.personId !== a.personId) fail(404, 'Abwesenheit nicht gefunden.'); s.delete('absences', b.id); return {}; }
      case 'settings.reminders': { const v = b.value ?? {}; s.put('reminders', a.personId, { dayBefore: v.dayBefore === true, twoHours: v.twoHours === true, changes: v.changes === true }); return {}; }
      case 'account.approve': {
        admin(); const target = s.account(required(b.uid, 'Konto')); const member = s.get('members', Number(b.personId));
        if (!target || target.status !== 'pending' || target.version !== b.version) fail(409, 'Die Kontoanfrage hat sich geändert. Bitte neu laden.');
        if (!target.identityReady) fail(409, 'Die E-Mail-Adresse muss zuerst bestätigt werden.');
        if (!member?.active) fail(400, 'Bitte eine aktive Person auswählen.');
        if (s.accounts().some(x => x.personId === member.id && x.uid !== target.uid)) fail(409, 'Diese Person ist bereits mit einem Konto verknüpft.');
        if (!['member', 'admin'].includes(b.role)) fail(400, 'Ungültige Berechtigung.');
        s.saveAccount({ ...target, personId: member.id, status: 'approved', role: b.role, approvedBy: a.uid, approvedAt: now(), version: target.version + 1 }); return {};
      }
      case 'account.status': {
        admin(); const target = s.account(b.uid);
        if (!target || target.version !== b.version) fail(409, 'Das Konto hat sich geändert.');
        if (target.uid === a.uid) fail(409, 'Den eigenen Zugang hier nicht sperren.');
        if (!['rejected', 'suspended', 'approved'].includes(b.status)) fail(400, 'Ungültiger Kontostatus.');
        if (b.status === 'approved' && (!target.personId || !target.identityReady)) fail(409, 'Das Konto benötigt erst eine bestätigte Identität und Personenzuordnung.');
        if (target.role === 'admin' && target.status === 'approved' && s.accounts().filter(x => x.status === 'approved' && x.role === 'admin').length <= 1) fail(409, 'Der letzte Admin muss erhalten bleiben.');
        s.saveAccount({ ...target, status: b.status, version: target.version + 1 }); return {};
      }
      case 'member.save': {
        admin(); const memberId = b.id == null ? this.nextPersonId() : Number(b.id), old = s.get('members', memberId);
        if (b.id != null && !old) fail(404, 'Person nicht gefunden.');
        if (old && old.version !== b.version && (old.version ?? 1) !== b.version) fail(409, 'Die Person wurde zwischenzeitlich geändert.');
        const name = required(b.name, 'Name');
        if (memberId === a.personId && b.active === false) fail(409, 'Den eigenen Zugang hier nicht deaktivieren.');
        s.put('members', memberId, { id: memberId, name, group: text(b.group), initials: initials(name), active: b.active !== false, version: (old?.version ?? 0) + 1 }); return { id: memberId };
      }
      case 'event.save': {
        admin(); const eventId = b.id || id(), old = s.get('events', eventId);
        if (b.id && !old) fail(404, 'Termin nicht gefunden.');
        if (old && (old.version ?? 1) !== b.version) fail(409, 'Der Termin wurde zwischenzeitlich geändert.');
        const startsAt = date(b.startsAt), endsAt = date(b.endsAt);
        if (endsAt <= startsAt) fail(400, 'Das Ende muss nach dem Beginn liegen.');
        if (b.productionId && !s.get('productions', b.productionId)) fail(400, 'Produktion nicht gefunden.');
        const sceneIds = [...new Set(list(b.sceneIds).map(String))];
        if (b.productionId && sceneIds.some(x => !s.get('scripts', b.productionId)?.scenes.some(scene => scene.id === x))) fail(400, 'Eine ausgewählte Szene gehört nicht zur Produktion.');
        const e = { id: eventId, title: required(b.title, 'Titel'), startsAt, endsAt, place: text(b.place), group: text(b.group), type: ['rehearsal', 'technical', 'performance', 'costume', 'other'].includes(b.type) ? b.type : 'rehearsal', locked: b.locked === true, productionId: b.productionId || null, sceneIds: b.productionId ? sceneIds : [], version: (old?.version ?? 0) + 1 };
        s.put('events', eventId, e);
        for (const r of s.all('responses').filter(r => r.eventId === eventId && r.expectedArrivalAt && (r.expectedArrivalAt <= startsAt || r.expectedArrivalAt >= endsAt))) s.put('responses', `${eventId}:${r.personId}`, { ...r, expectedArrivalAt: null });
        for (const absence of s.all('absences')) if (absence.from <= day(startsAt) && absence.to >= day(startsAt) && !s.get('responses', `${eventId}:${absence.personId}`)) s.put('responses', `${eventId}:${absence.personId}`, { eventId, personId: absence.personId, status: 'no', expectedArrivalAt: null, reason: absence.reason, updatedAt: now() });
        if (old) this.enqueuePush({ title: 'Termin aktualisiert', body: e.title, data: { eventId }, change: true });
        return { id: eventId };
      }
      case 'event.delete': {
        admin(); const e = s.get('events', b.id); if (!e) fail(404, 'Termin nicht gefunden.');
        if ((e.version ?? 1) !== b.version) fail(409, 'Der Termin wurde zwischenzeitlich geändert.');
        s.delete('events', b.id);
        for (const kind of ['responses', 'checkins']) for (const item of s.all(kind).filter(x => x.eventId === b.id)) s.delete(kind, `${item.eventId}:${item.personId}`);
        return {};
      }
      case 'checkin.save': {
        admin(); if (!s.get('events', b.eventId)) fail(404, 'Termin nicht gefunden.');
        for (const c of list(b.members)) {
          const memberId = Number(c.id), key = `${b.eventId}:${memberId}`, old = s.get('checkins', key);
          if (!s.get('members', memberId)?.active) fail(400, 'Person nicht verfügbar.');
          if (c.present !== null && typeof c.present !== 'boolean') fail(400, 'Anwesenheit muss da, fehlt oder nicht erfasst sein.');
          if ((old?.version ?? 0) !== (c.version ?? 0)) fail(409, 'Ein Anwesenheitseintrag wurde gleichzeitig geändert. Bitte neu laden.');
          s.put('checkins', key, { eventId: b.eventId, personId: memberId, present: c.present, version: (old?.version ?? 0) + 1, updatedAt: now() });
        }
        return {};
      }
      case 'event.script': {
        admin(); const e = s.get('events', b.eventId); if (!e) fail(404, 'Termin nicht gefunden.');
        const doc = b.productionId ? s.get('scripts', b.productionId) : null;
        if (b.productionId && !doc) fail(400, 'Drehbuch nicht gefunden.');
        const sceneIds = [...new Set(list(b.sceneIds).map(String))];
        if (doc && sceneIds.some(x => !doc.scenes.some(scene => scene.id === x))) fail(400, 'Szene nicht gefunden.');
        s.put('events', e.id, { ...e, productionId: b.productionId || null, sceneIds: doc ? sceneIds : [], version: (e.version ?? 1) + 1 }); return {};
      }
      case 'production.save': {
        admin(); const productionId = b.id || id(), old = s.get('productions', productionId);
        if (b.id && !old) fail(404, 'Produktion nicht gefunden.');
        if (old && (old.version ?? 1) !== b.version) fail(409, 'Die Produktion wurde zwischenzeitlich geändert.');
        const casting = {};
        for (const [roleId, memberId] of Object.entries(b.casting ?? {})) {
          if (!old?.roles.some(r => r.id === roleId)) fail(400, 'Rolle gehört nicht zur Produktion.');
          if (memberId != null && !s.get('members', Number(memberId))?.active) fail(400, 'Besetzte Person nicht verfügbar.');
          if (memberId != null) casting[roleId] = Number(memberId);
        }
        const directors = list(b.directorMemberIds).map(Number);
        if (directors.some(m => !s.get('members', m)?.active)) fail(400, 'Regieperson nicht verfügbar.');
        s.put('productions', productionId, { ...old, id: productionId, title: required(b.title, 'Titel'), subtitle: text(b.subtitle), roles: old?.roles ?? [], sceneCount: old?.sceneCount ?? 0, revision: old?.revision ?? '', casting, directorMemberIds: [...new Set(directors)], version: (old?.version ?? 0) + 1 });
        return { id: productionId };
      }
      case 'message.send': {
        admin(); const audience = b.audience === 'selected' ? 'selected' : 'all';
        const recipients = audience === 'all' ? s.all('members').filter(m => m.active).map(m => m.id) : [...new Set(list(b.recipientPersonIds).map(Number))];
        if (!recipients.length || recipients.some(m => !s.get('members', m)?.active)) fail(400, 'Bitte gültige Empfänger auswählen.');
        const m = { id: id(), title: required(b.title, 'Betreff'), body: required(b.body, 'Nachricht', 10000), audience, recipientPersonIds: recipients, authorId: a.personId, authorName: s.get('members', a.personId).name, createdAt: now() };
        s.put('messages', m.id, m);
        if (b.push === true) this.enqueuePush({ title: m.title, body: m.body.slice(0, 200), data: { messageId: m.id }, recipientPersonIds: recipients });
        return { id: m.id, pushQueued: b.push === true && this.pushEnabled };
      }
      case 'message.read': { const m = s.get('messages', b.id); if (!m || !this.canReadMessage(a, m)) fail(404, 'Mitteilung nicht gefunden.'); s.put('receipts', `${m.id}:${a.personId}`, { messageId: m.id, personId: a.personId, readAt: now() }); return {}; }
      case 'comment.save': {
        const doc = s.get('scripts', b.productionId);
        if (!doc || doc.revision !== b.revision || !doc.cues.some(c => c.id === b.cueId)) fail(409, 'Diese Textstelle gehört nicht zur aktuellen Fassung.');
        const commentId = b.id || id(), old = s.get('comments', commentId);
        if (b.id && (!old || old.authorId !== a.personId)) fail(403, 'Du kannst nur eigene Kommentare bearbeiten.');
        const comment = { id: commentId, productionId: b.productionId, cueId: b.cueId, revision: b.revision, text: required(b.text, 'Kommentar', 3000), authorId: a.personId, authorName: this.profile(a).displayName, createdAt: old?.createdAt ?? now(), updatedAt: now() };
        s.put('comments', commentId, comment); return { id: commentId };
      }
      case 'comment.delete': { const comment = s.get('comments', b.id); if (!comment || (comment.authorId !== a.personId && a.role !== 'admin')) fail(403, 'Diesen Kommentar kannst du nicht entfernen.'); s.delete('comments', b.id); return {}; }
      case 'push.test': { if (!this.pushEnabled) fail(409, 'Der Push-Versand ist noch nicht eingerichtet.'); this.enqueuePush({ title: 'Theater-App', body: 'Deine Testbenachrichtigung ist da.', data: {}, recipientPersonIds: [a.personId] }); return { queued: true }; }
      default: fail(400, 'Diese Aktion wird nicht unterstützt.');
    }
  }
  importScript(uid, production, document) {
    this.account(uid, true);
    if (!production?.id || !document?.revision || !Array.isArray(document.cues) || !Array.isArray(document.scenes) || !Array.isArray(document.roles)) fail(400, 'Ungültiges Drehbuch.');
    return this.store.transaction(() => {
      const old = this.store.get('productions', production.id);
      this.store.put('productions', production.id, { ...production, roles: document.roles, sceneCount: document.scenes.length, revision: document.revision, casting: Object.fromEntries(Object.entries(old?.casting ?? {}).filter(([role]) => document.roles.some(r => r.id === role))), directorMemberIds: old?.directorMemberIds ?? [], version: (old?.version ?? 0) + 1 });
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
    if (body.revision !== doc.revision) fail(409, 'Die Drehbuchfassung hat sich geändert.');
    if (body.cueId != null && !doc.cues.some(c => c.id === body.cueId)) fail(400, 'Textstelle nicht gefunden.');
    if (body.sequence != null && body.sequence !== current.sequence) fail(409, 'Die Regiemarkierung wurde zwischenzeitlich geändert.');
    const cue = doc.cues.find(c => c.id === body.cueId);
    return { ...this.store.put('focus', productionId, { productionId, revision: doc.revision, sequence: current.sequence + 1, cueId: body.cueId ?? null, cueOrdinal: cue?.ordinal ?? null, sceneId: cue?.sceneId ?? null, updatedBy: uid, director: { id: uid, name: this.profile(a).displayName }, updatedAt: now() }), canDirect };
  }
  device(uid, token, platform, remove = false) {
    this.account(uid); if (typeof token !== 'string' || token.length < 20 || token.length > 4096) fail(400, 'Ungültiges Gerätetoken.');
    const key = createHash('sha256').update(token).digest('hex');
    if (remove) { if (this.store.get('devices', key)?.uid === uid) this.store.delete('devices', key); }
    else { if (!['android', 'ios', 'web'].includes(platform)) fail(400, 'Ungültige Plattform.'); this.store.put('devices', key, { id: key, uid, token, platform, updatedAt: now() }); }
    return { ok: true, pushEnabled: this.pushEnabled };
  }
  enqueuePush(message) {
    if (!this.pushEnabled) return;
    const job = { id: id(), ...message, attempts: 0, status: 'pending', createdAt: now(), nextAttemptAt: now() };
    this.store.put('pushJobs', job.id, job);
  }
}
