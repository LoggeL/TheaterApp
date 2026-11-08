import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { loadCatalog } from '../src/runner-wardrobe.mjs';
import { missionRules } from '../src/runner-missions.mjs';
import { missionDerivation, missionLog } from '../src/runner-mission-log.mjs';
import { purgeExpired, retention } from '../src/retention.mjs';
import { missionFlag, missionReport, missionStats } from '../scripts/mission-report.mjs';

// History of the Tagesmissionen for balancing: one row per mission, person and day.
const rarities = [{ id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 60, gage: 10 }];
const items = [
  { id: 'c0', kind: 'character', name: 'Engel Logge', rarity: 'hell', default: true },
  { id: 'b0', kind: 'backdrop', name: 'Wand', rarity: 'hell', default: true },
  { id: 'o0', kind: 'obstacles', name: 'Lager', rarity: 'hell', default: true },
  { id: 'f0', kind: 'fx', name: 'Ohne', rarity: 'hell', default: true },
];
const catalog = loadCatalog({ rarities, items, dupes: { shinyChance: { costume: 0.03, ensemble: 0.03, mission: 0.05 } }, ensemble: { every: 10, milestones: [{ km: 5 }] } });

// One type per slot (distance, points, runs), so the missions are known; [easy] adds types to the easy slot.
const rulesWith = (easy = []) => ({
  ...missionRules,
  types: {
    distance: { ...missionRules.types.distance, slots: ['easy'] },
    ...Object.fromEntries(easy.map(type => [type, { ...missionRules.types[type], slots: ['easy'] }])),
    points: { ...missionRules.types.points, slots: ['medium'] },
    runs: { ...missionRules.types.runs, slots: ['hard'], share: { hard: 0.33 }, start: [100, 150, 200] },
  },
});

function setup(t, { start = '2026-10-24T08:00:00Z', rules = rulesWith(), path = ':memory:' } = {}) {
  const store = new Store(path); t.after(() => store.close());
  const clock = { now: new Date(start) };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.now, runnerCatalog: catalog, random: () => 0.5, missionRules: rules });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let n = 0;
  const action = body => app.action('admin', body, `m-${++n}`);
  const member = (uid, name) => {
    const personId = action({ action: 'member.save', name }).id;
    app.session({ uid, name, email: `${uid}@example.invalid`, email_verified: true });
    action({ action: 'account.approve', uid, personId, version: 1, role: 'member' });
    return personId;
  };
  const sam = member('sam', 'Sam Beispiel'), kim = member('kim', 'Kim Beispiel');
  /** A run of 10 minutes ending 10 minutes from now (without statistics: an older app). */
  const play = (meters, { uid = 'sam' } = {}) => {
    const end = +clock.now + 600000;
    const { roundId } = app.runnerStart(uid);
    clock.now = new Date(end);
    return app.runnerScore(uid, { roundId, score: meters, meters });
  };
  const rows = personId => store.db.prepare('SELECT * FROM runner_mission_log WHERE person_id=? ORDER BY day, slot, rerolled').all(personId).map(r => ({ ...r, data: JSON.parse(r.data) }));
  const bySlot = (personId, day) => Object.fromEntries(rows(personId).filter(r => r.day === day && !r.rerolled_to).map(r => [r.slot, r]));
  return { store, app, clock, action, sam, kim, play, rows, bySlot };
}

test('the day\'s missions are logged when they are made, with how their targets came about', t => {
  const { app, sam, rows } = setup(t);
  app.runnerMissions('sam');
  const logged = rows(sam);
  assert.deepEqual(logged.map(r => [r.day, r.slot, r.type, r.target, r.reward, r.client_stats, r.rerolled, r.done, r.runs, r.crate]), [
    ['2026-10-24', 'easy', 'distance', 150, 450, 1, 0, 0, 0, 0],
    ['2026-10-24', 'hard', 'runs', 3, 1500, 1, 0, 0, 0, 0],
    ['2026-10-24', 'medium', 'points', 325, 900, 1, 0, 0, 0, 0],
  ]);
  // No runs yet: the start values decide, there is no best to compare with.
  assert.ok(logged.every(r => r.data.derivation.source === 'start' && r.data.derivation.ratio === null && r.best === null));
  assert.equal(logged.find(r => r.type === 'runs').data.min, 200);
  // Asking again the same day writes nothing new.
  app.runnerMissions('sam');
  assert.equal(rows(sam).length, 3);
});

test('runs are counted until a mission is done, with the minutes since the day\'s first run and the Missionskiste', t => {
  const { store, sam, play, bySlot } = setup(t);
  play(100); // made by the run (an older app without statistics), nothing done
  let day = bySlot(sam, '2026-10-24');
  assert.deepEqual(Object.values(day).map(r => [r.slot, r.runs, r.done, r.progress, r.client_stats]), [['easy', 1, 0, 100, 0], ['hard', 1, 0, 0, 0], ['medium', 1, 0, 100, 0]]);
  assert.equal(day.easy.data.firstRunAt, '2026-10-24T08:10:00.000Z');
  play(400); // distance 150 and points 330 done in the second run
  day = bySlot(sam, '2026-10-24');
  assert.deepEqual([day.easy.done, day.easy.runs_to_done, day.easy.minutes_to_done], [1, 2, 10]);
  assert.deepEqual([day.medium.done, day.medium.runs_to_done, day.medium.minutes_to_done], [1, 2, 10]);
  assert.deepEqual([day.hard.done, day.hard.runs, day.hard.progress], [0, 2, 1]);
  play(250); play(250); // the series of three runs of at least 200 m
  day = bySlot(sam, '2026-10-24');
  assert.deepEqual([day.hard.done, day.hard.runs_to_done, day.hard.minutes_to_done, day.hard.progress], [1, 4, 30, 3]);
  // Done missions keep their runs; the day's runs go on in the details.
  assert.deepEqual([day.easy.runs, day.easy.data.dayRuns, day.easy.data.doneAt], [2, 4, '2026-10-24T08:20:00.000Z']);
  assert.ok(Object.values(day).every(r => r.crate === 1));
  assert.equal(store.get('runnerMissions', sam).crate, true);
  play(300);
  assert.equal(bySlot(sam, '2026-10-24').hard.runs, 4, 'runs after done do not count for it');
});

test('a reroll marks the old mission and logs the new one, once per request', t => {
  const { app, sam, play, rows } = setup(t, { rules: rulesWith(['dailyDistance']) });
  const before = app.runnerMissions('sam').missions.find(m => m.slot === 'easy').type;
  const other = before === 'distance' ? 'dailyDistance' : 'distance';
  play(100);
  const view = app.runnerMissionReroll('sam', 'r-1', { slot: 'easy' });
  assert.equal(view.missions.find(m => m.slot === 'easy').type, other);
  app.runnerMissionReroll('sam', 'r-1', { slot: 'easy' });
  const easy = rows(sam).filter(r => r.slot === 'easy');
  assert.equal(easy.length, 2);
  const [old, fresh] = easy;
  assert.deepEqual([old.type, old.rerolled, old.rerolled_to, old.runs, old.progress, old.done], [before, 0, other, 1, 100, 0]);
  assert.ok(old.data.rerolledAt);
  assert.deepEqual([fresh.type, fresh.rerolled, fresh.rerolled_from, fresh.rerolled_to, fresh.runs], [other, 1, before, null, 0]);
  assert.equal(fresh.data.firstRunAt, '2026-10-24T08:10:00.000Z', 'the day\'s first run carries over');
  // The day's distance starts with today's metres.
  assert.equal(fresh.progress, other === 'dailyDistance' ? 100 : 0);
  play(700);
  const done = rows(sam).find(r => r.slot === 'easy' && r.rerolled);
  assert.deepEqual([done.done, done.runs_to_done, done.minutes_to_done], [1, 1, 10]);
  assert.equal(rows(sam).find(r => r.slot === 'easy' && !r.rerolled).runs, 1, 'the rerolled-away mission counts no more runs');
});

test('a new day keeps the old day\'s rows as they ended and logs targets against the bests', t => {
  const { app, clock, sam, play, bySlot, rows } = setup(t);
  for (let i = 0; i < 5; i++) play(1000);
  play(30);
  clock.now = new Date('2026-10-25T07:00:00Z');
  app.runnerMissions('sam');
  const old = bySlot(sam, '2026-10-24'), next = bySlot(sam, '2026-10-25');
  assert.deepEqual([old.hard.done, old.hard.runs_to_done, old.medium.done, old.medium.runs_to_done], [1, 3, 1, 1]);
  assert.equal(rows(sam).length, 6);
  // Six counted runs with a best of 1000 m and points: the targets are the shares of it (0.3, 0.33,
  // 0.44), rounded to even figures; the ratio is the one of the rounded target.
  assert.deepEqual(Object.values(next).map(r => [r.slot, r.target, r.best, r.data.derivation.share, r.data.derivation.source, r.data.derivation.ratio, r.runs]), [
    ['easy', 300, 1000, 0.3, 'share', 0.3, 0], ['hard', 3, 1000, 0.33, 'share', 0.325, 0], ['medium', 450, 1000, 0.44, 'share', 0.45, 0],
  ]);
  assert.equal(next.hard.data.min, 325);
  // A day nobody plays on stays complete: unfinished means not done.
  clock.now = new Date('2026-10-27T07:00:00Z');
  play(50);
  assert.ok(Object.values(bySlot(sam, '2026-10-25')).every(r => r.done === 0 && r.runs === 0));
});

test('the derivation names limits and the start value', () => {
  const ctx = (best, runs = 10) => ({ rules: missionRules, best, runs });
  assert.equal(missionDerivation({ slot: 'easy', type: 'distance', target: 100 }, ctx({ m: 200 })).source, 'min');
  assert.equal(missionDerivation({ slot: 'hard', type: 'distance', target: 6000 }, ctx({ m: 20000 })).source, 'max');
  assert.equal(missionDerivation({ slot: 'easy', type: 'distance', target: 150 }, ctx({ m: 300 }, 2)).source, 'start');
  assert.deepEqual(missionDerivation({ slot: 'medium', type: 'collect', kind: 'mask', target: 9 }, ctx({ mask: 20 })), { best: 20, share: 0.45, raw: 9, value: 9, ratio: 0.45, source: 'share', few: false, countedRuns: 10, start: 4, bests: { m: null, s: null } });
  assert.equal(missionDerivation({ slot: 'hard', type: 'debut', kind: 'drum', target: 250 }, ctx({ s: 400 })).source, 'band');
  assert.deepEqual(missionDerivation({ slot: 'easy', type: 'unknown', target: 1 }, ctx({})), {});
});

test('logging never breaks a run', t => {
  const { store, play } = setup(t);
  store.db.exec('DROP TABLE runner_mission_log');
  const error = console.error; console.error = () => {}; t.after(() => { console.error = error; });
  assert.ok(play(400).progress.missions.missions.some(m => m.done));
});

test('deleting a person deletes their rows, others stay', async t => {
  const { store, app, action, sam, kim, play, rows } = setup(t);
  play(100); play(100, { uid: 'kim' });
  assert.equal(rows(sam).length, 3);
  await app.deleteAccount('admin', 'sam', store.account('sam').version);
  action({ action: 'member.delete', id: sam, version: store.get('members', sam).version });
  assert.equal(rows(sam).length, 0);
  assert.equal(rows(kim).length, 3);
});

test('retention deletes rows older than 180 days', async t => {
  const { app, clock, sam, play, rows } = setup(t, { start: '2026-04-20T08:00:00Z' });
  assert.equal(retention.missionLogDays, 180);
  assert.equal(missionLog.retentionDays, 180);
  play(100);
  clock.now = new Date('2026-04-30T08:00:00Z');
  play(100);
  clock.now = new Date('2026-10-24T12:00:00Z');
  const counts = await purgeExpired(app, { now: clock.now });
  // 180 days before 24 October is 27 April: the 20 April rows go, the 30 April rows stay.
  assert.equal(counts.missionLog, 3);
  assert.deepEqual([...new Set(rows(sam).map(r => r.day))], ['2026-04-30']);
});

/** Rows of a fixture: [n] missions of [type] in [slot] by [players] people, [done] of them done in [runs] runs. */
let fixturePeople = 1000;
function fixture(store, { day = '2026-10-20', type, slot, n, players = n, done, runs = 1, played = n, rerolled = 0, crate = false, ratio = 0.3 }) {
  const insert = store.db.prepare(`INSERT INTO runner_mission_log(day, person_id, slot, type, kind, target, reward, best, client_stats, rerolled, rerolled_from, rerolled_to, done, runs, runs_to_done, progress, minutes_to_done, crate, created_at, updated_at, data)
    VALUES (?,?,?,?,NULL,100,450,?,1,0,NULL,?,?,?,?,?,?,?,?,?,?)`);
  const base = fixturePeople; fixturePeople += players;
  for (let i = 0; i < n; i++) {
    const isDone = i < done, ran = i < played;
    // A person plays a type and slot once a day: more missions than players spread over the next days.
    const at = new Date(Date.parse(`${day}T12:00:00Z`) + Math.floor(i / players) * 864e5).toISOString().slice(0, 10);
    insert.run(at, base + (i % players), slot, type, 100 / ratio, i >= n - rerolled ? 'points' : null, isDone ? 1 : 0, ran ? (isDone ? runs : 3) : 0, isDone ? runs : null, isDone ? 100 : ran ? 40 : 0, isDone ? 5 * (runs - 1) : null, crate ? 1 : 0,
      `${at}T08:00:00.000Z`, `${at}T09:00:00.000Z`, JSON.stringify({ derivation: { ratio, source: 'share' }, dayRuns: ran ? 3 : 0 }));
  }
}

test('the report aggregates by type and slot and flags missions that look too easy or too hard', t => {
  const store = new Store(); t.after(() => store.close());
  fixture(store, { type: 'distance', slot: 'easy', n: 20, done: 19, runs: 1 });
  fixture(store, { type: 'ceiling', slot: 'hard', n: 20, done: 3, runs: 4, rerolled: 5, ratio: 0.55 });
  fixture(store, { type: 'points', slot: 'medium', n: 4, players: 2, done: 4, runs: 1 });
  fixture(store, { type: 'distance', slot: 'medium', n: 10, done: 5, runs: 2, played: 8 });
  const report = missionReport(store.db, { days: 14, now: new Date('2026-10-24T10:00:00Z') });
  const line = start => report.split('\n').find(l => l.startsWith(start));
  assert.match(report, /^# Tagesmissionen: 2026-10-10 bis 2026-10-23 \(14 Tage, nur abgeschlossene Tage\)/);
  assert.match(line('| distance | leicht |'), /\| 20 \| 20 \| 20 \| 95 % \(19\) \| 0 % \| 1 \(1–1\) \| 0 \|.*\| zu leicht\? \|$/);
  assert.match(line('| ceiling | schwer |'), /\| 15 % \(3\) \| 25 % \|.*\| 0.55 \|.*\| zu schwer\? \|$/);
  assert.match(line('| points | mittel |'), /zu leicht\? \(kleine Stichprobe\) \|$/);
  // 8 of 10 played: completion counts only those.
  assert.match(line('| distance | mittel |'), /\| 10 \| 10 \| 8 \| 63 % \(5\) \|.*\| 40 % \|.*\|  \|$/);
  assert.match(report, /## Nach Stufe/);
  assert.match(report, /\| ceiling → points \| 5 \|/);
  assert.match(report, /\| 2026-10-20 \| \d+ \| \d+ \| 0 \| 0 % \| 3 \|/);
  // Aggregates only: no person ids.
  assert.doesNotMatch(report, /100[0-9]/);
  // Today is left out unless asked for.
  fixture(store, { day: '2026-10-24', type: 'runs', slot: 'hard', n: 1, done: 0 });
  assert.doesNotMatch(missionReport(store.db, { now: new Date('2026-10-24T10:00:00Z') }), /\| runs \|/);
  assert.match(missionReport(store.db, { now: new Date('2026-10-24T10:00:00Z'), today: true }), /\| runs \| schwer \|/);
  assert.equal(missionFlag(missionStats([])), '');
});

test('the report script runs read-only on a database file', t => {
  const dir = mkdtempSync(join(tmpdir(), 'mission-report-')); t.after(() => rmSync(dir, { recursive: true, force: true }));
  const path = join(dir, 'theater.sqlite');
  const { store, clock, play } = setup(t, { path, start: new Date(Date.now() - 2 * 864e5).toISOString() });
  play(100); play(400); play(100, { uid: 'kim' });
  clock.now = new Date(Date.now() - 864e5);
  play(300);
  store.db.exec('PRAGMA wal_checkpoint(FULL)');
  const script = fileURLToPath(new URL('../scripts/mission-report.mjs', import.meta.url));
  const run = spawnSync(process.execPath, [script, path, '--days', '7'], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  assert.match(run.stdout, /# Tagesmissionen: .* \(7 Tage, nur abgeschlossene Tage\)/);
  assert.match(run.stdout, /\| distance \| leicht \|/);
  assert.match(run.stdout, /## Missionskiste je Tag/);
  assert.equal(spawnSync(process.execPath, [script], { encoding: 'utf8' }).status, 2);
});
