import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures, runnerMaxMeters } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { bundledCatalog, loadCatalog, shinyChanceOf } from '../src/runner-wardrobe.mjs';
import { settleWeeks, weekAwardsKind, weekPrizesKind, weekRunsKind, weeklyRules } from '../src/runner-weekly.mjs';

// Rewards of the Wochenprobe: a Wochenkiste for every ranked player, gage and a trophy for the
// places, the top-up of weeks closed by the rules before, the crate and the trophy counts.
const rarities = [{ id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 60, gage: 10 }];
const items = [
  ...['character', 'backdrop', 'obstacles', 'fx'].map(kind => ({ id: `${kind}.default`, kind, name: 'Default', rarity: 'hell', default: true })),
  { id: 'h1', kind: 'character', name: 'Hell 1', rarity: 'hell' },
  { id: 'h2', kind: 'character', name: 'Hell 2', rarity: 'hell' },
  { id: 'h3', kind: 'character', name: 'Hell 3', rarity: 'hell' },
];
const names = { sam: 'Sam Beispiel', kim: 'Kim Muster', lou: 'Lou Probe', ria: 'Ria Rang', ole: 'Ole Ohne' };
// Week 45 of 2026 closes half an hour after Sunday midnight in Berlin (23:00 UTC).
const afterW45 = '2026-11-09T08:00:00Z', afterW46 = '2026-11-16T08:00:00Z';

function setup(t, { store = new Store(), begin = '2026-11-04T10:00:00Z', random = () => 0.5, shinyChance = { costume: 0.03, weekly: 0.15 } } = {}) {
  t.after(() => { try { store.close(); } catch { /* closed by an earlier setup on the same store */ } });
  const clock = { now: new Date(begin) };
  const make = () => new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.now, random, runnerCatalog: loadCatalog({ rarities, items, dupes: { shinyChance } }), missionRules: null });
  const app = make();
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let sequence = 0;
  const action = body => app.action('admin', body, `rewards-${++sequence}`);
  const ids = {};
  for (const [uid, name] of Object.entries(names)) {
    const personId = action({ action: 'member.save', name }).id;
    app.session({ uid, name, email: `${uid}@example.invalid`, email_verified: true });
    action({ action: 'account.approve', uid, personId, version: 1, role: 'member' });
    ids[uid] = personId;
  }
  const at = iso => { clock.now = new Date(iso); };
  /** A ranked run (or training) of [seconds] that ends now, with a fitting ghost. */
  const play = (uid, seconds, ranked = true) => {
    const end = clock.now;
    clock.now = new Date(+end - seconds * 1000);
    const { roundId } = app.runnerStart(uid, { weekly: { week: app.runnerWeekly(uid).week, ranked } });
    clock.now = end;
    const meters = Math.floor(runnerMaxMeters(seconds)), n = Math.floor(seconds * weeklyRules.hz) + 1;
    const result = app.runnerScore(uid, { roundId, score: meters, meters, ghost: Buffer.from([...Array(n).fill(128), 1]).toString('base64') });
    clock.now = new Date(+clock.now + 60000);
    return result;
  };
  /** Ranked runs in this order, the longer the better (`{ uid: seconds }`). */
  const runs = list => { for (const [uid, seconds] of Object.entries(list)) play(uid, seconds); };
  const gage = uid => store.get('runnerProgress', ids[uid])?.gage ?? 0;
  const gages = uids => uids.map(gage);
  const crates = uid => app.runnerWardrobe(uid, { roles: true }).progress.weeklyCrates;
  let opening = 0;
  const open = (uid, body = {}, id = `open-${++opening}`) => app.runnerOpenCrate(uid, id, { dupes: true, roles: true, crate: 'weekly', ...body });
  return { store, app, make, clock, at, action, ids, play, runs, gage, gages, crates, open };
}

const none = { gold: 0, silver: 0, bronze: 0 };

/** Closes a week the way 0.15.0 did: 30/20/10 for the places, 5 for the others, no `rules`. */
function closeTheOldWay(s, week) {
  const ranked = s.app.runnerWeekly('admin').leaderboard;
  const placements = ranked.map(x => ({ rank: x.rank, personId: x.personId, name: x.name, score: x.score, meters: x.meters, gage: { 1: 30, 2: 20, 3: 10 }[x.rank] ?? 5 }));
  for (const x of placements) {
    const p = s.store.get('runnerProgress', x.personId);
    s.store.put('runnerProgress', x.personId, { ...p, gage: (p.gage ?? 0) + x.gage, gageEarned: (p.gageEarned ?? 0) + x.gage });
  }
  s.store.put(weekAwardsKind, week, { week, closedAt: '2026-11-08T23:30:00.000Z', players: placements.length, placements });
}

test('servers announce the weekly rewards', t => {
  const { app } = setup(t);
  assert.ok(apiFeatures.includes('runnerWeeklyRewards'));
  assert.ok(app.snapshot('sam').capabilities.features.includes('runnerWeeklyRewards'));
});

test('every ranked player gets a Wochenkiste, the places gage and a trophy on top', t => {
  const s = setup(t);
  s.runs({ kim: 90, sam: 80, lou: 70, ria: 60 });
  // Training alone is no participation.
  s.play('ole', 120, false);
  const before = s.gages(['kim', 'sam', 'lou', 'ria', 'ole']);
  s.at(afterW45);
  const view = s.app.runnerWeekly('lou');
  const gains = s.gages(['kim', 'sam', 'lou', 'ria', 'ole']).map((g, i) => g - before[i]);
  assert.deepEqual(gains, [100, 50, 25, 0, 0]);
  assert.deepEqual(['kim', 'sam', 'lou', 'ria', 'ole'].map(s.crates), [1, 1, 1, 1, 0]);
  const awards = s.store.get(weekAwardsKind, '2026-W45');
  assert.deepEqual(awards.placements.map(x => [x.rank, x.personId, x.gage, x.crates, x.trophy ?? null]), [
    [1, s.ids.kim, 100, 1, 'gold'], [2, s.ids.sam, 50, 1, 'silver'], [3, s.ids.lou, 25, 1, 'bronze'], [4, s.ids.ria, 0, 1, null],
  ]);
  assert.equal(awards.rules, 2);
  assert.equal(awards.toppedUpAt, undefined);
  assert.deepEqual(s.store.all(weekPrizesKind).map(x => [x.week, x.personId, x.rank, x.crates, x.opened, x.trophy ?? null]), [
    ['2026-W45', s.ids.kim, 1, 1, 0, 'gold'], ['2026-W45', s.ids.sam, 2, 1, 0, 'silver'], ['2026-W45', s.ids.lou, 3, 1, 0, 'bronze'], ['2026-W45', s.ids.ria, 4, 1, 0, null],
  ].sort((x, y) => `${x[0]}:${x[1]}`.localeCompare(`${y[0]}:${y[1]}`)));
  // The banner of the week with what it brought.
  assert.deepEqual(view.lastWeek, { week: '2026-W45', rank: 3, score: Math.floor(runnerMaxMeters(70)), gage: 25, trophy: 'bronze', crates: 1 });
  assert.deepEqual(s.app.runnerWeekly('ria').lastWeek, { week: '2026-W45', rank: 4, score: Math.floor(runnerMaxMeters(60)), gage: 0, trophy: null, crates: 1 });
  assert.equal(s.app.runnerWeekly('ole').lastWeek, null);
  assert.deepEqual(view.trophies, { gold: 0, silver: 0, bronze: 1 });
  assert.deepEqual(s.app.runnerWeekly('ole').trophies, none);
  // Nothing of it is ever pushed.
  assert.deepEqual(s.store.all('pushJobs'), []);
});

test('rewards come exactly once: repeated settles, views and a fresh server on the same store', t => {
  const store = new Store(), s = setup(t, { store });
  s.runs({ kim: 90, sam: 80, lou: 70, ria: 60 });
  s.at(afterW45);
  settleWeeks(s.app);
  const after = () => [s.gages(['kim', 'sam', 'lou', 'ria']), store.all(weekPrizesKind).length, s.app.runnerWeekly('kim').trophies, ['kim', 'sam', 'lou', 'ria'].map(s.crates)];
  const once = after();
  assert.deepEqual(once[1], 4);
  for (let i = 0; i < 3; i++) { settleWeeks(s.app); s.app.runnerWeekly('sam'); s.app.runnerWeeklySeen('lou', { week: '2026-W45' }); }
  const restarted = new Theater(store, { clock: () => new Date(afterW46), runnerCatalog: loadCatalog({ rarities, items }), missionRules: null });
  settleWeeks(restarted); restarted.runnerWeekly('kim'); settleWeeks(restarted);
  assert.deepEqual(after(), once);
  assert.deepEqual(store.get(weekAwardsKind, '2026-W45').placements.map(x => x.gage), [100, 50, 25, 0]);
  // The empty next week closes with nothing to give.
  assert.deepEqual(store.get(weekAwardsKind, '2026-W46').placements, []);
  assert.equal(store.get(weekAwardsKind, '2026-W46').rules, 2);
});

test('inactive people get nothing at the close; a top-up keeps to who the frozen record names', t => {
  const s = setup(t);
  s.runs({ kim: 90, sam: 80, lou: 70 });
  s.action({ action: 'member.save', id: s.ids.kim, name: names.kim, active: false, version: s.store.get('members', s.ids.kim).version });
  const before = s.gage('kim');
  s.at(afterW45);
  s.app.runnerWeekly('sam');
  assert.deepEqual(s.store.get(weekAwardsKind, '2026-W45').placements.map(x => [x.rank, x.personId, x.trophy]), [[1, s.ids.sam, 'gold'], [2, s.ids.lou, 'silver']]);
  assert.equal(s.gage('kim'), before);
  assert.equal(s.store.all(weekPrizesKind).some(x => x.personId === s.ids.kim), false);
  // A week closed the old way is topped up for who its record names, also after leaving since.
  s.at('2026-11-12T12:00:00Z');
  s.runs({ lou: 90, sam: 80 });
  closeTheOldWay(s, '2026-W46');
  s.action({ action: 'member.save', id: s.ids.lou, name: names.lou, active: false, version: s.store.get('members', s.ids.lou).version });
  s.at(afterW46);
  settleWeeks(s.app);
  assert.deepEqual(s.store.get(weekAwardsKind, '2026-W46').placements.map(x => [x.personId, x.trophy]), [[s.ids.lou, 'gold'], [s.ids.sam, 'silver']]);
  assert.equal(s.gage('kim'), before);
});

test('a week closed by the old rules is topped up once: crate, trophy and the gage missing', t => {
  const store = new Store(), s = setup(t, { store });
  s.runs({ kim: 90, sam: 80, lou: 70, ria: 60 });
  closeTheOldWay(s, '2026-W45');
  s.at('2026-11-08T23:40:00Z');
  // 0.15.0 showed Sam the banner already.
  const samRun = store.get(weekRunsKind, `2026-W45:${s.ids.sam}`);
  store.put(weekRunsKind, `2026-W45:${s.ids.sam}`, { ...samRun, rewardSeen: true });
  const old = s.gages(['kim', 'sam', 'lou', 'ria']);
  assert.deepEqual(old, [30, 20, 10, 5]);
  settleWeeks(s.app);
  // The difference to 100/50/25; nobody gives back the 5 of taking part.
  assert.deepEqual(s.gages(['kim', 'sam', 'lou', 'ria']), [100, 50, 25, 5]);
  assert.deepEqual(['kim', 'sam', 'lou', 'ria'].map(s.crates), [1, 1, 1, 1]);
  const awards = store.get(weekAwardsKind, '2026-W45');
  assert.equal(awards.rules, 2);
  assert.equal(awards.toppedUpAt, '2026-11-08T23:40:00.000Z');
  assert.equal(awards.closedAt, '2026-11-08T23:30:00.000Z');
  assert.deepEqual(awards.placements.map(x => [x.rank, x.gage, x.crates, x.trophy ?? null, x.topUp]), [
    [1, 100, 1, 'gold', { gage: 70, crates: 1, trophy: 'gold' }],
    [2, 50, 1, 'silver', { gage: 30, crates: 1, trophy: 'silver' }],
    [3, 25, 1, 'bronze', { gage: 15, crates: 1, trophy: 'bronze' }],
    [4, 5, 1, null, { gage: 0, crates: 1 }],
  ]);
  // The banner shows again with what the week brings now.
  assert.deepEqual(s.app.runnerWeekly('sam').lastWeek, { week: '2026-W45', rank: 2, score: Math.floor(runnerMaxMeters(80)), gage: 50, trophy: 'silver', crates: 1 });
  assert.deepEqual(s.app.runnerWeekly('ria').lastWeek, { week: '2026-W45', rank: 4, score: Math.floor(runnerMaxMeters(60)), gage: 5, trophy: null, crates: 1 });
  assert.deepEqual(s.app.runnerWeekly('kim').trophies, { gold: 1, silver: 0, bronze: 0 });
  // Once: again, lazily, after a crate was opened and on a fresh server.
  s.open('kim');
  s.app.runnerWeeklySeen('sam', { week: '2026-W45' });
  settleWeeks(s.app); s.app.runnerWeekly('lou');
  const restarted = new Theater(store, { clock: () => new Date(afterW46), runnerCatalog: loadCatalog({ rarities, items }), missionRules: null });
  settleWeeks(restarted); restarted.runnerWeekly('ria');
  assert.equal(s.gages(['sam', 'lou', 'ria']).join(), '50,25,5');
  assert.deepEqual(['kim', 'sam', 'lou', 'ria'].map(s.crates), [0, 1, 1, 1]);
  assert.equal(store.all(weekPrizesKind).length, 4);
  assert.equal(store.get(weekAwardsKind, '2026-W45').toppedUpAt, '2026-11-08T23:40:00.000Z');
  assert.equal(s.app.runnerWeekly('sam').lastWeek, null);
  assert.deepEqual(s.app.runnerWeekly('kim').trophies, { gold: 1, silver: 0, bronze: 0 });
});

test('the top-up happens lazily on the next view as well', t => {
  const s = setup(t);
  s.runs({ kim: 90, sam: 80 });
  closeTheOldWay(s, '2026-W45');
  s.at(afterW45);
  const view = s.app.runnerWeekly('kim');
  assert.deepEqual(view.lastWeek, { week: '2026-W45', rank: 1, score: Math.floor(runnerMaxMeters(90)), gage: 100, trophy: 'gold', crates: 1 });
  assert.deepEqual(s.gages(['kim', 'sam']), [100, 50]);
});

test('a Wochenkiste draws from everything with its own shine chance, once per request id', t => {
  const s = setup(t, { random: () => 0.1 });
  s.runs({ kim: 90, sam: 80 });
  s.at(afterW45);
  settleWeeks(s.app);
  const first = s.open('sam', {}, 'same');
  assert.equal(first.outcome.crate, 'weekly');
  assert.equal(first.outcome.week, '2026-W45');
  assert.equal(first.outcome.shiny, true); // 0.1 < 0.15, but not below the 0.03 of a costume crate.
  assert.ok(['h1', 'h2', 'h3'].includes(first.item.id));
  assert.equal(first.wardrobe.progress.weeklyCrates, 0);
  assert.equal(first.wardrobe.weekly.crates, 0);
  assert.equal(first.wardrobe.progress.opened, 0);
  assert.equal(first.wardrobe.progress.crates, 0);
  const again = s.open('sam', {}, 'same');
  assert.equal(again.item.id, first.item.id);
  assert.equal(s.store.get(weekPrizesKind, `2026-W45:${s.ids.sam}`).opened, 1);
  assert.throws(() => s.open('sam'), e => e.status === 409 && e.code === 'no_crate' && /Wochenkiste/.test(e.message));
  // Only apps with duplicates; never aimed.
  assert.throws(() => s.app.runnerOpenCrate('kim', 'old', { crate: 'weekly' }), e => e.status === 400);
  assert.throws(() => s.open('kim', { target: 'random' }), e => e.code === 'unknown_target');
  assert.equal(s.crates('kim'), 1);
  // The bundled catalog: the chance of the Ensemble-Kiste, another crate for everybody.
  assert.equal(shinyChanceOf(bundledCatalog(), 'weekly'), shinyChanceOf(bundledCatalog(), 'ensemble'));
  assert.equal(bundledCatalog().weeklyCrate.name, 'Wochenkiste');
});

test('Wochenkisten of several weeks never lapse and open the earliest first', t => {
  const s = setup(t);
  s.runs({ kim: 90 });
  s.at('2026-11-12T12:00:00Z');
  s.runs({ kim: 60 });
  s.at('2027-02-01T12:00:00Z');
  settleWeeks(s.app);
  assert.equal(s.crates('kim'), 2);
  assert.deepEqual([s.open('kim'), s.open('kim')].map(x => x.outcome.week), ['2026-W45', '2026-W46']);
});

test('apps from before see the gage, never the Wochenkiste among their crates', t => {
  const s = setup(t);
  s.runs({ kim: 90, sam: 80 });
  s.at(afterW45);
  settleWeeks(s.app);
  const older = s.app.runnerWardrobe('sam');
  assert.equal(older.progress.crates, 0);
  assert.equal(older.progress.galaCrates, 0);
  assert.equal(older.progress.weeklyCrates, 1);
  assert.equal(older.gage.balance, 50);
  // What 0.15.0 reads of the weekly view stays as it was, only with fields added.
  const view = s.app.runnerWeekly('sam');
  for (const field of ['week', 'rank', 'score', 'gage']) assert.ok(field in view.lastWeek, field);
  assert.equal(view.lastWeek.gage, 50);
});

test('trophies are counted per person from the frozen weeks and shown beside the names', t => {
  const s = setup(t);
  s.runs({ kim: 90, sam: 80, lou: 70 });
  s.at('2026-11-12T12:00:00Z');
  s.runs({ kim: 90, lou: 80, sam: 70, ria: 60 });
  s.at('2026-11-18T12:00:00Z');
  s.runs({ lou: 90, kim: 80 });
  const view = s.app.runnerWeekly('kim');
  assert.deepEqual(view.trophies, { gold: 2, silver: 0, bronze: 0 });
  assert.deepEqual(view.leaderboard.map(x => [x.name, x.trophies]), [
    [names.lou, { gold: 0, silver: 1, bronze: 1 }], [names.kim, { gold: 2, silver: 0, bronze: 0 }],
  ]);
  assert.deepEqual(s.app.runnerWeekly('sam').trophies, { gold: 0, silver: 1, bronze: 1 });
  assert.deepEqual(s.app.runnerWeekly('ria').trophies, none);
  const wardrobe = s.app.runnerWardrobe('kim', { roles: true }).weekly;
  assert.deepEqual(wardrobe.trophies, { gold: 2, silver: 0, bronze: 0 });
  assert.equal(wardrobe.crates, 2);
  assert.deepEqual(wardrobe.crate, { id: 'weekly', kind: 'weekly', name: 'Wochenkiste', animation: 'generic', shinyChance: 0.15 });
});

test('deleting a person removes their Wochenkisten and trophies; the others keep theirs', async t => {
  const s = setup(t);
  s.runs({ sam: 90, kim: 80, lou: 70 });
  s.at(afterW45);
  s.app.runnerWeekly('kim');
  s.runs({ lou: 90, sam: 80 });
  await s.app.deleteAccount('admin', 'sam', s.store.account('sam').version);
  s.action({ action: 'member.delete', id: s.ids.sam, version: s.store.get('members', s.ids.sam).version });
  assert.equal(s.store.all(weekPrizesKind).some(x => x.personId === s.ids.sam), false);
  assert.equal(s.store.all(weekRunsKind).some(x => x.personId === s.ids.sam), false);
  assert.equal(JSON.stringify(s.store.get(weekAwardsKind, '2026-W45')).includes(names.sam), false);
  assert.deepEqual(s.store.get(weekAwardsKind, '2026-W45').placements.map(x => [x.rank, x.personId, x.trophy]), [[2, s.ids.kim, 'silver'], [3, s.ids.lou, 'bronze']]);
  assert.deepEqual(s.app.runnerWeekly('kim').trophies, { gold: 0, silver: 1, bronze: 0 });
  assert.deepEqual(s.app.runnerWeekly('kim').leaderboard.map(x => [x.personId, x.trophies]), [[s.ids.lou, { gold: 0, silver: 0, bronze: 1 }]]);
  assert.equal(s.crates('lou'), 1);
});

test('the routes give the weekly fields and open a Wochenkiste once per key', async t => {
  const s = setup(t);
  s.runs({ kim: 90, sam: 80 });
  s.at(afterW45);
  s.runs({ kim: 60 });
  const server = createHttpServer({ theater: s.app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`, headers = { authorization: 'Bearer kim', 'content-type': 'application/json' };
  const weekly = await (await fetch(`${base}/games/runner/weekly`, { headers })).json();
  assert.deepEqual(weekly.trophies, { gold: 1, silver: 0, bronze: 0 });
  assert.deepEqual(weekly.leaderboard[0].trophies, { gold: 1, silver: 0, bronze: 0 });
  assert.deepEqual(weekly.lastWeek, { week: '2026-W45', rank: 1, score: Math.floor(runnerMaxMeters(90)), gage: 100, trophy: 'gold', crates: 1 });
  const post = () => fetch(`${base}/games/runner/crates`, { method: 'POST', headers: { ...headers, 'idempotency-key': 'weekly-key' }, body: JSON.stringify({ crate: 'weekly', dupes: true, roles: true }) }).then(async r => ({ status: r.status, body: await r.json() }));
  const [one, two] = [await post(), await post()];
  assert.equal(one.status, 200);
  assert.equal(one.body.outcome.crate, 'weekly');
  assert.equal(two.body.item.id, one.body.item.id);
  assert.equal(s.crates('kim'), 0);
  const wardrobe = await (await fetch(`${base}/games/runner/wardrobe?roles=1`, { headers })).json();
  assert.equal(wardrobe.weekly.crates, 0);
  assert.equal(wardrobe.progress.weeklyCrates, 0);
});
