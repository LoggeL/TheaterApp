import { releasePackReady } from './runner-content-releases.mjs';
import { dropIsLive } from './runner-drop-push.mjs';

// The countdown to the next scheduled content drop (wardrobe/releases.json) in the game menu and in
// the wardrobe: `nextDrop` `{ id, name, startsAt, ready }` in every wardrobe view (GET
// /games/runner/wardrobe and the views crates, trades and outfits answer with), only while the
// next drop starts within `nextDropWindowMs` by the server's clock. `now` beside it is the server's
// time, so the app counts by that clock whatever the device says. Older apps ignore both.
// - `ready`: whether the drop will reach the players at its start, by the rule the drop push uses
//   (`dropIsLive`), asked of the catalog as deployed (`_runnerCatalog`, unreleased items included).
// - A role pack held back after its start (pictures missing, `releasePackReady`) keeps its card with
//   `ready: false` for up to a day, so the app says "Gleich soll es so weit sein …" instead of a
//   countdown at zero; a drop that went live is gone from the view. A drop still to come within the
//   window goes first: a held pack never hides its countdown.
// No push here: runner-drop-push.mjs announces the drop when it goes live.

export const nextDropWindowMs = 24 * 3600000;

const deployed = t => t._runnerCatalog ?? t.runnerCatalog;

/**
 * The drop to count down to at [at], or null: the earliest one still to start within the window;
 * only without one a started pack still held back (the earliest), so a held pack never hides the
 * countdown of a drop that is really coming.
 */
export function nextDrop(t, at = +t.clock()) {
  const base = deployed(t);
  let upcoming = null, held = null;
  const earlier = (release, than) => !than || Date.parse(release.startsAt) < Date.parse(than.startsAt);
  for (const release of t.runnerReleases ?? []) {
    const start = Date.parse(release.startsAt);
    if (start > at) {
      if (start - at < nextDropWindowMs && earlier(release, upcoming)) upcoming = release;
    } else if (
      // Started: only a pack still waiting for its pictures.
      at - start < nextDropWindowMs && release.itemIds.length && !releasePackReady(base, release) && earlier(release, held)
    ) {
      held = release;
    }
  }
  const next = upcoming ?? held;
  if (!next) return null;
  return { id: next.id, name: next.name, startsAt: next.startsAt, ready: next === upcoming && dropIsLive(base, next) };
}

/** The fields a wardrobe view carries: `nextDrop` and `now` while there is a drop, else none. */
export function nextDropFields(t) {
  const at = t.clock(), drop = nextDrop(t, +at);
  return drop ? { nextDrop: drop, now: new Date(at).toISOString() } : {};
}
