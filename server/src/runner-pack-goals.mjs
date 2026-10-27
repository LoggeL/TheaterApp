// Each released skin set starts a separate ensemble goal. Only approved runs after its release
// count; existing lifetime metres and old ensemble rewards never enter this counter. The first
// active access freezes the complete set and reward amount so later catalog changes cannot turn
// an earned set crate into a random crate. Call mutations inside the caller's run/open transaction.

const goalsKind = 'runnerPackGoals';
const contributionsKind = 'runnerPackContributions';
const key = (releaseId, personId) => `${releaseId}:${personId}`;
const activeMember = (t, personId) => t.store.get('members', personId)?.active === true;
const instant = at => at instanceof Date ? +at : Date.parse(at);
const releases = t => Array.isArray(t.runnerReleases) ? t.runnerReleases : [];

function activeGoals(t, at = t.clock()) {
  const now = instant(at);
  return releases(t).filter(r => typeof r.id === 'string' && r.id && typeof r.name === 'string'
    && Number.isFinite(r.goalMeters) && r.goalMeters > 0
    && Number.isInteger(r.crateCount) && r.crateCount > 0
    && Number.isFinite(Date.parse(r.startsAt)) && now >= Date.parse(r.startsAt));
}

/** Initializes only complete, illustrated sets. No missing item or art is silently replaced. */
function goalState(t, release) {
  const existing = t.store.get(goalsKind, release.id);
  if (existing) return existing;
  const itemIds = [...new Set(Array.isArray(release.itemIds) ? release.itemIds : [])];
  if (!itemIds.length || itemIds.some(id => {
    const item = t.runnerCatalog.byId.get(id);
    return !item || item.default || item.reward || item.unique
      || (['character', 'backdrop'].includes(item.kind) && !(typeof item.image === 'string' && item.image.length > 0));
  })) return null;
  const activationAt = t.clock().toISOString();
  return t.store.put(goalsKind, release.id, {
    releaseId: release.id, name: release.name, startsAt: release.startsAt,
    goalMeters: release.goalMeters, crateCount: release.crateCount, itemIds,
    meters: 0, contributors: 0, initializedAt: activationAt, activationAt,
  });
}

const contribution = (t, goal, personId) => t.store.get(contributionsKind, key(goal.releaseId, personId));
const balance = entry => Math.max(0, (entry?.grantedCrates ?? 0) - (entry?.opened ?? 0));

/** Counts one already validated, idempotently submitted run. A completed goal never gains entrants. */
export function recordPackRun(t, personId, meters, at = t.clock()) {
  if (!Number.isFinite(meters) || meters <= 0 || !activeMember(t, personId)) return packGoalsView(t, personId);
  // Both the server-recorded run start and its finish must be on/after the release boundary.
  // The caller supplies the trusted start when available; old callers use the current server time.
  const runAt = instant(at), serverAt = +t.clock();
  if (!Number.isFinite(runAt) || runAt > serverAt) return packGoalsView(t, personId);
  for (const release of activeGoals(t, new Date(Math.min(runAt, serverAt)))) {
    const goal = goalState(t, release);
    if (!goal || goal.reachedAt) continue;
    // runnerStart initializes ready goals before recording the round start. If art arrives late,
    // a round already in progress cannot count retroactively toward the new goal. Older saved
    // goals without this field retain their original release boundary.
    const activeSince = Math.max(Date.parse(goal.startsAt), Date.parse(goal.activationAt ?? goal.startsAt));
    if (runAt < activeSince) continue;
    const previous = contribution(t, goal, personId);
    const member = {
      ...(previous ?? {}), releaseId: goal.releaseId, personId,
      meters: (previous?.meters ?? 0) + meters, lastRunAt: new Date(serverAt).toISOString(),
    };
    t.store.put(contributionsKind, key(goal.releaseId, personId), member);
    const next = {
      ...goal, meters: goal.meters + meters,
      contributors: goal.contributors + (previous ? 0 : 1),
    };
    if (next.meters >= next.goalMeters) {
      next.reachedAt = new Date(serverAt).toISOString();
      // Freeze the awards at completion. A new/later active member does not retrospectively earn
      // them; a contributor who becomes inactive can retain an already earned unopened award.
      for (const entry of t.store.all(contributionsKind)) {
        if (entry.releaseId !== goal.releaseId || !(entry.meters > 0) || !activeMember(t, entry.personId)) continue;
        t.store.put(contributionsKind, key(goal.releaseId, entry.personId), {
          ...entry, grantedCrates: goal.crateCount, grantedAt: next.reachedAt, opened: entry.opened ?? 0,
        });
      }
    }
    t.store.put(goalsKind, goal.releaseId, next);
  }
  return packGoalsView(t, personId);
}

/** The personal view contains no other member's name, id, or individual contribution. */
export function packGoalsView(t, personId) {
  return activeGoals(t).flatMap(release => {
    const goal = goalState(t, release);
    if (!goal) return [];
    const own = contribution(t, goal, personId), active = activeMember(t, personId);
    return [{
      releaseId: goal.releaseId, name: goal.name, startsAt: goal.startsAt,
      goalMeters: goal.goalMeters, meters: goal.meters, contributionMeters: own?.meters ?? 0,
      contributors: goal.contributors, reached: !!goal.reachedAt,
      ...(goal.reachedAt ? { reachedAt: goal.reachedAt } : {}),
      crateCount: goal.crateCount, crates: active ? balance(own) : 0,
      eligible: active && (goal.reachedAt ? (own?.grantedCrates ?? 0) > 0 : (own?.meters ?? 0) > 0),
    }];
  });
}

/** Finds an earned crate, bound to the immutable item pool of that goal. */
export function nextPackCrate(t, personId, releaseId = null) {
  if (!activeMember(t, personId)) return null;
  for (const release of activeGoals(t)) {
    if (releaseId != null && release.id !== releaseId) continue;
    const goal = goalState(t, release);
    if (!goal?.reachedAt) continue;
    const remaining = balance(contribution(t, goal, personId));
    if (remaining > 0) return { releaseId: goal.releaseId, name: goal.name, itemIds: [...goal.itemIds], remaining };
  }
  return null;
}

/** Consumes one earned crate. Retry protection is the enclosing opening's idempotency key. */
export function markPackCrateOpened(t, personId, releaseId) {
  const crate = nextPackCrate(t, personId, releaseId);
  if (!crate) return false;
  const id = key(releaseId, personId), own = t.store.get(contributionsKind, id);
  t.store.put(contributionsKind, id, { ...own, opened: (own.opened ?? 0) + 1, lastOpenedAt: t.clock().toISOString() });
  return true;
}
