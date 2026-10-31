import { releaseIsActive, releasePackReady } from './runner-content-releases.mjs';

// The push when scheduled game content (wardrobe/releases.json) goes live. index.mjs calls
// `announceContentDrops` from its periodic worker, so the server's clock decides. Production runs
// one process, but the claim also holds for several on one database: the decision, the job and the
// marker share one SQLite write transaction, which reads the marker again.
//
// Store kind `runnerDropPush`, not `reminderSent`: the retention job purges that one.
// - `cutover` `{ at }`: noted on the first run. A release that started at or before it never
//   pushes, however recent: Creepshow may still be inside the catch-up window at the first deploy.
// - `release:<id>` `{ releaseId, sentAt, recipients }` once announced, never sent twice, also when
//   the plan moves the release later. `{ heldAt }` while the pack waits for pictures and
//   `{ skippedAt }` when it was found too late are the other states.
//
// Who hears of it: `dropRecipients`. The game is hidden, so the text does not name it either; admins
// see every job in the push diagnosis. The switch is the existing `direct` ("Pushes der Leitung"):
// docs/operations.md explains why there is no own kind. No deep link: the app has no target for
// the game (`AppTarget.fromUri`), so a tap opens the app as for other pushes without a target.

const kind = 'runnerDropPush';
const releaseKey = release => `release:${release.id}`;

/** How long after its start a drop is still announced, so a short server pause loses nothing. */
export const dropCatchUpMs = 24 * 3600000;

const present = (catalog, id) => {
  const item = catalog.byId.get(id);
  return !!item && (!['character', 'backdrop'].includes(item.kind) || typeof item.image === 'string');
};

/**
 * Whether the release really reached the players, given the catalog as released right now: a role
 * pack by the rule that releases it (`releasePackReady`). That rule says yes to a release without
 * roles, so a pure stage needs its own items: `disabled` ones are not in the catalog.
 */
export function dropIsLive(catalog, release) {
  if (release.itemIds.length) return releasePackReady(catalog, release);
  const stages = [...release.gatedItemIds, ...release.freeItemIds];
  return stages.length > 0 && stages.every(id => present(catalog, id));
}

/**
 * Approved accounts of active members with at least one run the server counted. `runnerProgress`
 * does not qualify (a mere look into the wardrobe writes one), nor does a started round.
 */
export const dropRecipients = t => t.store.accounts()
  .filter(a => a.status === 'approved' && a.personId && t.store.get('members', a.personId)?.active === true && t.store.get('runnerScores', a.personId)?.rounds > 0)
  .map(a => a.personId);

const cutover = t => {
  const s = t.store, known = s.get(kind, 'cutover');
  return known ?? s.transaction(() => s.get(kind, 'cutover') ?? s.put(kind, 'cutover', { at: t.clock().toISOString() }));
};

/** One step of a release that started after the cutover; re-read inside the write transaction. */
function settle(t, release, live, at) {
  const s = t.store, key = releaseKey(release), state = s.get(kind, key), when = new Date(at).toISOString();
  if (state?.sentAt || state?.skippedAt) return;
  if (!live) { if (!state) s.put(kind, key, { releaseId: release.id, heldAt: when }); return; }
  // A held pack starts for the players now, however long its pictures took.
  if (!state?.heldAt && at - Date.parse(release.startsAt) > dropCatchUpMs) { s.put(kind, key, { releaseId: release.id, skippedAt: when }); return; }
  const recipients = dropRecipients(t);
  if (recipients.length) t.enqueuePush({ title: `Neu: ${release.name}`, body: 'Jetzt freigeschaltet.', data: {}, recipientPersonIds: recipients, pushKind: 'direct' });
  s.put(kind, key, { releaseId: release.id, ...(state?.heldAt ? { heldAt: state.heldAt } : {}), sentAt: when, recipients: recipients.length });
}

/** Announces every release that became due; repeated calls and restarts change nothing. */
export function announceContentDrops(t) {
  if (!t.pushEnabled) return;
  const s = t.store, at = +t.clock(), since = Date.parse(cutover(t).at);
  for (const release of t.runnerReleases) {
    if (!releaseIsActive(release, at) || Date.parse(release.startsAt) <= since) continue;
    const state = s.get(kind, releaseKey(release));
    if (state?.sentAt || state?.skippedAt) continue;
    const live = dropIsLive(t.runnerCatalog, release);
    // Nothing to write while a pack stays on hold: no write lock every 15 seconds.
    if (live || !state) s.transaction(() => settle(t, release, live, at));
  }
}
