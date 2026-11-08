import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures, runnerMaxMeters, stageRunner } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { berlinWeek, checkGhost, settleWeeks, weekAwardsKind, weekBounds, weekRunsKind, weeklyRules, weeksKind } from '../src/runner-weekly.mjs';
import { monthScoresKind } from '../src/runner-monthly.mjs';

// Wochenprobe: one course a week, three ranked runs per person, unlimited training.

function setup(t, begin = '2026-11-04T10:00:00Z') {
  const store = new Store(); t.after(() => store.close());
  const clock = { now: new Date(begin) };
  const at = iso => { clock.now = new Date(iso); };
  const tick = (ms = 60000) => { clock.now = new Date(+clock.now + ms); };
  let random = 0.25;
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.now, random: () => random });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `weekly-${++sequence}`);
  const person = (uid, name) => {
    const personId = action({ action: 'member.save', name }).id;
    app.session({ uid, name: `${name} (Login)`, email: `${uid}@example.invalid`, email_verified: true });
    action({ action: 'account.approve', uid, personId, version: 1, role: 'member' });
    return personId;
  };
  const sam = person('sam', 'Sam Beispiel'), kim = person('kim', 'Kim Muster'), lou = person('lou', 'Lou Probe');
  const week = () => berlinWeek(clock.now);
  const start = (uid, ranked = true, w = week()) => app.runnerStart(uid, { weekly: { week: w, ranked } });
  /** Ends the run [started] after [seconds] with its metres, [pickups] on top and a fitting ghost. */
  const finish = (uid, started, { seconds = 60, pickups = 0, ghost, ...extra } = {}) => {
    tick(seconds * 1000);
    const meters = Math.floor(runnerMaxMeters(seconds));
    return app.runnerScore(uid, { roundId: started.roundId, score: meters + pickups, meters, ...(ghost === undefined ? { ghost: ghostOf(seconds) } : ghost === null ? {} : { ghost }), ...extra });
  };
  const play = (uid, options = {}) => finish(uid, start(uid, options.ranked ?? true), options);
  const gage = personId => store.get('runnerProgress', personId)?.gage ?? 0;
  return { store, app, clock, at, tick, action, sam, kim, lou, week, start, finish, play, gage, setRandom: x => { random = x; } };
}

/** A ghost of a run of [seconds]: 20 samples a second from 0 s on, then the crash flag. */
function ghostOf(seconds, { crashed = true, flag = true, value = 128 } = {}) {
  const n = Math.floor(seconds * weeklyRules.hz) + 1;
  return Buffer.from([...Array(n).fill(value), ...(flag ? [crashed ? 1 : 0] : [])]).toString('base64');
}

test('servers announce the Wochenprobe', t => {
  const { app } = setup(t);
  assert.ok(apiFeatures.includes('runnerWeekly'));
  assert.ok(app.snapshot('sam').capabilities.features.includes('runnerWeekly'));
});

test('the week runs from Monday to Monday midnight in Berlin and is named by its ISO week', () => {
  // Winter time (UTC+1): Sunday 23:59:59 in Berlin is still week 45, midnight starts week 46.
  assert.equal(berlinWeek('2026-11-08T22:59:59.999Z'), '2026-W45');
  assert.equal(berlinWeek('2026-11-08T23:00:00.000Z'), '2026-W46');
  assert.deepEqual(weekBounds('2026-W46'), { startsAt: '2026-11-08T23:00:00.000Z', endsAt: '2026-11-15T23:00:00.000Z' });
  // The week of the spring switch starts in winter and ends in summer time.
  assert.deepEqual(weekBounds('2026-W13'), { startsAt: '2026-03-22T23:00:00.000Z', endsAt: '2026-03-29T22:00:00.000Z' });
  assert.equal(berlinWeek('2026-03-29T21:59:59.999Z'), '2026-W13');
  assert.equal(berlinWeek('2026-03-29T22:00:00.000Z'), '2026-W14');
  // ISO years: 1 January 2027 (a Friday) still belongs to 2026's week 53; 2027 has no week 53.
  assert.equal(berlinWeek('2027-01-01T12:00:00Z'), '2026-W53');
  assert.equal(berlinWeek('2027-01-04T12:00:00Z'), '2027-W01');
  assert.deepEqual(weekBounds('2027-W01'), { startsAt: '2027-01-03T23:00:00.000Z', endsAt: '2027-01-10T23:00:00.000Z' });
  assert.equal(weekBounds('2027-W53'), null);
  assert.equal(weekBounds('2026-W54'), null);
  assert.equal(weekBounds('2026-46'), null);
  assert.equal(weekBounds(46), null);
  // Every week of a few years follows the one before without a gap.
  for (let week = '2026-W01', i = 0; i < 160; i++) {
    const { endsAt } = weekBounds(week), next = berlinWeek(endsAt);
    assert.equal(weekBounds(next).startsAt, endsAt);
    week = next;
  }
});

test('one seed per week for everybody, made on the first request and then kept', t => {
  const { app, store, at, setRandom } = setup(t);
  setRandom(0.5);
  const first = app.runnerWeekly('sam');
  assert.equal(first.week, '2026-W45');
  assert.equal(first.seed, 2147483648);
  assert.deepEqual([first.startsAt, first.endsAt], ['2026-11-01T23:00:00.000Z', '2026-11-08T23:00:00.000Z']);
  assert.deepEqual(first.attempts, { used: 0, max: 3 });
  assert.equal(first.best, null);
  assert.deepEqual(first.leaderboard, []);
  assert.deepEqual(first.ghosts, []);
  assert.equal(first.lastWeek, null);
  setRandom(0.75);
  assert.equal(app.runnerWeekly('kim').seed, first.seed);
  assert.equal(app.runnerStart('lou', { weekly: { week: '2026-W45', ranked: false } }).weekly.seed, first.seed);
  // The next week: a new seed, the old one stays.
  at('2026-11-09T08:00:00Z');
  const next = app.runnerWeekly('sam');
  assert.equal(next.week, '2026-W46');
  assert.equal(next.seed, 3221225472);
  assert.deepEqual(store.all(weeksKind).map(x => [x.week, x.seed]), [['2026-W45', 2147483648], ['2026-W46', 3221225472]]);
  // Seeds stay whole unsigned 32-bit numbers, also at the top.
  setRandom(0.9999999999);
  at('2026-11-16T08:00:00Z');
  const top = app.runnerWeekly('sam').seed;
  assert.ok(Number.isInteger(top) && top >= 0 && top <= 0xFFFFFFFF);
});

test('three ranked attempts a week, counted at the start; training stays unlimited', t => {
  const { app, store, sam, start, finish, play, week } = setup(t);
  const one = start('sam');
  assert.deepEqual(one.weekly, { week: '2026-W45', seed: app.runnerWeekly('sam').seed, ranked: true, attempt: 1 });
  assert.equal(typeof one.roundId, 'string');
  assert.equal(typeof one.startedAt, 'string');
  // Counted at once, before any result; a run given up costs its attempt.
  assert.deepEqual(app.runnerWeekly('sam').attempts, { used: 1, max: 3 });
  assert.equal(start('sam').weekly.attempt, 2);
  const third = start('sam');
  assert.equal(third.weekly.attempt, 3);
  assert.throws(() => start('sam'), { status: 409, code: 'attempts_used' });
  // The result of an attempt started before still counts.
  assert.equal(finish('sam', third).weekly.attempts.used, 3);
  assert.throws(() => start('sam'), { status: 409, code: 'attempts_used' });
  // Training: as often as wanted, no attempt, on the same course.
  for (let i = 0; i < 8; i++) assert.deepEqual(play('sam', { ranked: false, seconds: 20 }).weekly.attempts, { used: 3, max: 3 });
  const training = start('sam', false);
  assert.equal(training.weekly.ranked, false);
  assert.equal(training.weekly.attempt, null);
  assert.equal(store.get(weekRunsKind, `${week()}:${sam}`).training, 8);
  assert.deepEqual(store.get(weekRunsKind, `${week()}:${sam}`).attempts.map(x => x.attempt), [1, 2, 3]);
  // Others have their own attempts; normal runs have no limit.
  assert.equal(start('kim').weekly.attempt, 1);
  for (let i = 0; i < 5; i++) app.runnerStart('sam');
});

test('parallel ranked starts never get beyond three', async t => {
  const { app } = setup(t);
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  const post = body => fetch(`${base}/games/runner/rounds`, { method: 'POST', headers: { Authorization: 'Bearer sam', 'Content-Type': 'application/json' }, body: JSON.stringify(body) }).then(async r => ({ status: r.status, body: await r.json() }));
  const answers = await Promise.all(Array.from({ length: 8 }, () => post({ weekly: { week: '2026-W45', ranked: true } })));
  const ok = answers.filter(x => x.status === 200);
  assert.equal(ok.length, 3);
  assert.deepEqual(ok.map(x => x.body.weekly.attempt).sort(), [1, 2, 3]);
  assert.deepEqual(answers.filter(x => x.status === 409).map(x => x.body.code), Array(5).fill('attempts_used'));
  assert.deepEqual(app.runnerWeekly('sam').attempts, { used: 3, max: 3 });
  // Training still starts, and so do normal runs, exactly as before (no body, an empty one).
  assert.equal((await post({ weekly: { week: '2026-W45', ranked: false } })).status, 200);
  const plain = await post({});
  assert.equal(plain.status, 200);
  assert.deepEqual(Object.keys(plain.body).sort(), ['roundId', 'startedAt']);
  const bare = await fetch(`${base}/games/runner/rounds`, { method: 'POST', headers: { Authorization: 'Bearer sam' } }).then(r => r.json());
  assert.deepEqual(Object.keys(bare).sort(), ['roundId', 'startedAt']);
  // The weekly view and the banner over HTTP.
  const view = await fetch(`${base}/games/runner/weekly`, { headers: { Authorization: 'Bearer sam' } }).then(r => r.json());
  assert.equal(view.week, '2026-W45');
  const seen = await fetch(`${base}/games/runner/weekly/seen`, { method: 'PUT', headers: { Authorization: 'Bearer sam', 'Content-Type': 'application/json' }, body: JSON.stringify({ week: 'gestern' }) });
  assert.equal(seen.status, 400);
});

test('only the current week starts; a run counts for the week it was started in', t => {
  const { app, store, sam, kim, at, start, finish } = setup(t);
  assert.throws(() => start('sam', true, '2026-W44'), { status: 409, code: 'week_over' });
  assert.throws(() => start('sam', false, '2026-W46'), { status: 409, code: 'week_over' });
  for (const weekly of [true, { week: '2026-W45' }, { week: '2026-45', ranked: true }, { week: '2026-W45', ranked: 'ja' }, []]) {
    assert.throws(() => app.runnerStart('sam', { weekly }), { status: 400 }, JSON.stringify(weekly));
  }
  assert.deepEqual(app.runnerWeekly('sam').attempts.used, 0);
  // Started on Sunday at 23:50 Berlin, the result arrives on Monday.
  at('2026-11-08T22:50:00Z');
  const late = start('sam');
  const result = finish('sam', late, { seconds: 20 * 60 });
  assert.equal(result.weekly.week, '2026-W45');
  assert.equal(result.weekly.rank, 1);
  assert.equal(store.get(weekRunsKind, `2026-W45:${sam}`).best, result.score);
  const now = app.runnerWeekly('sam');
  assert.equal(now.week, '2026-W46');
  assert.deepEqual(now.leaderboard, []);
  assert.deepEqual(now.attempts, { used: 0, max: 3 });
  // The new week's course needs the new week.
  assert.throws(() => start('kim', true, '2026-W45'), { status: 409, code: 'week_over' });
  assert.equal(start('kim').weekly.week, '2026-W46');
  assert.equal(store.get(weekRunsKind, `2026-W46:${kim}`).used, 1);
});

test('the best ranked run counts, ties go to the earlier one; training and normal runs do not rank', t => {
  const { app, store, sam, kim, lou, play, tick } = setup(t);
  const first = play('sam', { seconds: 60, pickups: 50 });
  assert.deepEqual(first.weekly, { week: '2026-W45', ranked: true, improved: true, best: { score: 560, meters: 510 }, rank: 1, attempts: { used: 1, max: 3 } });
  // The answer of a normal run as well: the all-time list stays as it was.
  assert.equal(first.improved, false);
  assert.deepEqual(first.leaderboard, { players: 0, top: [], own: null });
  assert.equal(first.progress.gained, 510);
  const worse = play('sam', { seconds: 40 });
  assert.equal(worse.weekly.improved, false);
  assert.deepEqual(worse.weekly.best, { score: 560, meters: 510 });
  // A better training run is only training.
  const training = play('sam', { ranked: false, seconds: 120 });
  assert.deepEqual([training.weekly.ranked, training.weekly.improved, training.weekly.best.score], [false, false, 560]);
  // The same score later ranks behind.
  tick();
  play('kim', { seconds: 60, pickups: 50 });
  play('lou', { seconds: 30 });
  const view = app.runnerWeekly('kim');
  assert.deepEqual(view.leaderboard.map(x => [x.rank, x.name, x.score, x.meters, x.me]), [[1, 'Sam Beispiel', 560, 510, false], [2, 'Kim Muster', 560, 510, true], [3, 'Lou Probe', 210, 210, false]]);
  assert.equal(view.leaderboard[0].personId, sam);
  assert.equal(view.leaderboard[0].at, store.get(weekRunsKind, `2026-W45:${sam}`).bestAt);
  assert.deepEqual(view.best, { score: 560, meters: 510 });
  assert.ok(!JSON.stringify(view).includes('example.invalid') && !JSON.stringify(view).includes('Login'));
  // Weekly runs never enter the all-time list, the month list or the Monatsgala; they count as runs
  // (beside the deaths of the progress, for the wardrobe's statistics).
  for (const id of [sam, kim, lou]) assert.deepEqual([store.get('runnerScores', id).best, store.get('runnerScores', id).bestAt], [0, null]);
  assert.equal(store.get('runnerScores', kim).rounds, 1);
  assert.ok(store.get('runnerScores', kim).lastPlayedAt);
  assert.deepEqual([app.runnerWardrobe('sam').stats.rounds, app.runnerWardrobe('sam').stats.untracked], [3, 0]);
  assert.deepEqual(app.runnerLeaderboard('sam').top, []);
  assert.deepEqual(store.all(monthScoresKind), []);
  assert.deepEqual(app.runnerLeaderboard('sam', { period: 'month' }).top, []);
  // A normal run does, and leaves the week alone.
  const { roundId } = app.runnerStart('lou');
  tick(60000);
  const normal = app.runnerScore('lou', { roundId, score: 900, meters: 510 });
  assert.equal(normal.improved, true);
  assert.equal(normal.weekly, undefined);
  assert.equal(app.runnerWeekly('lou').best.score, 210);
  assert.equal(store.get(monthScoresKind, `2026-11:${lou}`).best, 900);
  // They count for the progress like any run: metres, crate points, missions.
  assert.equal(store.get('runnerProgress', sam).meters, 510 + Math.floor(runnerMaxMeters(40)) + Math.floor(runnerMaxMeters(120)));
  assert.ok(store.get('runnerMissions', sam).runs >= 3);
});

test('a result sent again gets its first answer and counts once; the mode cannot change', t => {
  const { app, store, sam, start, tick } = setup(t);
  const started = start('sam');
  tick(60000);
  const body = { roundId: started.roundId, score: 530, meters: 510, ghost: ghostOf(60) };
  const first = app.runnerScore('sam', body);
  const again = app.runnerScore('sam', body);
  assert.deepEqual(again.weekly, first.weekly);
  assert.deepEqual(again.progress, first.progress);
  assert.equal(store.get(weekRunsKind, `2026-W45:${sam}`).ranked, 1);
  assert.equal(store.get('runnerProgress', sam).meters, 510);
  assert.throws(() => app.runnerScore('sam', { ...body, score: 600 }), { status: 409, code: 'round_unknown' });
  // A normal run stays normal, whatever its result says.
  const { roundId } = app.runnerStart('sam');
  tick(60000);
  const normal = app.runnerScore('sam', { roundId, score: 520, meters: 510, weekly: { week: '2026-W45', ranked: true }, ghost: ghostOf(60) });
  assert.equal(normal.weekly, undefined);
  assert.equal(store.get('runnerScores', sam).best, 520);
  assert.equal(store.get(weekRunsKind, `2026-W45:${sam}`).best, 530);
  // A weekly run needs its metres.
  const other = start('sam', false);
  tick(60000);
  assert.throws(() => app.runnerScore('sam', { roundId: other.roundId, score: 500 }), { status: 400, code: 'implausible' });
});

test('ghosts are checked against the run and kept only with a new best', t => {
  const { app, store, sam, kim, start, finish, play } = setup(t);
  // Malformed or not fitting the run: implausible, the run does not count, the attempt is gone.
  const fits = { meters: 510, elapsed: 60000 };
  for (const ghost of [42, 'kein base64!', 'QUJD=', ghostOf(30), ghostOf(90), Buffer.alloc(weeklyRules.maxSamples + 2, 128).toString('base64')]) {
    assert.throws(() => checkGhost(ghost, fits), { status: 400, code: 'implausible' }, String(ghost).slice(0, 20));
  }
  // Longer than the measured time allows, though the metres would fit it.
  assert.throws(() => checkGhost(ghostOf(120), { meters: Math.floor(runnerMaxMeters(120)), elapsed: 60000 }), { code: 'implausible' });
  const one = start('sam');
  assert.throws(() => finish('sam', one, { ghost: ghostOf(30) }), { status: 400, code: 'implausible' });
  assert.equal(app.runnerWeekly('sam').best, null);
  assert.deepEqual(app.runnerWeekly('sam').attempts.used, 1);
  // Fitting ones, with and without the crash flag; a sample more or less is fine.
  assert.deepEqual(checkGhost(ghostOf(60), fits), { y: Buffer.alloc(1201, 128).toString('base64'), crashed: true, samples: 1201 });
  assert.equal(checkGhost(ghostOf(60, { crashed: false }), fits).crashed, false);
  assert.deepEqual(checkGhost(ghostOf(60, { flag: false }), fits), { y: Buffer.alloc(1201, 128).toString('base64'), crashed: true, samples: 1201 });
  assert.equal(checkGhost(Buffer.alloc(1200, 128).toString('base64'), fits).samples, 1200);
  // A ranked run always has one: without (or with no samples) it is not plausible.
  for (const ghost of [null, undefined, '']) assert.throws(() => checkGhost(ghost, { meters: 0, elapsed: 1000 }), { status: 400, code: 'implausible' }, String(ghost));
  assert.equal(checkGhost(Buffer.alloc(1, 128).toString('base64'), { meters: 0, elapsed: 1000 }).samples, 1);

  play('sam', { seconds: 60 });
  // `character` (the figure of the ghost) has its own tests in runner-ghost-figures.test.mjs.
  const ghosts = app.runnerWeekly('kim').ghosts.map(({ character, ...x }) => x);
  assert.deepEqual(ghosts, [{ personId: sam, name: 'Sam Beispiel', rank: 1, score: 510, meters: 510, hz: 20, y: Buffer.alloc(1201, 128).toString('base64'), crashed: true, me: false }]);
  // A worse ranked run keeps the ghost of the best; training never makes one.
  play('sam', { seconds: 30, ghost: ghostOf(30, { value: 40 }) });
  play('sam', { ranked: false, seconds: 120, ghost: ghostOf(120, { value: 40 }) });
  assert.equal(store.get(weekRunsKind, `2026-W45:${sam}`).ghost.samples, 1201);
  // A ranked result without a ghost does not count (nor replace the ghost of the best); the
  // attempt is gone.
  const bare = start('kim');
  assert.throws(() => finish('kim', bare, { seconds: 70, ghost: null }), { status: 400, code: 'implausible' });
  const view = app.runnerWeekly('kim');
  assert.deepEqual(view.leaderboard.map(x => [x.personId, x.score]), [[sam, 510]]);
  assert.deepEqual(view.ghosts.map(x => [x.personId, x.rank, x.me]), [[sam, 1, false]]);
  assert.equal(store.get(weekRunsKind, `2026-W45:${sam}`).ghost.samples, 1201);
  assert.equal(view.attempts.used, 1);
});

test('after the week the places get their rewards exactly once, the banner shows until seen', t => {
  const { app, store, sam, kim, lou, at, play, gage, action } = setup(t);
  const extra = action({ action: 'member.save', name: 'Ria Rang' }).id;
  app.session({ uid: 'ria', name: 'Ria', email: 'ria@example.invalid', email_verified: true });
  action({ action: 'account.approve', uid: 'ria', personId: extra, version: 1, role: 'member' });
  play('kim', { seconds: 90 }); play('sam', { seconds: 80 }); play('lou', { seconds: 70 }); play('ria', { seconds: 20 });
  // Training alone is no participation.
  play('admin', { ranked: false, seconds: 100 });
  const before = new Map([sam, kim, lou, extra].map(id => [id, gage(id)]));
  const gains = () => [kim, sam, lou, extra].map(id => gage(id) - before.get(id));
  // The week ended, but results of runs still open may arrive for half an hour: not closed yet.
  at('2026-11-08T23:10:00Z');
  settleWeeks(app);
  assert.equal(app.runnerWeekly('kim').lastWeek, null);
  assert.equal(store.get(weekAwardsKind, '2026-W45'), null);
  at(new Date(Date.parse('2026-11-08T23:00:00Z') + stageRunner.roundTtlMs).toISOString());
  const view = app.runnerWeekly('sam');
  assert.deepEqual(view.lastWeek, { week: '2026-W45', rank: 2, score: Math.floor(runnerMaxMeters(80)), gage: 50, trophy: 'silver', crates: 1 });
  assert.deepEqual(gains(), [100, 50, 25, 0]);
  assert.equal(store.get('runnerProgress', store.account('admin').personId)?.gage ?? 0, 0);
  const awards = store.get(weekAwardsKind, '2026-W45');
  assert.deepEqual(awards.placements.map(x => [x.rank, x.personId, x.gage, x.crates, x.trophy]), [[1, kim, 100, 1, 'gold'], [2, sam, 50, 1, 'silver'], [3, lou, 25, 1, 'bronze'], [4, extra, 0, 1, undefined]]);
  assert.equal(awards.players, 4);
  assert.equal(awards.rules, weeklyRules.rules);
  // The week's ghosts are not needed any more; its best runs stay.
  assert.ok(store.all(weekRunsKind).every(x => x.ghost === null));
  assert.equal(store.get(weekRunsKind, `2026-W45:${kim}`).best, 900);
  // Again and again, and on a server started anew: nothing more.
  settleWeeks(app); app.runnerWeekly('kim'); app.runnerWeekly('lou');
  const restarted = new Theater(store, { clock: () => new Date('2026-11-10T08:00:00Z') });
  settleWeeks(restarted); restarted.runnerWeekly('sam');
  assert.deepEqual(gains(), [100, 50, 25, 0]);
  assert.deepEqual(['kim', 'sam', 'lou', 'ria', 'admin'].map(uid => app.runnerWardrobe(uid).progress.weeklyCrates), [1, 1, 1, 1, 0]);
  // The banner: once per person, until seen; other people still see theirs.
  assert.equal(app.runnerWeekly('sam').lastWeek.rank, 2);
  const seen = app.runnerWeeklySeen('sam', { week: '2026-W45' });
  assert.equal(seen.lastWeek, null);
  assert.equal(seen.week, '2026-W46');
  assert.equal(app.runnerWeekly('sam').lastWeek, null);
  assert.equal(app.runnerWeeklySeen('sam', { week: '2026-W45' }).lastWeek, null);
  assert.equal(app.runnerWeekly('kim').lastWeek.gage, 100);
  assert.deepEqual(app.runnerWeekly('ria').lastWeek, { week: '2026-W45', rank: 4, score: Math.floor(runnerMaxMeters(20)), gage: 0, trophy: null, crates: 1 });
  assert.equal(app.runnerWeekly('admin').lastWeek, null);
  assert.throws(() => app.runnerWeeklySeen('sam', { week: '2026-11' }), { status: 400 });
  assert.throws(() => app.runnerWeeklySeen('sam', {}), { status: 400 });
  // A late result of a week already closed cannot come: the run would be older than `roundTtlMs`.
  // The next week closes on its own, also when nobody played it.
  at('2026-11-23T08:00:00Z');
  app.runnerWeekly('kim');
  assert.deepEqual(store.get(weekAwardsKind, '2026-W46').placements, []);
  assert.equal(app.runnerWeekly('kim').lastWeek, null);
  // Nothing of it is ever pushed.
  assert.deepEqual(store.all('pushJobs'), []);
});

test('inactive people are hidden from the week, deleted ones leave it', async t => {
  const { app, store, action, sam, kim, lou, at, play } = setup(t);
  play('kim', { seconds: 90 }); play('sam', { seconds: 80 }); play('lou', { seconds: 70 });
  action({ action: 'member.save', id: kim, name: 'Kim Muster', active: false, version: store.get('members', kim).version });
  const view = app.runnerWeekly('sam');
  assert.deepEqual(view.leaderboard.map(x => [x.rank, x.personId]), [[1, sam], [2, lou]]);
  assert.deepEqual(view.ghosts.map(x => x.personId), [sam, lou]);
  // Also when the week is closed: no gage for an inactive person.
  at('2026-11-09T08:00:00Z');
  app.runnerWeekly('sam');
  assert.deepEqual(store.get(weekAwardsKind, '2026-W45').placements.map(x => [x.rank, x.personId]), [[1, sam], [2, lou]]);
  play('sam', { seconds: 30 });
  // Deleting the person removes their weekly records, ghosts and places; the others keep theirs.
  await app.deleteAccount('admin', 'sam', store.account('sam').version);
  action({ action: 'member.delete', id: sam, version: store.get('members', sam).version });
  assert.deepEqual(store.all(weekRunsKind).filter(x => x.personId === sam), []);
  assert.deepEqual(store.get(weekAwardsKind, '2026-W45').placements.map(x => [x.rank, x.personId]), [[2, lou]]);
  assert.deepEqual(app.runnerWeekly('lou').lastWeek, { week: '2026-W45', rank: 2, score: Math.floor(runnerMaxMeters(70)), gage: 50, trophy: 'silver', crates: 1 });
  assert.deepEqual(app.runnerWeekly('lou').leaderboard, []);
  assert.ok(store.all(weekRunsKind).some(x => x.personId === lou));
});

test('runs of older apps stay exactly as before', t => {
  const { app, store, sam, tick } = setup(t);
  const started = app.runnerStart('sam');
  assert.deepEqual(Object.keys(started).sort(), ['roundId', 'startedAt']);
  tick(60000);
  const result = app.runnerScore('sam', { roundId: started.roundId, score: 450 });
  assert.deepEqual(Object.keys(result).sort(), ['improved', 'leaderboard', 'progress', 'score']);
  assert.equal(result.improved, true);
  assert.equal(store.get('runnerScores', sam).best, 450);
  assert.deepEqual(store.all(weekRunsKind), []);
  // The weekly list knows nothing of it.
  assert.deepEqual(app.runnerWeekly('sam').leaderboard, []);
  // Its statistics with a debut by points (older apps send no `course`) still count.
  const next = app.runnerStart('sam');
  tick(60000);
  const stats = { rose: 44, mask: 0, star: 0, ground: 0, ceiling: 0, passed: { pile: 1 } };
  app.runnerScore('sam', { roundId: next.roundId, score: 520, meters: 300, missionStats: stats });
  assert.equal(store.get('runnerMissions', sam).best.passed.pile, 1);
});
