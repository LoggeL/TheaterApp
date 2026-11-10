// Effort budget: the whole three-mission crate should have median completion <= 10 runs,
// not a ten-run history mistaken for that outcome. Sample quantiles are estimates, not guarantees.
export const missionEffort = Object.freeze({ version: 2, window: 10, minSamples: 5, maxAgeDays: 30,
  completionRuns: 10, quantile: { easy: 0.5, medium: 0.6, hard: 0.7 }, seriesCount: 2, dailyRuns: 3 });

const quantile = (values, q) => [...values].sort((a, b) => a - b)[Math.floor((values.length - 1) * q)];

/** null means cold start; [] means measured but not offered (including zero specialty values). */
export function recentMissionOptions(type, slot, ctx, nice, debuts) {
  const recent = ctx.recent ?? [], r = ctx.rules.types[type];
  if (recent.length < missionEffort.minSamples) return null;
  const q = missionEffort.quantile[slot];
  const values = fn => recent.map(fn).filter(v => Number.isFinite(v) && v >= 0);
  // Never round upward across the empirical success quantile.
  const target = (vs, min, max, percentile = q) => {
    if (vs.length < missionEffort.minSamples) return null;
    const v = quantile(vs, percentile);
    return v < min ? null : Math.min(max, Math.floor(v), nice(v));
  };
  const option = (vs, min, max) => { const t = target(vs, min, max); return t === null ? [] : [{ target: t }]; };
  const metres = values(x => x.m);
  switch (type) {
    case 'distance': return option(metres, r.min, r.max);
    case 'points': return option(values(x => x.s), r.min, r.max);
    case 'ground': case 'ceiling': return option(values(x => x.st?.[type]), r.min, r.max);
    case 'noPickup': return option(values(x => x.st ? x.st.beforePickup ?? (x.m === x.s ? x.m : 0) : undefined), r.min, r.max);
    case 'collect': return Object.entries(r.kinds).flatMap(([kind, k]) => option(values(x => x.st?.[kind]), k.min, r.max).map(o => ({ kind, ...o })));
    case 'pass': return ['crate', 'flat', 'lamp', 'border', 'sandbag', ...debuts.map(([, k]) => k)]
      .flatMap(kind => option(values(x => x.st ? x.st.passed?.[kind] ?? 0 : undefined), debuts.some(([, k]) => k === kind) ? r.debutMin : r.min, r.max).map(o => ({ kind, ...o })));
    case 'runs': {
      const min = target(metres, r.min, r.max, missionEffort.quantile.easy);
      return min === null ? [] : [{ target: missionEffort.seriesCount, min }];
    }
    case 'dailyDistance': {
      const base = target(metres, 1, r.max, missionEffort.quantile.easy);
      return base === null ? [] : [{ target: Math.min(r.max, base * missionEffort.dailyRuns) }];
    }
    case 'reach': {
      const distance = target(metres, 1, Infinity);
      const hit = debuts.findLast(([m]) => m <= distance);
      return hit ? [{ kind: hit[1], target: hit[0] }] : [];
    }
    default: return [];
  }
}
