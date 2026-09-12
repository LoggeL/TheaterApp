import { io } from 'socket.io-client';
import { AppError } from './theater.mjs';

// One connection per requested play; no shared-room traffic until somebody opens
// the session. Cue IDs and revisions must match before legacy markers are used.
export class ScriptFocusBridge {
  constructor(theater, { url, password, socketFactory = io }) {
    this.theater = theater; this.url = url; this.password = password; this.socketFactory = socketFactory; this.rooms = new Map();
    this.timer = setInterval(() => { for (const [id, r] of this.rooms) if (Date.now() - r.touched > 600000) { r.socket.disconnect(); this.rooms.delete(id); } }, 60000);
    this.timer.unref?.();
  }
  close() { clearInterval(this.timer); for (const r of this.rooms.values()) r.socket.disconnect(); this.rooms.clear(); }
  wait(socket, event, predicate = () => true) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { socket.off(event, listener); reject(new AppError(502, 'Die Verbindung zum Skriptdienst antwortet nicht.')); }, 7000);
      const listener = data => { if (!predicate(data)) return; clearTimeout(timer); socket.off(event, listener); resolve(data); };
      socket.on(event, listener);
    });
  }
  async room(productionId) {
    let r = this.rooms.get(productionId);
    if (r) { r.touched = Date.now(); if (!r.socket.connected) throw new AppError(502, 'Die Skriptsitzung wird neu verbunden. Bitte erneut versuchen.'); return r; }
    const socket = this.socketFactory(this.url, { transports: ['websocket', 'polling'], forceNew: true, autoConnect: false, reconnection: true });
    r = { socket, touched: Date.now(), director: null, isDirector: false }; this.rooms.set(productionId, r);
    const director = data => { if (data.success === false) return; r.director = data.director === 'Niemand' ? null : data.director; r.isDirector = data.isDirector === true; };
    socket.on('set_director', director);
    socket.on('director_takeover', data => { r.director = data.newDirector; r.isDirector = data.isDirector === true; });
    socket.on('unset_director', () => { r.director = null; r.isDirector = false; });
    socket.on('disconnect', () => { r.isDirector = false; });
    socket.on('connect', () => {
      r.lastSequence = null;
      this.accept(productionId, r, { playId: productionId, cueId: null }, true);
      socket.emit('join_play', { playId: productionId });
    });
    socket.on('marker_update', data => this.accept(productionId, r, data));
    socket.on('marker_clear', data => this.accept(productionId, r, { ...data, cueId: null }, true));
    const joined = this.wait(socket, 'set_director');
    socket.connect();
    try { await joined; return r; } catch (e) { socket.disconnect(); this.rooms.delete(productionId); throw e; }
  }
  accept(productionId, room, data, cleared = false) {
    if (data.playId !== productionId) return;
    const s = this.theater.store, doc = s.get('scripts', productionId);
    if (!doc || (!cleared && data.scriptRevision !== doc.revision)) return;
    const cue = !cleared ? doc.cues.find(c => c.id === data.cueId) : null;
    if (!cleared && !cue) return;
    if (Number.isSafeInteger(data.sequence) && room.lastSequence != null && data.sequence <= room.lastSequence) return;
    room.lastSequence = Number.isSafeInteger(data.sequence) ? data.sequence : null;
    const old = s.get('focus', productionId);
    s.put('focus', productionId, { productionId, revision: doc.revision, sequence: (old?.sequence ?? 0) + 1, cueId: cue?.id ?? null, cueOrdinal: cue?.ordinal ?? null, sceneId: cue?.sceneId ?? null, director: room.director ? { id: 'skript', name: room.director } : null, updatedAt: new Date().toISOString(), source: 'skript' });
  }
  async focus(uid, productionId, body) {
    const t = this.theater, current = t.focus(uid, productionId);
    const r = await this.room(productionId);
    if (body) {
      const doc = t.store.get('scripts', productionId);
      if (!current.canDirect) throw new AppError(403, 'Du hast keine Regieberechtigung für dieses Stück.');
      if (body.revision !== doc.revision || (body.sequence != null && body.sequence !== t.focus(uid, productionId).sequence)) throw new AppError(409, 'Fassung oder Regiemarkierung wurde zwischenzeitlich geändert.');
      const cue = doc.cues.find(c => c.id === body.cueId);
      if (body.cueId != null && !cue) throw new AppError(400, 'Textstelle nicht gefunden.');
      if (!this.password) throw new AppError(409, 'Für die gemeinsame Skript-Regie fehlt die Serverkonfiguration.');
      const name = t.profile(t.account(uid)).displayName;
      if (!r.isDirector || r.director !== name) {
        // Both a first director and a takeover have explicit server responses.
        const result = new Promise((resolve, reject) => {
          const timer = setTimeout(() => { cleanup(); reject(new AppError(502, 'Die Regie konnte nicht übernommen werden.')); }, 7000);
          const cleanup = () => { clearTimeout(timer); r.socket.off('set_director', accept); r.socket.off('director_takeover', accept); };
          const accept = data => { if (data.isDirector === true || data.success === false) { cleanup(); resolve(data); } };
          r.socket.on('set_director', accept); r.socket.on('director_takeover', accept);
        });
        r.socket.emit('set_director', { name, password: this.password });
        const response = await result;
        if (response.success === false) throw new AppError(502, 'Der Skriptdienst hat die Regieanmeldung abgelehnt.');
      }
      const event = cue ? 'marker_update' : 'marker_clear';
      const ack = this.wait(r.socket, event, d => d.playId === productionId && (!cue || d.cueId === cue.id));
      r.socket.emit(cue ? 'set_marker' : 'clear_marker', cue ? { protocolVersion: 2, playId: productionId, scriptRevision: doc.revision, cueId: cue.id, ordinal: cue.ordinal } : undefined);
      await ack;
    }
    return { ...t.focus(uid, productionId), connected: r.socket.connected, source: 'skript', director: r.director ? { id: 'skript', name: r.director } : null };
  }
}
