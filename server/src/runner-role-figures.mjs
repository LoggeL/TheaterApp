import { AppError } from './theater.mjs';

// Role figures of the stage runner's wardrobe (`runnerRoleFigures`, catalog `roleFigures: true`):
// every stage role of an actor is a figure of its own with its own rarity (see runner-wardrobe.mjs).
// Before, there was one figure per person and its other roles came as "role variants" from
// duplicates. This module moves the progress records over once and shows apps from before
// (Android 0.11.2, web clients not reloaded yet) the same ownership in the shape they know.
//
// - Migration (once per record, on its first use, `model: 2`): owned variants become owned figures
//   (the variant id is the figure's id), plainly as variants never shone; the worn variant becomes
//   the worn figure; owned items, shine, gage, crates, statistics and the ensemble stay as they are.
//   If Legacy was open under the old rule (all light blue characters of 0.11.2 owned, or a Legacy
//   item won), it stays open (`unlockedRarities`). Nothing is taken away: the old fields stay too.
//   (The own figures count as owned here as they did then; since `runnerGiftFigure` the next move,
//   runner-own-figures.mjs, keeps them in `owned`.)
// - Older apps (no `roles`): a figure with `variantOf` is shown as a role variant of the person's
//   figure it names. That figure counts as owned when it or one of its roles is owned (so every
//   owned figure can be seen and worn); without the figure itself its card wears one of the roles.
//   A role figure won from a crate shows as "Neue Rolle" of the person's figure.

const fail = (status, message, code) => { throw new AppError(status, message, code); };
const list = value => Array.isArray(value) ? value : [];

/** The progress model with role figures. */
export const roleFiguresModel = 2;
// The light blue characters of the catalog of 0.11.2: Legacy opened once all of them were owned.
export const legacyOpenedBy = Object.freeze(['character.linak', 'character.max', 'character.maximilian', 'character.marcella', 'character.jakob', 'character.lena', 'character.hendrik', 'character.maren']);

const roleOf = x => Object.fromEntries(['role', 'play', 'year'].filter(k => x[k] !== undefined).map(k => [k, x[k]]));
/** "Rolle (Stück, Jahr)": a variant's `name`, as apps before the structured fields show it. */
export const roleName = ({ role, play, year }) => {
  const where = [play, year].filter(v => v !== undefined).join(', ');
  return role ? (where ? `${role} (${where})` : role) : '';
};

/**
 * [p] moved to role figures, or null if it is there already (or the catalog has none). [at] is the
 * time of the move.
 */
export function migrateToRoleFigures(c, p, at) {
  if (!c.roleFigures || (p.model ?? 1) >= roleFiguresModel) return null;
  const variants = list(p.variants).filter(id => typeof id === 'string');
  const owned = [...new Set([...list(p.owned), ...variants])];
  const selected = { ...p.selected };
  const worn = p.selectedVariant?.[selected.character];
  if (typeof worn === 'string' && variants.includes(worn)) selected.character = worn;
  const had = new Set([...owned, ...c.items.filter(x => x.personId === p.personId).map(x => x.id)]);
  const legacy = c.rarity.has('legacy') && (legacyOpenedBy.every(id => had.has(id)) || owned.some(id => c.byId.get(id)?.rarities.includes('legacy')));
  return {
    ...p, owned, selected, model: roleFiguresModel, roleFiguresAt: at.toISOString(),
    ...(legacy ? { unlockedRarities: [...new Set([...list(p.unlockedRarities), 'legacy'])] } : {}),
  };
}

const older = new WeakMap();
/** The person's figure [base] as older apps know it: with its role figures as `variants`. */
function olderItem(c, base) {
  let items = older.get(c);
  if (!items) older.set(c, items = new Map());
  if (!items.has(base)) {
    const item = c.byId.get(base);
    const variants = (c.rolesOf.get(base) ?? []).filter(f => f.image).map(f => ({
      id: f.id, name: roleName(f), ...roleOf(f), image: f.image, ...(f.portrait ? { portrait: f.portrait } : {}), ...(f.harness ? { harness: f.harness } : {}),
    }));
    items.set(base, variants.length ? { ...item, variants } : item);
  }
  return items.get(base);
}

/** The wardrobe view [v] of [p] (who owns [owned]) for an app from before role figures. */
export function olderAppView(c, v, p, owned) {
  if (!c.baseOf.size) return v;
  const folded = id => c.baseOf.has(id);
  const mine = base => c.rolesOf.get(base).filter(f => owned.has(f.id)).map(f => f.id);
  const worn = v.selected.character, memory = p.selectedVariant ?? {};
  const selectedVariants = {};
  for (const base of c.rolesOf.keys()) {
    const roles = mine(base);
    if (!roles.length) continue;
    const pick = c.baseOf.get(worn) === base ? worn : roles.includes(memory[base]) ? memory[base] : owned.has(base) ? null : roles[0];
    if (pick) selectedVariants[base] = pick;
  }
  const shown = id => !folded(id) && (owned.has(id) || (c.rolesOf.has(id) && mine(id).length > 0));
  return {
    ...v,
    catalog: { ...v.catalog, items: v.catalog.items.filter(x => !folded(x.id)).map(x => c.rolesOf.has(x.id) ? olderItem(c, x.id) : x) },
    owned: c.items.filter(x => shown(x.id)).map(x => x.id),
    selected: { ...v.selected, character: c.baseOf.get(worn) ?? worn },
    shiny: v.shiny.filter(id => !folded(id)),
    variants: v.owned.filter(folded), selectedVariants,
  };
}

/** A crate's result for an older app: a won role figure as a new role of the person's figure. */
export function olderAppOpening(c, result) {
  const reel = result.reel.map(id => c.baseOf.get(id) ?? id), base = c.baseOf.get(result.item.id);
  if (!base) return { ...result, reel };
  const figure = result.item;
  const outcome = result.outcome?.type === 'new' ? { ...result.outcome, type: 'variant', variant: { id: figure.id, name: roleName(figure), ...roleOf(figure) } } : result.outcome;
  return { ...result, item: olderItem(c, base), reel, ...(outcome ? { outcome } : {}) };
}

/** A trade's or purchase's result for an older app: a role figure shows as the person's figure. */
export function olderAppDeal(c, result) {
  const base = c.baseOf.get(result.item.id);
  return base ? { ...result, item: olderItem(c, base) } : result;
}

/**
 * What an older app's "wear [item]" (a person's figure with roles) means: `variant` an owned role
 * of it, null the figure itself; without one the role worn last with it (else the figure, else one
 * of its roles). Returns the figure to wear and the remembered roles; the caller checks ownership.
 */
export function olderAppOutfit(c, p, owned, item, variant) {
  const memory = { ...p.selectedVariant };
  if (variant === null) {
    delete memory[item.id];
    return { wear: item.id, selectedVariant: memory };
  }
  if (variant !== undefined) {
    if (c.baseOf.get(variant) !== item.id) fail(404, 'Diese Rolle gibt es nicht.');
    if (!owned.has(variant)) fail(409, 'Diese Rolle hast du noch nicht.', 'not_owned');
    memory[item.id] = variant;
    return { wear: variant, selectedVariant: memory };
  }
  const roles = c.rolesOf.get(item.id).filter(f => owned.has(f.id)).map(f => f.id);
  return { wear: roles.includes(memory[item.id]) ? memory[item.id] : owned.has(item.id) ? item.id : roles[0] ?? item.id, selectedVariant: memory };
}
