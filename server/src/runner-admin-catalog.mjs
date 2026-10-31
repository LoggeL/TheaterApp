import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { AppError } from './theater.mjs';
import { releaseIsActive } from './runner-content-releases.mjs';
import { isUniqueEntry } from './runner-unique.mjs';

// The admins' Skin-Viewer of the stage runner (`runnerAdminCatalog`): every entry of the wardrobe
// catalog as the admins see it, whatever a member would see of it right now.
//
// - GET /admin/runner/catalog: the catalog in the shape of the members' one (`rarities`,
//   `departments`, `ensembleRarity`, `uniqueRarity`, `items`), but with every entry in `items`:
//   active ones, those of a release that has not started (or whose pack is not ready), the unique
//   figures and ensemble rewards (secrets for members until unlocked), and the `disabled` ones that
//   members never get at all. Each item carries `admin`: `{ disabled, live, release, secret }`
//   (`live`: in the catalog members get right now; `release`: the scheduled release it belongs to;
//   `secret`: `unique` or `reward` while it is hidden until unlocked), and `releases` lists them all.
// - GET /admin/runner/skins/<file>: the pictures of that view. Its links point here, never to the
//   members' route: `/games/runner/skins/<file>` keeps answering 404 for unreleased, disabled and
//   secret pictures, for admins too, so nothing of this view can leak through it or its cache
//   (immutable there, and kept per account by the service worker). The answers here are `no-store`,
//   and the worker leaves this route alone. Music has no use here, so the view carries no link to it.
// - Both only for admins (`theater.account(uid, true)`, 403 otherwise), like the other admin routes.
//   Read-only: nothing here changes a catalog, a release or anybody's wardrobe.

const fail = (status, message, code) => { throw new AppError(status, message, code); };
const list = value => Array.isArray(value) ? value : [];
const text = v => typeof v === 'string' && v.trim() !== '';
const fileName = /^[a-z0-9][a-z0-9._-]{0,80}\.(?:webp|png)$/;
const imageTypes = { '.webp': 'image/webp', '.png': 'image/png' };
const hex = /^#[0-9A-Fa-f]{6}$/;
const poses = new Set(['fly', 'dangle', 'runA', 'passA', 'runB', 'passB', 'cheer', 'crash']);
const pictureKeys = ['image', 'portrait', 'thumb', 'obstacles', 'collectibles'];
const kinds = new Set(['character', 'backdrop', 'obstacles', 'fx']);

/** The admins' link of a picture the members' catalog links as `/games/runner/skins/<file>?v=…`. */
const adminLink = link => typeof link === 'string' ? link.replace(/^\/games\/runner\/skins\//, '/admin/runner/skins/') : link;

// The parsed `disabled` entries per catalog: built once, on the first admin request.
const views = new WeakMap();

/**
 * The `disabled` entries of [base] (a catalog of `loadCatalog`, which leaves them out), read as
 * leniently as an entry may be while it waits for its picture: an unknown rarity or a bad file name
 * does not break the view, it is shown as it is (or without the picture). Their pictures are kept
 * apart (`files`), served only through the admins' route.
 */
function disabledOf(base) {
  if (views.has(base)) return views.get(base);
  const { data, imageDir } = base.source ?? {};
  const files = new Map();
  const picture = name => {
    if (!text(name) || !fileName.test(name) || !imageDir) return undefined;
    if (!files.has(name) && !base.files.has(name)) {
      const path = new URL(name, imageDir);
      if (!existsSync(path)) return undefined;
      const bytes = readFileSync(path);
      files.set(name, { bytes, mime: imageTypes[name.slice(name.lastIndexOf('.'))], hash: createHash('sha256').update(bytes).digest('hex').slice(0, 16) });
    }
    const file = files.get(name) ?? base.files.get(name);
    return `/admin/runner/skins/${name}?v=${file.hash}`;
  };
  const scored = base.rarities.filter(r => r.minScore !== undefined).sort((x, y) => y.minScore - x.minScore || y.rank - x.rank);
  const rank = id => base.rarity.get(id)?.rank ?? -1;
  const special = new Set([base.uniqueRarity?.id, base.ensemble?.rarity?.id].filter(Boolean));
  const items = [];
  for (const x of list(data?.items)) {
    if (x?.disabled !== true || !text(x.id) || !kinds.has(x.kind) || base.byId.has(x.id)) continue;
    const unique = !!base.uniqueRarity && isUniqueEntry(x, base.uniqueRarity);
    const fixed = x.rarities !== undefined ? list(x.rarities) : x.rarity !== undefined ? [x.rarity] : [];
    const byScore = typeof x.score === 'number' ? scored.find(r => x.score >= r.minScore)?.id : undefined;
    const own = [...new Set([...fixed, ...(byScore ? [byScore] : []), ...(x.reward === true && !fixed.length && base.ensemble ? [base.ensemble.rarity.id] : [])])]
      .filter(id => typeof id === 'string' && (base.rarity.has(id) || special.has(id)))
      .sort((a, b) => rank(b) - rank(a));
    const departments = (x.department === undefined ? [] : Array.isArray(x.department) ? x.department : [x.department]).filter(d => typeof d === 'string');
    const item = {
      id: x.id, kind: x.kind, name: text(x.name) ? x.name : x.id, rarity: own[0] ?? base.rarities[0].id, rarities: own.length ? own : [base.rarities[0].id],
      ...(x.default === true ? { default: true } : {}),
      ...(x.placeholder === true ? { placeholder: true } : {}),
      ...(x.reward === true ? { reward: true } : {}),
      ...(unique ? { unique: true, ...(x.unlock && typeof x.unlock === 'object' ? { unlock: x.unlock } : {}) } : {}),
      ...(departments.length ? { departments } : {}),
      ...(text(x.rarityReason) ? { rarityReason: x.rarityReason } : {}),
      ...(text(x.label) ? { label: x.label } : {}),
      ...(Number.isInteger(x.personId) ? { personId: x.personId } : {}),
      ...(text(x.role) ? { role: x.role } : {}),
      ...(text(x.play) ? { play: x.play } : {}),
      ...(Number.isInteger(x.year) ? { year: x.year } : {}),
      ...(typeof x.importance === 'number' ? { importance: x.importance } : {}),
      ...(x.tint && typeof x.tint === 'object' ? { tint: { hue: Number(x.tint.hue) || 0, saturation: Number(x.tint.saturation ?? 1), brightness: Number(x.tint.brightness ?? 1) } } : {}),
      ...(x.effect && typeof x.effect === 'object' ? { effect: { trail: String(x.effect.trail ?? 'sparkle'), colors: list(x.effect.colors).filter(c => hex.test(c)) } } : {}),
      ...(hex.test(x.borderColor ?? '') ? { borderColor: x.borderColor } : {}),
    };
    // `thumb` goes by name, as in `loadCatalog`: the portrait at the size of the grid.
    const thumb = text(x.portrait) && /-portrait\.webp$/.test(x.portrait) ? x.portrait.replace(/-portrait\.webp$/, '-thumb.webp') : undefined;
    for (const key of pictureKeys) { const link = picture(key === 'thumb' ? thumb : x[key]); if (link) item[key] = link; }
    if (x.harness && typeof x.harness === 'object' && !Array.isArray(x.harness)) {
      const harness = Object.fromEntries(Object.entries(x.harness).filter(([pose, at]) => poses.has(pose) && Array.isArray(at) && at.length === 2 && at.every(Number.isFinite)));
      if (Object.keys(harness).length) item.harness = harness;
    }
    for (const key of ['collectibleNames', 'obstacleCrashLines']) {
      const names = x[key];
      if (names && typeof names === 'object' && !Array.isArray(names)) item[key] = Object.fromEntries(Object.entries(names).filter(([, v]) => text(v)));
    }
    items.push(item);
  }
  const view = { items, files };
  views.set(base, view);
  return view;
}

/** The scheduled release of each item id: `{ id, name, startsAt, active, part }`, part `items`, `gated` or `free`. */
function releasesById(t, at) {
  const byId = new Map();
  for (const r of t.runnerReleases ?? []) {
    const release = { id: r.id, name: r.name, startsAt: r.startsAt, active: releaseIsActive(r, at) };
    for (const [part, ids] of [['items', r.itemIds], ['gated', r.gatedItemIds], ['free', r.freeItemIds]]) for (const id of list(ids)) if (!byId.has(id)) byId.set(id, { ...release, part });
  }
  return byId;
}

/** GET /admin/runner/catalog: every entry of the wardrobe with its state, for admins only. */
export function adminRunnerCatalog(t, uid) {
  t.account(uid, true);
  const base = t.runnerBaseCatalog, live = t.runnerCatalog, at = t.clock();
  const releases = releasesById(t, at), disabled = disabledOf(base);
  const milestones = new Map((base.ensemble?.milestones ?? []).filter(m => m.item).map(m => [m.item, m.km]));
  const state = (x, isDisabled) => {
    const release = releases.get(x.id) ?? null;
    return {
      disabled: isDisabled, live: !isDisabled && live.byId.has(x.id), release,
      secret: x.unique ? 'unique' : x.reward ? 'reward' : null,
      ...(milestones.has(x.id) ? { milestoneKm: milestones.get(x.id) } : {}),
    };
  };
  const shown = x => Object.fromEntries(Object.entries(x).filter(([key]) => key !== 'music').map(([key, value]) => [key, pictureKeys.includes(key) ? adminLink(value) : value]));
  return {
    kinds: ['character', 'backdrop', 'obstacles', 'fx'],
    rarities: base.rarities.map(({ rank, ...r }) => r), departments: base.departments, dupes: base.dupes,
    ...(base.ensemble ? { ensembleRarity: base.ensemble.rarity } : {}),
    ...(base.uniqueRarity ? { uniqueRarity: base.uniqueRarity } : {}),
    items: [
      ...base.items.map(x => ({ ...shown(x), admin: state(x, false) })),
      ...disabled.items.map(x => ({ ...x, admin: state(x, true) })),
    ],
    releases: (t.runnerReleases ?? []).map(r => ({ id: r.id, name: r.name, startsAt: r.startsAt, active: releaseIsActive(r, at) })),
    serverTime: at.toISOString(),
  };
}

/**
 * GET /admin/runner/skins/<file>: a picture of the admins' view, whatever its state; the same 404
 * as an unknown file for anything else. Admins only.
 */
export function adminRunnerSkin(t, uid, name) {
  t.account(uid, true);
  const base = t.runnerBaseCatalog;
  const file = base.files.get(name) ?? disabledOf(base).files.get(name);
  if (!file || !fileName.test(name)) fail(404, 'Nicht gefunden.');
  return file;
}
