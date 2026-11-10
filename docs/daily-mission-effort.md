# Daily mission effort, policy 2

## Acceptance target

**The complete daily crate (all three missions), median completion at most 10 runs.**
This is not a ten-run sampling-window requirement and not a guarantee for every player/day.
Missions advance in parallel. Total runs played in a day are a different metric: a player can
keep playing after earning the crate. In particular, the observed 26.5 daily runs on 2026-11-09
were NOT a measured 26.5-run median time to the crate.

## Generation

- Keep the latest 10 timestamped accepted **ordinary** runs of at least 20 m, at most 30 days old.
  No per-run identifiers, client timestamps or indefinite trace. Retry responses are deduplicated
  before recording; weekly/training runs still progress missions but do not enter the ordinary basis.
- At least five comparable measurements enable per-dimension empirical quantiles: easy p50,
  medium p60, hard p70 (lower order statistic, rounded down rather than beyond the quantile).
  Real zero measurements count. Missing statistics do not masquerade as zero or a measured record.
  Unsupported/too-rare specialties are omitted instead of forced up to an unattainable minimum.
- `noPickup` uses only its own before-first-pickup measurements (older checked statistics: a
  wholly pickup-free run), never 60% of normal distance. Its minimum is 5 m, not 80 m.
- `runs` requires **two** median-threshold successes, not three record-fraction successes.
  `dailyDistance` budgets three recent median runs. Reaching/passing late obstacles must be
  supported by that dimension's samples, not a normal-distance record from a different run.
- Allocate hard, medium, then easy, returning the usual easy/medium/hard order. This reserves
  scarce eligible types so beginners/older clients still receive three distinct missions.
- Before sufficient timestamped samples exist, lifetime fractions may LOWER conservative start
  targets, never exceed them. Distance starts 100/150/200 m, points 120/200/300, day distance
  at most 300 m, series two runs of at most 60/80 m, no-pickup at most 10/15/20 m and only with
  its own measured record. The old timestamp-less retry buffer is not fabricated into recent history.
- Freeze the generation basis for the Berlin day, including rerolls. Retain best records separately;
  administrative leaderboard scores cannot inflate the adaptive basis. Sustained lower performance
  can lower future targets; intentional sandbagging cannot be fully distinguished from real decline.

The quantiles deliberately leave slack below the ten-run median budget. With stable representative
performance, each offered single-run target has a substantial success rate; three parallel slots
are not three sequential ten-run tasks. Ten samples still have sampling error, and deliberate
specialty choices/change of play style break a stationary-performance assumption.

## Compatibility and rollout

No schema migration, historical rewrite, reward reset or retrospective payout. Missions already
created for a day keep their goals, progress, completed status, rewards and crate flag; policy 2
applies when creating new missions (including a requested reroll). Timestamped samples accumulate
prospectively. The first new day uses capped cold-start goals until five comparable samples exist.
Existing reward/idempotency paths remain unchanged.

**A push to `main` currently triggers the workflow's Google Play release job.** For a code/push-only
request with no deployment authorization, push the feature branch; do not trigger that release
or alter/disable its workflow to bypass the restriction. Deployment is a separate operation.

## Verification and limits

- Regression tests exercise record outliers, sustained decline, specialty zeros/missing statistics,
  no-pickup domain separation, day freezing, stale samples, retry/weekly exclusion, full three-slot
  allocation, reward compatibility and the whole-crate completion metric.
- Seeded **synthetic**, independent future-run simulation: five skill fixtures × two client modes ×
  1,000 person-days = 10,000 simulated person-days, including 20% instant exits in future attempts.
  Each fixture's whole-crate median was **3–4 runs**; 887–983 of 1,000 completed by run 10.
  Failures remain in the denominator. Reproduce with:
  `cd server && node --test test/runner-mission-effort.test.mjs`.
- Pure, read-only generation against the investigated actual saved bests gives 100 m easy distance
  and 2 × 80 m medium series for the reported high-record/low-typical case (previously 575 m and
  3 × 625 m). The reported no-pickup outlier is capped at 20 m hard, rather than 210 m.
  These are **cold-start policy comparisons**, not changed live missions or a historical replay.
- The 87 saved targets and timestamp-less last-ten retry results cannot reconstruct full historical
  per-run specialty traces or prove a counterfactual production completion median <=10.
- On earning a new crate, log `data.crateRuns` as the absolute day-run count at that instant,
  including runs before a reroll. Do not replace it with later total `dayRuns` or the replacement's
  relative `runs_to_done`. The read-only `server/scripts/mission-report.mjs` reports completion p50,
  measurement count and crates by run 10 alongside played days. Old unknown completion times
  remain unknown. Interpret completion-only medians with the played/unfinished denominator,
  missing measurements and sample size; do not claim live target attainment from simulation.
