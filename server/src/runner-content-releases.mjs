import { readFileSync } from 'node:fs';

/** Scheduled runner content is enforced by server time on every catalog access. */
export function parseContentReleases(data) {
  if (!Array.isArray(data)) throw new Error('Runner releases must be an array');
  const ids = new Set(), gated = new Set();
  return data.map(raw => {
    if (!raw || typeof raw.id !== 'string' || !/^[a-z0-9][a-z0-9-]*$/.test(raw.id) || ids.has(raw.id)) throw new Error('Invalid runner release id');
    ids.add(raw.id);
    if (typeof raw.name !== 'string' || !raw.name.trim() || typeof raw.startsAt !== 'string' || !/(Z|[+-]\d\d:\d\d)$/.test(raw.startsAt) || !Number.isFinite(Date.parse(raw.startsAt))) throw new Error(`Invalid runner release ${raw.id}`);
    const list = key => {
      const value = raw[key] ?? [];
      if (!Array.isArray(value) || value.some(id => typeof id !== 'string' || !id) || new Set(value).size !== value.length) throw new Error(`Invalid ${key} of ${raw.id}`);
      return [...value];
    };
    const itemIds = list('itemIds'), gatedItemIds = list('gatedItemIds'), freeItemIds = list('freeItemIds');
    for (const id of [...itemIds, ...gatedItemIds]) {
      if (gated.has(id)) throw new Error(`Runner item ${id} scheduled twice`);
      gated.add(id);
    }
    const goal = raw.goalMeters !== undefined;
    if (goal && (!(Number.isInteger(raw.goalMeters) && raw.goalMeters > 0) || !itemIds.length || !(Number.isInteger(raw.crateCount) && raw.crateCount > 0))) throw new Error(`Invalid goal ${raw.id}`);
    return { id: raw.id, name: raw.name, startsAt: new Date(raw.startsAt).toISOString(), itemIds, gatedItemIds, freeItemIds,
      ...(goal ? { goalMeters: raw.goalMeters, crateCount: raw.crateCount } : {}) };
  });
}

let bundled;
export const bundledContentReleases = () => bundled ??= parseContentReleases(JSON.parse(readFileSync(new URL('./wardrobe/releases.json', import.meta.url), 'utf8')));
export const releaseIsActive = (release, at) => +at >= Date.parse(release.startsAt);
/** A role set goes live together, after every sprite is present in the deployed catalog. */
export const releasePackReady = (base, release) => release.itemIds.every(id => {
  const item = base.byId.get(id);
  return item && !item.default && !item.reward && !item.unique
    && (!['character', 'backdrop'].includes(item.kind) || typeof item.image === 'string');
});
export const releasedFreeItems = t => (t.runnerReleases ?? []).filter(r => releaseIsActive(r, t.clock())).flatMap(r => r.freeItemIds ?? []).filter(id => t.runnerCatalog.byId.has(id));

const assetKeys = ['image', 'portrait', 'thumb', 'obstacles', 'collectibles', 'music', 'openImage', 'fxImage'];
const filesOf = entries => new Set(entries.flatMap(x => assetKeys.flatMap(key => typeof x[key] === 'string' ? [x[key].match(/\/skins\/([^?]+)/)?.[1]].filter(Boolean) : [])));

/** Preserves parsed item objects (including non-enumerable draw/legacy metadata). */
export function releasedCatalog(base, releases, at) {
  const hidden = new Set(releases.flatMap(r => !releaseIsActive(r, at) ? [...r.itemIds, ...r.gatedItemIds]
    : !releasePackReady(base, r) ? [...r.itemIds, ...r.gatedItemIds.filter(id => base.byId.get(id)?.kind !== 'backdrop')] : []));
  if (!hidden.size) return base;
  const items = base.items.filter(x => !hidden.has(x.id));
  const byId = new Map(items.map(x => [x.id, x]));
  const collectible = base.collectible.filter(x => byId.has(x.id));
  const targetItems = new Map([...base.targetItems].map(([id, pool]) => [id, pool.filter(x => byId.has(x.id))]));
  const crateTargets = base.crateTargets.filter(x => x.id === 'random' || targetItems.get(x.id)?.length);
  for (const id of targetItems.keys()) if (!crateTargets.some(x => x.id === id)) targetItems.delete(id);
  const allowedFiles = filesOf([...items, ...crateTargets]);
  const restrictedFiles = map => new Map([...map].map(([name, ids]) => [name, ids.filter(id => byId.has(id))]).filter(([name, ids]) => allowedFiles.has(name) && ids.length));
  const baseOf = new Map([...base.baseOf].filter(([id, parent]) => byId.has(id) && byId.has(parent)));
  const rolesOf = new Map();
  for (const [id, parent] of baseOf) rolesOf.set(parent, [...(rolesOf.get(parent) ?? []), byId.get(id)]);
  return { ...base, items, byId, collectible, uniques: base.uniques.filter(x => byId.has(x.id)), targetItems, crateTargets,
    files: new Map([...base.files].filter(([name]) => allowedFiles.has(name))),
    rewardFiles: restrictedFiles(base.rewardFiles), uniqueFiles: restrictedFiles(base.uniqueFiles), baseOf, rolesOf,
    ensemble: base.ensemble ? { ...base.ensemble, milestones: base.ensemble.milestones.map(m => hidden.has(m.item) ? { km: m.km, item: m.item, releasePending: true } : m) } : null,
  };
}
