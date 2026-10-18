import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures, stageRunner, runnerMaxMeters, runnerMaxScore } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const clock = { now: new Date('2026-10-18T10:00:00Z') };
  const tick = (ms = 60000) => { clock.now = new Date(+clock.now + ms); };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.now });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `runner-${++sequence}`);
  const person = (uid, name) => {
    const personId = action({ action: 'member.save', name }).id;
    app.session({ uid, name: `${name} (Login)`, email: `${uid}@example.invalid`, email_verified: true });
    action({ action: 'account.approve', uid, personId, version: 1, role: 'member' });
    return personId;
  };
  const sam = person('sam', 'Sam Beispiel'), kim = person('kim', 'Kim Muster');
  app.session({ uid: 'pending', name: 'Neu', email: 'pending@example.invalid', email_verified: true });
  /** Runs for [ms] and submits [score]. */
  const play = (uid, score, ms = 60000) => { const { roundId } = app.runnerStart(uid); tick(ms); return app.runnerScore(uid, { roundId, score }); };
  return { store, app, action, sam, kim, tick, play };
}

test('servers announce the runner', t => {
  const { app } = setup(t);
  assert.ok(apiFeatures.includes('stageRunner'));
  assert.ok(!apiFeatures.includes('propsGame'));
  assert.ok(app.snapshot('sam').capabilities.features.includes('stageRunner'));
});

test('the plausible maximum follows the speed curve and the measured time', () => {
  const { startSpeed, acceleration, maxSpeed, metersPerUnit } = stageRunner;
  assert.equal(runnerMaxMeters(0), 0);
  assert.ok(Math.abs(runnerMaxMeters(10) - (startSpeed * 10 + acceleration * 50) * metersPerUnit) < 1e-9);
  // After reaching the top speed the distance grows linearly.
  const top = (maxSpeed - startSpeed) / acceleration;
  assert.ok(Math.abs(runnerMaxMeters(top + 10) - runnerMaxMeters(top) - maxSpeed * 10 * metersPerUnit) < 1e-9);
  assert.ok(runnerMaxScore(0) > 0, 'a little slack for network delays');
  assert.ok(runnerMaxScore(60000) > runnerMaxScore(30000));
  // One minute: about 450 m plus pickups; far below a made-up million.
  assert.ok(runnerMaxScore(60000) < 5000);
});

test('the best score per person is kept and ranked with the current name', t => {
  const { app, action, store, sam, kim, play } = setup(t);
  assert.deepEqual(app.runnerLeaderboard('sam'), { players: 0, top: [], own: null });
  assert.equal(play('sam', 420).improved, true);
  assert.equal(play('sam', 300).improved, false);
  play('kim', 570);
  const board = app.runnerLeaderboard('sam');
  assert.deepEqual(board.top.map(x => [x.rank, x.name, x.score]), [[1, 'Kim Muster', 570], [2, 'Sam Beispiel', 420]]);
  assert.deepEqual(board.own, { rank: 2, personId: sam, name: 'Sam Beispiel', score: 420, achievedAt: '2026-10-18T10:01:00.000Z' });
  assert.equal(store.get('runnerScores', sam).rounds, 2);
  action({ action: 'member.save', id: kim, name: 'Kim Neu', version: store.get('members', kim).version });
  assert.equal(app.runnerLeaderboard('kim').top[0].name, 'Kim Neu');
  assert.ok(!JSON.stringify(board).includes('Login'));
  assert.ok(!JSON.stringify(board).includes('example.invalid'));
});

test('equal scores share a rank, the earlier best first; zero scores are not listed', t => {
  const { app, play } = setup(t);
  play('kim', 200); play('sam', 200); play('admin', 0);
  const board = app.runnerLeaderboard('admin');
  assert.deepEqual(board.top.map(x => [x.rank, x.name]), [[1, 'Kim Muster'], [1, 'Sam Beispiel']]);
  assert.equal(board.own, null);
  assert.equal(board.players, 2);
});

test('the top list is limited while the own placement is always returned', t => {
  const { app, action, play } = setup(t);
  for (let i = 0; i < stageRunner.leaderboardSize + 2; i++) {
    const uid = `p${i}`, personId = action({ action: 'member.save', name: `Person ${i}` }).id;
    app.session({ uid, name: uid, email: `${uid}@example.invalid`, email_verified: true });
    action({ action: 'account.approve', uid, personId, version: 1, role: 'member' });
    play(uid, 100 + i);
  }
  play('sam', 1);
  const board = app.runnerLeaderboard('sam');
  assert.equal(board.top.length, stageRunner.leaderboardSize);
  assert.equal(board.own.rank, stageRunner.leaderboardSize + 3);
});

test('scores above what the measured time allows and invalid runs are rejected', t => {
  const { app, store, sam, tick, play } = setup(t);
  play('sam', 10);
  for (const score of [-1, 1.5, '50', null, undefined, Number.NaN]) {
    const { roundId } = app.runnerStart('sam'); tick();
    assert.throws(() => app.runnerScore('sam', { roundId, score }), { status: 400, code: 'implausible' }, String(score));
  }
  // Short runs are fine as long as the score fits the time.
  let { roundId } = app.runnerStart('sam'); tick(3000);
  assert.throws(() => app.runnerScore('sam', { roundId, score: runnerMaxScore(3000) + 1 }), { status: 400, code: 'implausible' });
  assert.equal(app.runnerScore('sam', { roundId, score: runnerMaxScore(3000) }).improved, true);
  // A run counts only once and must be known.
  assert.throws(() => app.runnerScore('sam', { roundId, score: 30 }), { status: 409, code: 'round_unknown' });
  assert.throws(() => app.runnerScore('sam', { score: 20 }), { status: 409, code: 'round_unknown' });
  assert.throws(() => app.runnerScore('sam', { roundId: 'erfunden', score: 20 }), { status: 409, code: 'round_unknown' });
  // A new start replaces the open run; runs expire after a generous time.
  const old = app.runnerStart('sam').roundId; ({ roundId } = app.runnerStart('sam')); tick();
  assert.throws(() => app.runnerScore('sam', { roundId: old, score: 30 }), { status: 409, code: 'round_unknown' });
  tick(stageRunner.roundTtlMs);
  assert.throws(() => app.runnerScore('sam', { roundId, score: 30 }), { status: 409, code: 'round_expired' });
  assert.equal(store.get('runnerScores', sam).best, runnerMaxScore(3000));
});

test('runs are rate-limited per person and hour', t => {
  const { app, tick } = setup(t);
  for (let i = 0; i < stageRunner.roundsPerHour; i++) { app.runnerStart('sam'); tick(1000); }
  assert.throws(() => app.runnerStart('sam'), { status: 429, code: 'rate_limited' });
  assert.ok(app.runnerStart('kim').roundId);
  tick(3600000 - (stageRunner.roundsPerHour - 1) * 1000);
  assert.ok(app.runnerStart('sam').roundId);
});

test('only approved members play and see the list; inactive and deleted people leave it', async t => {
  const { app, action, store, sam, kim, play } = setup(t);
  for (const call of [() => app.runnerLeaderboard('pending'), () => app.runnerStart('pending'), () => app.runnerScore('unknown', { roundId: 'x', score: 1 })]) assert.throws(call, { status: 403 });
  play('sam', 12); play('kim', 15);
  action({ action: 'member.save', id: kim, name: 'Kim Muster', active: false, version: store.get('members', kim).version });
  assert.deepEqual(app.runnerLeaderboard('sam').top.map(x => x.personId), [sam]);
  await app.deleteAccount('admin', 'sam', store.account('sam').version);
  action({ action: 'member.delete', id: sam, version: store.get('members', sam).version });
  assert.equal(store.get('runnerScores', sam), null);
  assert.equal(store.get('runnerRounds', sam), null);
  assert.deepEqual(app.runnerLeaderboard('admin').top, []);
});

test('the HTTP API starts runs, takes scores and returns the leaderboard', async t => {
  const { app, tick } = setup(t);
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  const call = async (uid, method, path, body) => {
    const response = await fetch(`${base}${path}`, { method, headers: { Authorization: `Bearer ${uid}`, 'Content-Type': 'application/json' }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    return { status: response.status, body: await response.json() };
  };
  const start = await call('sam', 'POST', '/games/runner/rounds', {});
  assert.equal(start.status, 200);
  assert.equal((await call('sam', 'POST', '/games/runner/scores', { roundId: start.body.roundId, score: 100000 })).body.code, 'implausible');
  tick(20000);
  const done = await call('sam', 'POST', '/games/runner/scores', { roundId: start.body.roundId, score: 90 });
  assert.equal(done.status, 200);
  assert.equal(done.body.leaderboard.own.score, 90);
  const board = await call('kim', 'GET', '/games/runner/leaderboard');
  assert.deepEqual(board.body.top.map(x => x.name), ['Sam Beispiel']);
  assert.equal((await call('pending', 'GET', '/games/runner/leaderboard')).status, 403);
  assert.equal((await call('sam', 'GET', '/games/props/leaderboard')).status, 404);
});
