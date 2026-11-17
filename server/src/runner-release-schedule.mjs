import { AppError } from './theater.mjs';
import { releaseIsActive, releasePackReady } from './runner-content-releases.mjs';
import { announceContentDrops, dropIsLive } from './runner-drop-push.mjs';
import { berlinParts, fromBerlin } from './event-series.mjs';

// The admins' Release-Zeitplan of the stage runner (`runnerReleaseSchedule`): the scheduled drops of
// wardrobe/releases.json, and new dates for them without a deploy.
//
// - Store kind `runnerReleaseOverrides`, one entry per release id: `{ releaseId, startsAt,
//   updatedAt, updatedBy }`. `Theater.runnerReleases` is releases.json (the default) with these
//   dates on top; only `startsAt` can change, never the contents of a release. An entry for an id
//   that releases.json no longer knows is ignored. Resetting deletes the entry, so the date of
//   releases.json counts again (also after a later deploy changes it).
// - The Theater keeps the merged plan in memory and builds it again after every change made here;
//   production runs one server process (see runner-drop-push.mjs).
// - GET /admin/runner/releases: every release, earliest first, with `startsAt`, `plannedStartsAt`
//   (releases.json), `overridden`, `itemCount`, `active` (started), `ready` (all its pictures there,
//   by the rule the drop push uses: `dropIsLive` on the deployed catalog), `status` (`live`: started
//   and ready; `blocked`: started, but held back for missing pictures; `scheduled`: not started),
//   `missing` (how many items of its set still keep it back) and `push` `{ state, at }`: `sent`,
//   `skipped` (found more than 24 hours late), `held` (started, waiting for pictures), `silent`
//   (started before the drop push existed: never pushes) or `pending` (nothing yet).
// - PUT /admin/runner/releases/<id>: `{ date: 'YYYY-MM-DD', time: 'HH:MM' }` (Berlin wall clock,
//   time 18:00 by default), or `{ startsAt }` as ISO 8601 with a UTC offset (`Z` or `+01:00`), or
//   `{ startsAt: null }` for the date of releases.json. Answers the new entry as in the list.
// - Guard rail: a release that is live (started and ready, so players have its contents) moves
//   into the future only with `confirm: true`; without it 409 `release_live`. Its push stays sent:
//   it never comes a second time.
// - A date in the past or now goes through the normal drop logic right away (`announceContentDrops`,
//   also run by the worker every 15 seconds): one push "Neu: <Name>" if the new date lies after the
//   push's cutover and at most 24 hours back, none if it was announced before or lies further back.
// - Admins only (`theater.account(uid, true)`, 403 otherwise), like the other admin routes. Every
//   change is in the audit log (`runnerRelease.reschedule`).

const kind = 'runnerReleaseOverrides';
const fail = (status, message, code) => { throw new AppError(status, message, code); };
export const defaultReleaseTime = '18:00';

/** [planned] (parsed releases) with the dates stored in [store]; the same array without any. */
export function withReleaseOverrides(planned, store) {
  const overrides = new Map(store.all(kind).map(o => [o.releaseId, o]));
  if (!overrides.size) return planned;
  return planned.map(r => {
    const at = Date.parse(overrides.get(r.id)?.startsAt);
    return Number.isFinite(at) ? { ...r, startsAt: new Date(at).toISOString() } : r;
  });
}

const two = n => String(n).padStart(2, '0');
const validDay = (y, m, d) => { const at = new Date(Date.UTC(y, m - 1, d)); return at.getUTCFullYear() === y && at.getUTCMonth() === m - 1 && at.getUTCDate() === d; };
const inRange = y => y >= 2020 && y < 2100;

/** The instant as Berlin wall time with its offset, e.g. `2026-11-22T18:00:00+01:00`. */
export function berlinIso(ms) {
  const p = berlinParts(ms), offset = Math.round((Date.UTC(p.y, p.m, p.d, p.h, p.mi, p.s, p.ms) - ms) / 60000);
  const sign = offset < 0 ? '-' : '+', abs = Math.abs(offset);
  return `${p.y}-${two(p.m + 1)}-${two(p.d)}T${two(p.h)}:${two(p.mi)}:${two(p.s)}${sign}${two(Math.floor(abs / 60))}:${two(abs % 60)}`;
}

const iso = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,3})?)?(Z|[+-](\d{2}):(\d{2}))$/;

/** The instant (ms) of a request body, or null for the date of releases.json; 400 for anything else. */
export function requestedStart(body) {
  const bad = () => fail(400, 'Bitte ein gültiges Datum mit Uhrzeit wählen.', 'invalid_date');
  if (body.date !== undefined) {
    const day = typeof body.date === 'string' ? body.date.match(/^(\d{4})-(\d{2})-(\d{2})$/) : null;
    const time = (body.time ?? defaultReleaseTime);
    const clock = typeof time === 'string' ? time.match(/^(\d{2}):(\d{2})$/) : null;
    if (!day || !clock) bad();
    const [y, m, d] = day.slice(1).map(Number), [h, mi] = clock.slice(1).map(Number);
    if (!inRange(y) || !validDay(y, m, d) || h > 23 || mi > 59) bad();
    return fromBerlin({ y, m: m - 1, d, h, mi, s: 0, ms: 0 });
  }
  if (body.startsAt === null) return null;
  if (typeof body.startsAt !== 'string') bad();
  const match = body.startsAt.match(iso);
  // A time without an offset would depend on the server's zone: refused, as in releases.json.
  if (!match) fail(400, 'Bitte den Termin als ISO-Datum mit Zeitzone angeben, z. B. 2026-11-22T18:00:00+01:00.', 'invalid_date');
  const [y, m, d, h, mi, s = '0'] = match.slice(1, 7).map(Number);
  if (!inRange(y) || !validDay(y, m, d) || h > 23 || mi > 59 || s > 59 || (match[8] !== undefined && (+match[8] > 14 || +match[9] > 59))) bad();
  const at = Date.parse(body.startsAt);
  return Number.isFinite(at) ? at : bad();
}

/** How the drop push stands for [release] (see the header). */
function pushOf(t, release, active) {
  const state = t.store.get('runnerDropPush', `release:${release.id}`);
  if (state?.sentAt) return { state: 'sent', at: state.sentAt };
  if (state?.skippedAt) return { state: 'skipped', at: state.skippedAt };
  if (state?.heldAt) return { state: 'held', at: state.heldAt };
  const cutover = t.store.get('runnerDropPush', 'cutover');
  // Without a cutover, the first run of the worker notes one now: everything started by then stays silent.
  if (active && (!cutover || Date.parse(release.startsAt) <= Date.parse(cutover.at))) return { state: 'silent', at: null };
  return { state: 'pending', at: null };
}

function entryOf(t, release, planned, at) {
  const base = t.runnerBaseCatalog, active = releaseIsActive(release, at), ready = dropIsLive(base, release);
  const override = t.store.get(kind, release.id);
  const missing = release.itemIds.filter(id => !releasePackReady(base, { itemIds: [id] })).length;
  return {
    id: release.id, name: release.name, startsAt: release.startsAt,
    plannedStartsAt: planned?.startsAt ?? release.startsAt,
    overridden: !!override && planned?.startsAt !== release.startsAt,
    ...(override ? { updatedAt: override.updatedAt } : {}),
    itemCount: new Set([...release.itemIds, ...release.gatedItemIds, ...release.freeItemIds]).size,
    active, ready, status: !active ? 'scheduled' : ready ? 'live' : 'blocked', missing,
    push: pushOf(t, release, active),
  };
}

const plannedById = t => new Map(t.plannedRunnerReleases.map(r => [r.id, r]));
const byStart = (a, b) => Date.parse(a.startsAt) - Date.parse(b.startsAt) || a.id.localeCompare(b.id);

/** GET /admin/runner/releases: the timeline, earliest first. */
export function adminReleaseSchedule(t, uid) {
  t.account(uid, true);
  const at = t.clock(), planned = plannedById(t);
  return {
    timeZone: 'Europe/Berlin', defaultTime: defaultReleaseTime, serverTime: at.toISOString(),
    releases: [...t.runnerReleases].sort(byStart).map(r => entryOf(t, r, planned.get(r.id), at)),
  };
}

/** PUT /admin/runner/releases/<id>: a new date for one release (see the header). */
export function rescheduleRelease(t, uid, id, body) {
  const account = t.account(uid, true);
  const planned = plannedById(t).get(id) ?? fail(404, 'Diesen Release gibt es nicht.', 'not_found');
  const wanted = requestedStart(body);
  const target = wanted ?? Date.parse(planned.startsAt);
  t.store.transaction(() => {
    const at = t.clock(), current = t.runnerReleases.find(r => r.id === id);
    const live = releaseIsActive(current, at) && dropIsLive(t.runnerBaseCatalog, current);
    if (live && target > +at && body.confirm !== true) {
      fail(409, `„${current.name}“ ist bereits freigeschaltet. Ein späterer Termin nimmt den Spielenden die Inhalte bis dahin wieder weg, und der Push kommt kein zweites Mal.`, 'release_live');
    }
    if (wanted === null || target === Date.parse(planned.startsAt)) t.store.delete(kind, id);
    else t.store.put(kind, id, { releaseId: id, startsAt: berlinIso(target), updatedAt: at.toISOString(), updatedBy: account.personId });
    t.store.audit(uid, 'runnerRelease.reschedule', `${id} ${current.startsAt} -> ${new Date(target).toISOString()}`);
  });
  t.reloadRunnerReleases();
  // Due now: the drop logic of the worker right away, with its own transaction and its markers.
  try { announceContentDrops(t); } catch (e) { console.error('Drop-Push:', e.code ?? e.message); }
  const release = t.runnerReleases.find(r => r.id === id);
  return entryOf(t, release, planned, t.clock());
}
