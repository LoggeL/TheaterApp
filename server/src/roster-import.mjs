import { createHash } from 'node:crypto';

const key = value => String(value ?? '').trim().toLocaleLowerCase('de');
const initials = name => name.split(/\s+/).slice(0, 2).map(x => x[0]).join('').toUpperCase();

/** Explicit one-time person/casting migration. Never imports credentials or grants access. */
export function importRoster(store, input, { apply = false } = {}) {
  const { source, migrationId, members, productionIds, existingPeople = {}, actorAliases = {} } = input;
  if (!source || !migrationId || !Array.isArray(members) || !Array.isArray(productionIds)) throw Error('Invalid roster import');
  const fingerprint = createHash('sha256').update(JSON.stringify(input)).digest('hex');
  const markerId = `roster:${source}:${migrationId}`;
  return store.transaction(() => {
    const done = store.get('migrations', markerId);
    if (done) {
      if (done.fingerprint !== fingerprint) throw Error('Migration ID already used with different data');
      return { ...done.report, alreadyApplied: true };
    }
    const allMembers = store.all('members'), changes = new Map(), bySource = new Map();
    let nextId = Math.max(0, ...allMembers.map(m => m.id)) + 1;
    for (const m of members) {
      const sourceId = String(m.sourceId), ref = `${source}:${sourceId}`;
      if (!m.name?.trim() || bySource.has(sourceId)) throw Error(`Invalid or duplicate source person: ${sourceId}`);
      const existingId = existingPeople[sourceId];
      const old = existingId == null ? allMembers.find(p => p.sourceRefs?.includes(ref)) : store.get('members', existingId);
      if (existingId != null && !old) throw Error(`Existing person not found: ${existingId}`);
      if (old && [...bySource.values()].some(p => p.id === old.id)) throw Error('Multiple source people mapped to one person');
      const personId = old?.id ?? nextId++;
      // Explicitly map public roster fields. No source email, password or auth role.
      const person = old ? { ...old, roleName: old.roleName || m.roleName || '', sourceRefs: [...new Set([...(old.sourceRefs ?? []), ref])], version: (old.version ?? 1) + 1 }
        : { id: personId, name: m.name.trim(), group: m.group || 'Ensemble', roleName: m.roleName || '', initials: m.initials || initials(m.name), active: m.active !== false, version: 1, sourceRefs: [ref] };
      bySource.set(sourceId, person); changes.set(personId, person);
    }
    for (const [actor, sourceId] of Object.entries(actorAliases)) {
      if (sourceId != null && !bySource.has(String(sourceId))) throw Error(`Actor alias has unknown person: ${actor}`);
    }
    const extraActors = new Map(), productions = [], unresolved = [];
    for (const productionId of productionIds) {
      const p = store.get('productions', productionId);
      if (!p) throw Error(`Production not found: ${productionId}`);
      const casting = { ...(p.casting ?? {}) };
      for (const r of p.roles ?? []) {
        const actor = r.actor?.trim();
        if (!actor) continue; // Collective cue speakers are not separate people.
        let person;
        if (Object.hasOwn(actorAliases, actor)) {
          const alias = actorAliases[actor];
          if (alias != null) person = bySource.get(String(alias));
        } else {
          const matches = members.filter(m => key(m.name) === key(actor)).map(m => bySource.get(String(m.sourceId)));
          if (matches.length === 1) person = matches[0];
          else if (matches.length === 0) {
            person = extraActors.get(key(actor));
            if (!person) {
              const ref = `script-actor:${key(actor)}`;
              person = allMembers.find(m => m.sourceRefs?.includes(ref)) ?? { id: nextId++, name: actor, group: 'Ensemble', initials: initials(actor), active: true, version: 1, sourceRefs: [ref] };
              extraActors.set(key(actor), person); changes.set(person.id, person);
            }
          }
        }
        if (!person) { unresolved.push({ productionId, roleId: r.id, actor }); continue; }
        if (casting[r.id] != null && casting[r.id] !== person.id) throw Error(`Existing casting conflict: ${productionId}/${r.id}`);
        casting[r.id] = person.id;
      }
      productions.push({ ...p, casting, version: (p.version ?? 1) + 1 });
    }
    const report = { sourcePeople: bySource.size, additionalScriptPeople: extraActors.size,
      createdPeople: [...changes.keys()].filter(id => !allMembers.some(m => m.id === id)).length,
      totalPeople: new Set([...allMembers.map(m => m.id), ...changes.keys()]).size,
      castingCount: productions.reduce((n, p) => n + Object.keys(p.casting).length, 0),
      roleCount: productions.reduce((n, p) => n + p.roles.length, 0), unresolved,
      loginAccounts: store.accounts().length,
    };
    if (apply) {
      for (const m of changes.values()) store.put('members', m.id, m);
      for (const p of productions) store.put('productions', p.id, p);
      store.put('migrations', markerId, { fingerprint, report, appliedAt: new Date().toISOString() });
      store.audit('roster-import', 'roster.import', markerId);
    }
    return { ...report, applied: apply };
  });
}
