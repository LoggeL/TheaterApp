// The person's own figures in the stage runner's wardrobe (`runnerGiftFigure`): the role figures of
// the catalog with the person's `personId` (see runner-wardrobe.mjs). Until this change everybody
// owned all of them at once, gold ones included; now one of them is a gift and the others are
// collected like everybody else's.
//
// - Gift (`gift` in `runnerProgress`): exactly one own figure, the active one (in the catalog, not
//   `disabled`, not held back by a release, with its picture) of the most common rarity (the
//   catalog's order of `rarities`, by the figure's main rarity; Legacy and Technik in their place
//   like any other), then the least `importance` (none counts as the most), then by id. Chosen once
//   and kept: a role figure added later never swaps it. Without such a figure (none in the catalog,
//   or all without a picture) there is no gift yet; it is chosen as soon as one is ready.
// - The gift goes into `owned` like a won item; everything else that person plays is in the crates
//   (also aimed ones), in trades and purchases, with duplicates and shine as for anyone.
// - Engel Logge (the catalog's default character) is only the stand-in for people without a gift:
//   whoever has one neither owns nor wears it, a worn one (or any figure no longer owned) falls back
//   to the gift. Everybody else keeps Engel Logge as before.
// - Bestandsschutz: what was owned under the old rule stays owned. On the first use of this code
//   the person's own figures in the catalog then (`runnerOwnFigures/cutover`, by person) are noted
//   once; every record from before (no `ownFigures` yet) gets those of its person into `owned`, once
//   (`ownFigures: 1`, `ownFiguresAt`, `ownFiguresKept`). A figure added to the catalog after the
//   switch is not kept, it is collected. Uniques and Legacy opened before stay open anyway
//   (`uniques`, `unlockedRarities` only ever grow).
// - People without a record: a record is created on the first wardrobe request or run, so whoever
//   opened the wardrobe or played since it exists has one. A person with runs (`runnerScores`) but
//   no record played only before the wardrobe existed and would have owned all own figures on the
//   first look: they keep them as well. A record created after the switch for someone who never
//   played gets only the gift.

const list = value => Array.isArray(value) ? value : [];
const cutoverKey = ['runnerOwnFigures', 'cutover'];

/** The progress model of own figures: gift plus kept figures instead of owning all of them. */
export const ownFiguresModel = 1;

/** The person's own figures in [c]: characters with their `personId`. */
export const ownFigures = (c, personId) => personId === null || personId === undefined ? [] : c.items.filter(x => x.kind === 'character' && x.personId === personId);

/** The figure [personId] gets as a gift from [c] now, or null if none is ready. */
export function giftFigure(c, personId) {
  const rank = x => c.rarity.get(x.rarity)?.rank ?? Infinity, importance = x => x.importance ?? Infinity;
  const ready = ownFigures(c, personId).filter(x => x.image && !x.default && !x.reward && !x.unique);
  return ready.sort((a, b) => rank(a) - rank(b) || importance(a) - importance(b) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))[0] ?? null;
}

/** The gift [p] has and the catalog still has, or null: only then is Engel Logge not theirs. */
export const giftOf = (c, p) => typeof p?.gift === 'string' && c.byId.get(p.gift)?.kind === 'character' ? p.gift : null;

/**
 * The own figures everybody owned at the switch, by person (`{ at, figures: { [personId]: ids } }`);
 * noted on first use from the catalog of that moment, then never changed.
 */
export function ownFiguresCutover(t) {
  const existing = t.store.get(...cutoverKey);
  if (existing) return existing;
  const figures = {};
  for (const x of t.runnerCatalog.items) if (x.kind === 'character' && Number.isInteger(x.personId)) (figures[x.personId] ??= []).push(x.id);
  return t.store.put(...cutoverKey, { at: t.clock().toISOString(), figures });
}

/**
 * [p] with its own figures settled, or null if nothing changes: once per record the figures kept
 * from before the switch ([cutover]), and the gift as soon as one is ready. [fresh]: the record is
 * created just now; it keeps figures only if the person [played] before.
 */
export function settleOwnFigures(c, p, cutover, at, { fresh = false, played = false } = {}) {
  let next = p;
  if ((p.ownFigures ?? 0) < ownFiguresModel) {
    const kept = !fresh || played ? list(cutover?.figures?.[p.personId]) : [];
    const owned = list(p.owned);
    next = {
      ...p, owned: [...owned, ...kept.filter(id => !owned.includes(id))], ownFigures: ownFiguresModel, ownFiguresAt: at.toISOString(),
      ...(kept.length ? { ownFiguresKept: kept } : {}),
    };
  }
  if (typeof next.gift !== 'string') {
    const gift = giftFigure(c, p.personId);
    if (gift) next = { ...next, gift: gift.id, owned: list(next.owned).includes(gift.id) ? list(next.owned) : [...list(next.owned), gift.id] };
  }
  return next === p ? null : next;
}
