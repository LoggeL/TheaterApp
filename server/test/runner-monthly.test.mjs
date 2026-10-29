import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures, stageRunner } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { berlinMonth, monthBounds, monthScoresKind } from '../src/runner-monthly.mjs';

function setup(t, start = '2026-10-18T10:00:00Z') {
  const store = new Store(); t.after(() => store.close());
  const clock = { now: new Date(start) };
  const at = iso => { clock.now = new Date(iso); };
  const tick = (ms = 60000) => { clock.now = new Date(+clock.now + ms); };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.now });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `monthly-${++sequence}`);
  const person = (uid, name) => {
    const personId = action({ action: 'member.save', name }).id;
    app.session({ uid, name: `${name} (Login)`, email: `${uid}@example.invalid`, email_verified: true });
    action({ action: 'account.approve', uid, personId, version: 1, role: 'member' });
    return personId;
  };
  const sam = person('sam', 'Sam Beispiel'), kim = person('kim', 'Kim Muster');
  /** A run of one minute that ends at the current clock time with [score]. */
  const play = (uid, score) => { tick(-60000); const { roundId } = app.runnerStart(uid); tick(60000); return app.runnerScore(uid, { roundId, score }); };
  const month = (uid, m) => app.runnerLeaderboard(uid, { period: 'month', month: m });
  return { store, app, action, sam, kim, at, tick, play, month };
}

test('servers announce the Monatsrangliste', t => {
  const { app } = setup(t);
  assert.ok(apiFeatures.includes('runnerMonthlyLeaderboard'));
  assert.ok(app.snapshot('sam').capabilities.features.includes('runnerMonthlyLeaderboard'));
});

test('the month follows Berlin midnight on the first, in summer and in winter time', () => {
  // Winter time (UTC+1): 23:30 UTC on the last day is already 00:30 on the first.
  assert.equal(berlinMonth('2026-10-31T22:59:59.999Z'), '2026-10');
  assert.equal(berlinMonth('2026-10-31T23:00:00.000Z'), '2026-11');
  assert.equal(berlinMonth('2026-10-31T23:30:00.000Z'), '2026-11');
  // Summer time (UTC+2): the month changes at 22:00 UTC.
  assert.equal(berlinMonth('2026-08-31T21:59:59.999Z'), '2026-08');
  assert.equal(berlinMonth('2026-08-31T22:00:00.000Z'), '2026-09');
  assert.equal(berlinMonth('2026-12-31T23:30:00.000Z'), '2027-01');
  // October starts in summer and ends in winter time; March the other way round.
  assert.deepEqual(monthBounds('2026-10'), { startsAt: '2026-09-30T22:00:00.000Z', endsAt: '2026-10-31T23:00:00.000Z' });
  assert.deepEqual(monthBounds('2027-03'), { startsAt: '2027-02-28T23:00:00.000Z', endsAt: '2027-03-31T22:00:00.000Z' });
  assert.deepEqual(monthBounds('2026-12'), { startsAt: '2026-11-30T23:00:00.000Z', endsAt: '2026-12-31T23:00:00.000Z' });
});

test('the month list counts only the best run of this month; the all-time list stays', t => {
  const { app, sam, kim, at, play, month } = setup(t);
  at('2026-09-20T10:00:00Z'); play('sam', 400);
  at('2026-10-05T10:00:00Z'); play('sam', 150); play('kim', 200);
  at('2026-10-06T10:00:00Z'); play('sam', 120); play('kim', 180);
  const october = month('sam');
  assert.equal(october.period, 'month');
  assert.equal(october.month, '2026-10');
  assert.equal(october.endsAt, '2026-10-31T23:00:00.000Z');
  assert.equal(october.startsAt, '2026-09-30T22:00:00.000Z');
  assert.deepEqual(october.top.map(x => [x.rank, x.name, x.score]), [[1, 'Kim Muster', 200], [2, 'Sam Beispiel', 150]]);
  assert.deepEqual(october.own, { rank: 2, personId: sam, name: 'Sam Beispiel', score: 150, achievedAt: '2026-10-05T10:00:00.000Z' });
  assert.equal(october.players, 2);
  // All time: September's 400 still leads.
  assert.deepEqual(app.runnerLeaderboard('sam').top.map(x => [x.rank, x.personId, x.score]), [[1, sam, 400], [2, kim, 200]]);
  // A past month by name.
  assert.deepEqual(month('sam', '2026-09').top.map(x => [x.personId, x.score]), [[sam, 400]]);
});

test('a run at 23:30 UTC on the last day counts for the new month', t => {
  const { sam, at, play, month, store } = setup(t);
  at('2026-10-31T22:30:00Z'); play('sam', 300);
  at('2026-10-31T23:30:00Z');
  // Midnight has passed in Berlin: November starts empty, October keeps its list.
  assert.deepEqual(month('sam').top, []);
  assert.equal(month('sam').month, '2026-11');
  assert.equal(month('sam').endsAt, '2026-11-30T23:00:00.000Z');
  play('sam', 50);
  assert.deepEqual(month('sam').own, { rank: 1, personId: sam, name: 'Sam Beispiel', score: 50, achievedAt: '2026-10-31T23:30:00.000Z' });
  assert.equal(month('sam', '2026-10').own.score, 300);
  assert.equal(store.get(monthScoresKind, `2026-11:${sam}`).rounds, 1);
  assert.equal(store.get(monthScoresKind, `2026-10:${sam}`).best, 300);
});

test('equal month scores share a rank; zero, inactive and deleted people are not listed', async t => {
  const { app, action, store, sam, kim, tick, play, month } = setup(t);
  play('kim', 90); tick(); play('sam', 90); play('admin', 0);
  assert.deepEqual(month('admin').top.map(x => [x.rank, x.name]), [[1, 'Kim Muster'], [1, 'Sam Beispiel']]);
  assert.equal(month('admin').own, null);
  assert.ok(!JSON.stringify(month('admin')).includes('example.invalid'));
  action({ action: 'member.save', id: kim, name: 'Kim Muster', active: false, version: store.get('members', kim).version });
  assert.deepEqual(month('sam').top.map(x => x.personId), [sam]);
  await app.deleteAccount('admin', 'sam', store.account('sam').version);
  action({ action: 'member.delete', id: sam, version: store.get('members', sam).version });
  assert.equal(store.get(monthScoresKind, `2026-10:${sam}`), null);
  assert.deepEqual(month('admin').top, []);
});

test('the month list is limited while the own placement is always returned', t => {
  const { app, action, play, month } = setup(t);
  for (let i = 0; i < stageRunner.leaderboardSize + 2; i++) {
    const uid = `p${i}`, personId = action({ action: 'member.save', name: `Person ${i}` }).id;
    app.session({ uid, name: uid, email: `${uid}@example.invalid`, email_verified: true });
    action({ action: 'account.approve', uid, personId, version: 1, role: 'member' });
    play(uid, 100 + i);
  }
  play('sam', 10);
  const board = month('sam');
  assert.equal(board.top.length, stageRunner.leaderboardSize);
  assert.equal(board.own.rank, stageRunner.leaderboardSize + 3);
});

test('the current month is filled from all-time bests set in it before the deploy', t => {
  const { store, sam, kim, play, month } = setup(t);
  // Records from before the Monatsrangliste: only the all-time best with its time.
  store.put('runnerScores', sam, { personId: sam, best: 350, bestAt: '2026-10-02T18:00:00.000Z', rounds: 4, lastPlayedAt: '2026-10-02T18:00:00.000Z' });
  store.put('runnerScores', kim, { personId: kim, best: 500, bestAt: '2026-09-12T18:00:00.000Z', rounds: 9, lastPlayedAt: '2026-10-03T18:00:00.000Z' });
  assert.deepEqual(month('sam').top.map(x => [x.personId, x.score, x.achievedAt]), [[sam, 350, '2026-10-02T18:00:00.000Z']]);
  assert.deepEqual(month('sam', '2026-09').top.map(x => [x.personId, x.score]), [[kim, 500]]);
  // A lower run afterwards keeps the known month best; Kim joins with the next run.
  play('sam', 100); play('kim', 120);
  assert.deepEqual(month('sam').top.map(x => [x.personId, x.score]), [[sam, 350], [kim, 120]]);
  assert.equal(store.get(monthScoresKind, `2026-10:${sam}`).best, 350);
});

test('requests without a period get exactly the all-time list; bad periods and months are refused', t => {
  const { app, play } = setup(t);
  play('sam', 80);
  const old = app.runnerLeaderboard('sam');
  assert.deepEqual(Object.keys(old).sort(), ['own', 'players', 'top']);
  assert.deepEqual(app.runnerLeaderboard('sam', {}), old);
  assert.deepEqual(app.runnerLeaderboard('sam', { period: 'all' }), { period: 'all', ...old });
  assert.throws(() => app.runnerLeaderboard('sam', { period: 'week' }), { status: 400 });
  for (const month of ['2026-13', '2026-1', 'Oktober', '2026-10-01']) assert.throws(() => app.runnerLeaderboard('sam', { period: 'month', month }), { status: 400 });
  assert.throws(() => app.runnerLeaderboard('sam', { period: 'month', month: '2026-11' }), { status: 400 });
  assert.throws(() => app.runnerLeaderboard('pending', { period: 'month' }), { status: 403 });
});

test('the HTTP API gives the month list with ?period=month and the old list without', async t => {
  const { app, play } = setup(t);
  play('sam', 70);
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  const call = async (uid, path) => {
    const response = await fetch(`${base}${path}`, { headers: { Authorization: `Bearer ${uid}` } });
    return { status: response.status, body: await response.json() };
  };
  const monthly = await call('kim', '/games/runner/leaderboard?period=month');
  assert.equal(monthly.status, 200);
  assert.equal(monthly.body.month, '2026-10');
  assert.equal(monthly.body.endsAt, '2026-10-31T23:00:00.000Z');
  assert.deepEqual(monthly.body.top.map(x => [x.name, x.score]), [['Sam Beispiel', 70]]);
  assert.equal((await call('kim', '/games/runner/leaderboard?period=month&month=2026-09')).body.players, 0);
  assert.equal((await call('kim', '/games/runner/leaderboard?period=month&month=2027-01')).status, 400);
  const old = await call('kim', '/games/runner/leaderboard');
  assert.deepEqual(Object.keys(old.body).sort(), ['own', 'players', 'top']);
});
