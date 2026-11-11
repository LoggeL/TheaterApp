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
- At least five comparable measurements enable per-dimension empirical quantiles: easy p40,
  medium p60, hard p80 (lower order statistic, rounded down rather than beyond the quantile).
  Of ten recent runs about seven reach the easy target, five the medium and three the hard one.
  Until 2026-11-11 the quantiles were p50/p60/p70 (six, five and four of ten): hard was hardly
  harder than easy for more than three times the reward. The spread rests on that reasoning and
  on two players' samples, not on measured completion under policy 2 (the log of 2026-11-08 to
  2026-11-10 is from the record-fraction rules before). With independent runs the crate still has
  a median of about three runs; check with `mission-report.mjs` after a few days. Series and day
  distance keep the median run (`missionEffort.median`). Missions already made keep their targets.
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

No schema migration or historical-day rewrite. On the next authenticated mission fetch, reroll or
accepted run after server rollout, **already-generated open missions of the current Berlin day**
are balanced once (policy-version marker), inside the existing serialized SQLite transaction:

- Lower target numbers and series minimum distances only; never harden an existing goal.
- Preserve mission identity/type/kind/slot, actual progress (including series counts), rewards,
  completed missions, reroll usage, best records and every other person's data. Do not reconstruct
  previously failed lower-threshold runs from retry buffers. A series may therefore still need
  a new qualifying run even if an earlier unrecorded run would have qualified under the new minimum.
- Use recent timestamped measurements if available; otherwise capped cold-start goals. Existing
  specialties no longer eligible for generation retain their kind and get their conservative start
  cap. Types without a meaningful same-kind option (e.g. legacy `debut`, an unreachable `reach`)
  stay unchanged, with an explicit `unsupported-or-ineligible` reason in `effortRebalance.changes`.
- Explicit server-written per-mission `targetOverride.source=admin` for the same day is respected.
  This is not client-settable and does not establish a global floor or affect future days.
- If preserved progress meets the lowered target, the shared normal completion rules award the
  original points and, when all three are done, one crate. Existing done/crate flags and the policy
  marker prevent double grants, including retries. No payouts for previous days.
- Freeze the new basis for subsequent rerolls. Record before/after targets, progress, policy version
  and observation timestamp in the current log row and `runner.mission.rebalance` audit, without
  incrementing runs or fabricating historical completion times. Rebalance-earned crates have
  `crateCompletionSource=effortRebalance`, not an invented `crateRuns`/time-to-crate measurement.

Timestamped samples accumulate prospectively. First-day generation uses capped cold-start goals
until five comparable samples exist. No manual production-wide migration is needed or authorized
by merging. Rollout is lazy; merging alone is not evidence that all accounts have been adjusted.

### Rollback

Roll back server code through the documented deployer to the previous release. Do not restore a
whole database over later gameplay. Existing lowered targets, completed flags and granted rewards
must remain; reverting code does not claw back legitimate rewards. Any per-record rollback needs
a fresh backup, explicit approval and a compare-and-set review of `effortRebalance` against current
progress/rewards. Before any separately authorized live override, take an integrity-checked online
SQLite backup, rehearse on a disposable copy, then use a guarded transaction and verify unrelated
entities/history remain byte-for-byte unchanged. Store backups privately, outside the repository.

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
