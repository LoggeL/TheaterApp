// Cues several roles speak together. The script source names them like one
// character ("ROMEO UND JULIA", "X & Y", "X, Y UND Z"). Such a name becomes the
// list of its roles on every cue (`roles`), and the made-up combined role leaves
// the role list. Cue ids, scenes and the script revision stay untouched: they
// are shared with the legacy Skript service.

const separator = /\s*,\s*|\s*&\s*|\s+und\s+/i;
// Collective speakers that are no fixed set of roles; they stay as they are.
const groupWords = new Set(['ALLE', 'BEIDE', 'CHOR', 'ENSEMBLE', 'GRUPPE', 'STIMMEN', 'ALLE ANDEREN']);
export const speakerSeparator = ' & ';
export const sharedSpeakersMigrationId = 'script-shared-speakers-v1';

const key = value => String(value ?? '').trim().toUpperCase();
const unique = values => [...new Set(values)];

/** A group speaker like "ALLE" or "CHOR"; numbered roles such as "ENSEMBLE 3" are single roles. */
export const isGroupSpeaker = name => groupWords.has(key(name).replace(/\s+/g, ' '));

/** The role ids [name] stands for when it joins known roles, otherwise null. */
export function sharedRoleIds(name, known) {
  const parts = String(name ?? '').split(separator).map(key).filter(Boolean);
  if (parts.length < 2) return null;
  const ids = parts.map(part => known.get(part));
  return ids.every(Boolean) ? unique(ids) : null;
}

/** The speaker roles of [cue]: `roles` when present, otherwise its single `role`. */
export const cueRoles = cue => Array.isArray(cue?.roles) && cue.roles.length ? cue.roles.map(String) : cue?.role ? [String(cue.role)] : [];

/** The label for a cue spoken by [roles], e.g. "ROMEO & JULIA". */
export const speakerLabel = roles => roles.join(speakerSeparator);

/**
 * Gives every cue its list of speakers and removes combined roles. Pure and
 * idempotent: a document that is already split comes back unchanged.
 * `combined` lists the removed roles, `unresolved` the group or partly unknown
 * speakers that keep their own role.
 */
export function splitSharedSpeakers(document) {
  const roles = Array.isArray(document?.roles) ? document.roles : [];
  const known = new Map();
  for (const role of roles) for (const name of [role.id, role.name]) if (key(name) && !known.has(key(name))) known.set(key(name), role.id);
  const combined = new Map();
  for (const role of roles) {
    // A role is combined when its name consists of other existing roles only.
    const ids = sharedRoleIds(role.id, known) ?? sharedRoleIds(role.name, known);
    if (ids && !ids.includes(role.id)) combined.set(role.id, ids);
  }
  // Combined roles may also be named after other combined roles; resolve to single roles.
  const resolve = (id, seen = new Set()) => {
    if (seen.has(id)) return [id];
    seen.add(id);
    const ids = combined.get(id) ?? sharedRoleIds(id, known);
    return ids ? unique(ids.flatMap(x => (combined.has(x) ? resolve(x, seen) : [x]))) : [id];
  };
  const counts = new Map();
  const cues = (Array.isArray(document?.cues) ? document.cues : []).map(cue => {
    const before = cueRoles(cue);
    if (!before.length) return cue;
    for (const id of before) counts.set(id, (counts.get(id) ?? 0) + 1);
    const speakers = unique(before.flatMap(id => resolve(id)));
    return { ...cue, role: speakers.length > 1 ? speakerLabel(speakers) : speakers[0], roles: speakers };
  });
  const remaining = roles.filter(role => !combined.has(role.id));
  const unresolved = remaining
    .filter(role => isGroupSpeaker(role.id) || String(role.id).split(separator).filter(Boolean).length > 1)
    .map(role => ({ roleId: role.id, cues: counts.get(role.id) ?? 0, reason: isGroupSpeaker(role.id) ? 'group' : 'unknown_roles' }));
  return {
    document: { ...document, roles: remaining, cues },
    combined: [...combined.keys()].map(roleId => ({ roleId, roles: resolve(roleId), cues: counts.get(roleId) ?? 0 })),
    unresolved,
  };
}

/** A production without the [combined] roles: its role list and casting, plus the removed castings. */
export function withoutCombinedRoles(production, combined) {
  const removed = new Set(combined.map(c => c.roleId));
  const casting = { ...production?.casting }, removedCasting = [];
  for (const roleId of removed) if (Object.hasOwn(casting, roleId)) { removedCasting.push({ roleId, personId: casting[roleId] }); delete casting[roleId]; }
  return { roles: (production?.roles ?? []).filter(r => !removed.has(r.id)), casting, removedCasting };
}

/**
 * One-off migration of stored scripts and productions to cues with several
 * speakers. Safe to run again: already split data stays unchanged.
 */
export function migrateSharedSpeakers(store, at = new Date().toISOString()) {
  const done = store.get('migrations', sharedSpeakersMigrationId);
  if (done) return { ...done.report, alreadyApplied: true };
  const report = { productions: [], unresolved: [] };
  for (const doc of store.all('scripts')) {
    const productionId = doc.productionId;
    const { document, combined, unresolved } = splitSharedSpeakers(doc);
    for (const u of unresolved) report.unresolved.push({ productionId, ...u });
    if (JSON.stringify(document) !== JSON.stringify(doc)) store.put('scripts', productionId, document);
    const p = store.get('productions', productionId);
    let removedCasting = [];
    if (p) {
      const next = withoutCombinedRoles(p, combined);
      removedCasting = next.removedCasting;
      if (next.roles.length !== (p.roles ?? []).length || removedCasting.length) store.put('productions', p.id, { ...p, roles: next.roles, casting: next.casting, version: (p.version ?? 1) + 1 });
    }
    if (combined.length || removedCasting.length) report.productions.push({ productionId, combined, removedCasting });
  }
  store.put('migrations', sharedSpeakersMigrationId, { report, appliedAt: at });
  return report;
}
