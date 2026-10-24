import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { loadCatalog } from '../src/runner-wardrobe.mjs';
import { bestsOf, checkRunStats, chooseMission, dayMissions, missionOptions, missionRules, missionSlots, missionText, nice, raiseBest, seeded } from '../src/runner-missions.mjs';

// Tagesmissionen: three a day per person, measured on the own best runs.
const rarities = [{ id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 60, gage: 10 }];
const items = [
  { id: 'c0', kind: 'character', name: 'Engel Logge', rarity: 'hell', default: true },
  { id: 'b0', kind: 'backdrop', name: 'Wand', rarity: 'hell', default: true },
  { id: 'o0', kind: 'obstacles', name: 'Lager', rarity: 'hell', default: true },
  { id: 'f0', kind: 'fx', name: 'Ohne', rarity: 'hell', default: true },
  { id: 'h1', kind: 'character', name: 'Hell 1', rarity: 'hell' },
  { id: 'h2', kind: 'character', name: 'Hell 2', rarity: 'hell' },
];
const catalog = loadCatalog({ rarities, items, dupes: { shinyChance: { costume: 0.03, ensemble: 0.03, mission: 0.05 } }, ensemble: { every: 10, milestones: [{ km: 5 }] } });

function setup(t, { start = '2026-10-24T08:00:00Z', random = 0.5 } = {}) {
  const store = new Store(); t.after(() => store.close());
  const clock = { now: new Date(start) };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.now, runnerCatalog: catalog, random: () => random });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let n = 0;
  const action = body => app.action('admin', body, `m-${++n}`);
  const member = (uid, name) => {
    const personId = action({ action: 'member.save', name }).id;
    app.session({ uid, name, email: `${uid}@example.invalid`, email_verified: true });
    action({ action: 'account.approve', uid, personId, version: 1, role: 'member' });
    return personId;
  };
  const sam = member('sam', 'Sam Beispiel');
  /** A run of 10 minutes ending at [at] (or 10 minutes from now); `stats` as the app sends them. */
  const play = (meters, { stats, score, at, uid = 'sam' } = {}) => {
    const pickupPoints = stats ? (stats.rose ?? 0) * 5 + (stats.mask ?? 0) * 10 + (stats.star ?? 0) * 25 : 0;
    const end = at ? Date.parse(at) : +clock.now + 600000;
    clock.now = new Date(end - 600000);
    const { roundId } = app.runnerStart(uid);
    clock.now = new Date(end);
    return app.runnerScore(uid, { roundId, score: score ?? meters + pickupPoints, meters, ...(stats ? { missionStats: stats } : {}) }).progress;
  };
  /** Sets today's missions of [personId] by hand. */
  const give = (personId, missions, extra = {}) => {
    app.runnerMissions('sam');
    const rec = store.get('runnerMissions', personId);
    store.put('runnerMissions', personId, { ...rec, missions: missions.map((m, i) => ({ slot: missionSlots[i], reward: missionRules.slots[missionSlots[i]].reward, progress: 0, done: false, ...m })), ...extra });
  };
  return { store, app, clock, sam, play, give };
}

/** A window of runs around a typical [median] metres, with statistics. */
const windowOf = (median, n = 30) => Array.from({ length: n }, (_, i) => {
  const m = Math.round(median * (0.4 + 1.2 * i / (n - 1)));
  return { m, s: Math.round(m * 1.4), st: { rose: Math.round(m / 20), mask: Math.round(m / 60), star: Math.round(m / 300), ground: Math.round(m / 4), ceiling: Math.round(m / 14), passed: { crate: Math.round(m / 40), lamp: Math.round(m / 45), border: Math.round(m / 30), drum: m * 1.4 >= 250 ? Math.round(m / 80) : 0 } } };
});
/** The context of a person whose bests come from [window] (and the high score [best]). */
const ctxOf = (window, best = 0, stats = true) => ({ stats, ...bestsOf({ window }, best) });

test('servers announce the Tagesmissionen', t => {
  const { app } = setup(t);
  assert.ok(apiFeatures.includes('runnerMissions'));
  assert.ok(app.snapshot('sam').capabilities.features.includes('runnerMissions'));
});

test('three missions a day, easy to hard, never two of a type, the same for the same person and day', t => {
  const { app } = setup(t);
  const view = app.runnerMissions('sam');
  assert.equal(view.day, '2026-10-24');
  assert.deepEqual(view.missions.map(m => m.slot), ['easy', 'medium', 'hard']);
  assert.equal(new Set(view.missions.map(m => m.type)).size, 3);
  assert.deepEqual(view.missions.map(m => m.reward), [300, 600, 1000]);
  assert.ok(view.missions.every(m => m.text && m.unit && m.progress === 0 && !m.done));
  assert.equal(view.rerollAvailable, true);
  assert.deepEqual(app.runnerMissions('sam'), view);
  // Deterministic: the same person, day and runs give the same missions, another day others.
  const ctx = ctxOf(windowOf(300), 900);
  assert.deepEqual(dayMissions(7, '2026-10-24', ctx), dayMissions(7, '2026-10-24', ctx));
  const days = Array.from({ length: 20 }, (_, i) => JSON.stringify(dayMissions(7, `2026-11-${String(i + 1).padStart(2, '0')}`, ctx).map(m => [m.type, m.kind])));
  assert.ok(new Set(days).size >= 10, 'days vary');
  for (let d = 1; d <= 28; d++) {
    const types = dayMissions(d, '2026-12-01', ctx).map(m => m.type);
    assert.equal(new Set(types).size, 3);
    assert.ok(!types.slice(1).includes('dailyDistance'), 'the day distance is only an easy one');
  }
});

test('yesterday’s types are avoided where possible', () => {
  const ctx = ctxOf(windowOf(300), 900);
  let repeats = 0, fresh = 0;
  for (let i = 0; i < 300; i++) {
    const random = seeded('x', i), previous = new Set(['distance', 'points', 'collect']);
    if (previous.has(chooseMission('hard', ctx, new Set(), previous, random).type)) repeats++;
    if (previous.has(chooseMission('hard', ctx, new Set(), new Set(), seeded('x', i)).type)) fresh++;
  }
  assert.ok(repeats < fresh / 2, `${repeats} repeats against ${fresh}`);
});

test('targets: start values for new players, shares of the own bests for experienced ones', () => {
  const none = ctxOf([]);
  assert.deepEqual(missionSlots.map(s => missionOptions('distance', s, none)[0].target), missionRules.types.distance.start);
  assert.deepEqual(missionOptions('collect', 'easy', none).map(o => [o.kind, o.target]), [['rose', 5], ['mask', 2], ['star', 1]]);
  // Without enough runs no obstacle of a debut and no debut mission.
  assert.ok(missionOptions('pass', 'hard', none).every(o => ['crate', 'flat', 'lamp', 'border', 'sandbag'].includes(o.kind)));
  assert.deepEqual(missionOptions('debut', 'medium', none), []);

  // Runs of 80 … 320 m, best 320 m and 448 points: 30 %, 42 % and 57 % of the best distance.
  const window = windowOf(200), ctx = ctxOf(window);
  assert.deepEqual([ctx.best.m, ctx.best.s, ctx.runs], [320, 448, 30]);
  assert.deepEqual(missionSlots.map(s => missionOptions('distance', s, ctx)[0].target), [100, 130, 180]);
  assert.deepEqual(missionSlots.map(s => missionOptions('points', s, ctx)[0].target), [130, 200, 260]);
  assert.deepEqual(missionOptions('runs', 'medium', ctx), [{ target: 3, min: 110 }]);
  // Even figures: 1 below 30, then 5, 10, 25, 50, 100.
  assert.deepEqual([7.4, 47, 183, 812, 1424, 4321].map(nice), [7, 45, 180, 800, 1400, 4300]);
  // Obstacles of a debut only where a run at the slot reaches them: the Kabeltrommel (250) at
  // 58 % of 448 points, not at 30 %; the Kistenstapel (500) never.
  assert.ok(!missionOptions('pass', 'easy', ctx).some(o => o.kind === 'drum'));
  const passKinds = missionOptions('pass', 'hard', ctx).map(o => o.kind);
  assert.ok(passKinds.includes('drum'));
  assert.ok(!passKinds.includes('pile') && !passKinds.includes('truss'));
  // The debut near the slot's points target (0.95 to 1.25 times it).
  assert.deepEqual(missionOptions('debut', 'medium', ctxOf(window, 1000)), [{ kind: 'pile', target: 500 }]);
  assert.deepEqual(missionOptions('debut', 'hard', ctx), [{ kind: 'drum', target: 250 }]);
  // A kind of play the player hardly does is not offered rather than made too hard: one star at
  // best, a little ceiling.
  assert.ok(!missionOptions('collect', 'hard', ctx).some(o => o.kind === 'star'));
  assert.deepEqual(missionOptions('ceiling', 'easy', ctx), []);
  assert.deepEqual(missionOptions('ceiling', 'hard', ctx), [{ target: 13 }]);
  // Limits: nothing below the minimum, nothing above the maximum.
  const tiny = ctxOf(Array.from({ length: 10 }, () => ({ m: 25, s: 30 })), 30, false);
  assert.equal(missionOptions('distance', 'easy', tiny)[0].target, missionRules.types.distance.min);
  const huge = ctxOf(Array.from({ length: 10 }, () => ({ m: 90000, s: 99000 })), 99000, false);
  assert.equal(missionOptions('distance', 'hard', huge)[0].target, missionRules.types.distance.max);
});

test('the bests only rise, statistics only from plausible runs, without a pickup only exact runs', () => {
  const best = { m: 300, s: 400, rose: 10, ground: 50, passed: { crate: 5 } };
  const worse = raiseBest(best, { meters: 100, score: 120, stats: { rose: 4, mask: 0, star: 0, ground: 20, ceiling: 3, passed: { crate: 1 } } });
  assert.deepEqual([worse.m, worse.s, worse.rose, worse.ground, worse.ceiling, worse.passed.crate, worse.noPickup], [300, 400, 10, 50, 3, 5, undefined]);
  const better = raiseBest(best, { meters: 500, score: 500, stats: { rose: 0, mask: 0, star: 0, ground: 90, ceiling: 0, passed: { crate: 9, lamp: 2 } } });
  assert.deepEqual([better.m, better.s, better.ground, better.passed.crate, better.passed.lamp, better.noPickup], [500, 500, 90, 9, 2, 500]);
  // Without (plausible) statistics only metres and points.
  assert.deepEqual(raiseBest(best, { meters: 600, score: 700, stats: null }), { ...best, m: 600, s: 700 });
  // From the earlier window once: its maxima and the high score.
  const { best: started, runs } = bestsOf({ window: windowOf(200) }, 999);
  assert.deepEqual([started.m, started.s, started.rose, started.passed.drum, runs], [320, 999, 16, 4, 30]);
  assert.equal(bestsOf({ best: { m: 50, s: 60 }, runs: 7 }, 80).best.s, 80);
});

test('bad runs on purpose lower no target; a new best raises them from the next day on', t => {
  const { app, store, sam, play, clock } = setup(t);
  store.put('runnerMissions', sam, { personId: sam, best: { m: 1400, s: 2000, rose: 60, mask: 20, star: 4, ground: 350, ceiling: 100, passed: { crate: 30, border: 40, drum: 15 } }, runs: 40 });
  clock.now = new Date('2026-10-24T08:00:00Z');
  const before = store.get('runnerMissions', sam);
  const targets = ctx => missionSlots.map(s => missionOptions('distance', s, ctx)[0].target);
  const ctx = () => ({ stats: true, ...bestsOf(store.get('runnerMissions', sam)) });
  assert.deepEqual(targets(ctx()), [425, 600, 800]);
  const today = play(25, { stats: { ground: 25, ceiling: 0 } }).missions.missions;
  for (let i = 0; i < 49; i++) play(25, { stats: { ground: 25, ceiling: 0 } });
  assert.deepEqual(targets(ctx()), [425, 600, 800]);
  assert.deepEqual(store.get('runnerMissions', sam).best, { ...before.best, passed: { ...Object.fromEntries(['crate', 'flat', 'lamp', 'border', 'sandbag', 'drum', 'pile', 'truss', 'drop'].map(k => [k, 0])), ...before.best.passed }, noPickup: 25 });
  assert.equal(store.get('runnerMissions', sam).runs, 90);
  // A new best: today's missions stay, tomorrow's targets are higher.
  const after = play(2000, { stats: { ground: 400, ceiling: 0 } }).missions.missions;
  assert.deepEqual(after.map(m => [m.type, m.kind, m.target]), today.map(m => [m.type, m.kind, m.target]));
  assert.deepEqual(targets(ctx()), [600, 850, 1150]);
  clock.now = new Date('2026-10-25T08:00:00Z');
  const expected = dayMissions(sam, '2026-10-25', ctx(), new Set(today.map(m => m.type)));
  const tomorrow = app.runnerMissions('sam');
  assert.equal(tomorrow.day, '2026-10-25');
  assert.deepEqual(tomorrow.missions.map(m => [m.type, m.kind, m.target]), expected.map(m => [m.type, m.kind, m.target]));
  const distance = tomorrow.missions.find(m => m.type === 'distance');
  if (distance) assert.equal(distance.target, [600, 850, 1150][missionSlots.indexOf(distance.slot)]);
});

test('texts name the target in German', () => {
  assert.equal(missionText({ type: 'distance', target: 850 }).text, 'Lauf 850 m in einem Durchgang');
  assert.equal(missionText({ type: 'collect', kind: 'rose', target: 25 }).text, 'Sammle 25 Rosen in einem Lauf');
  assert.equal(missionText({ type: 'collect', kind: 'star', target: 1 }).text, 'Sammle 1 Stern in einem Lauf');
  assert.equal(missionText({ type: 'ground', target: 300 }).text, 'Bleib 300 m am Boden in einem Lauf');
  assert.equal(missionText({ type: 'ceiling', target: 150 }).text, 'Flieg 150 m unter der Decke in einem Lauf');
  assert.equal(missionText({ type: 'pass', kind: 'truss', target: 8 }).text, 'Unterquere 8 Traversen in einem Lauf');
  assert.equal(missionText({ type: 'pass', kind: 'drum', target: 3 }).text, 'Komm an 3 Kabeltrommeln vorbei in einem Lauf');
  assert.equal(missionText({ type: 'dailyDistance', target: 1500 }).text, 'Lauf heute insgesamt 1.500 m');
  assert.equal(missionText({ type: 'debut', kind: 'truss', target: 750 }).text, 'Erreiche die Traverse: 750 Punkte in einem Lauf');
  assert.equal(missionText({ type: 'runs', target: 3, min: 200 }).text, 'Schaff heute 3 Läufe mit je mindestens 200 m');
});

test('the run statistics are checked for plausibility', () => {
  const ok = { rose: 4, mask: 2, star: 1, ground: 80, ceiling: 20, passed: { crate: 5, border: 4, drum: 1 } };
  const run = { meters: 300, score: 300 + 20 + 20 + 25, metersSent: true };
  assert.deepEqual(checkRunStats(ok, run), { rose: 4, mask: 2, star: 1, ground: 80, ceiling: 20, passed: { crate: 5, border: 4, drum: 1 } });
  const bad = [
    [{ ...ok, ground: 290 }, run], // floor and fly loft more than the distance
    [{ ...ok, rose: 5 }, run], // pickups do not add up to the points beyond the metres
    [{ ...ok, rose: -1 }, run], [{ ...ok, mask: 1.5 }, run], [{ ...ok, passed: { dragon: 1 } }, run], [{ ...ok, passed: [] }, run],
    [{ ...ok, passed: { crate: 60 } }, run], // more obstacles than sections fit
    [{ ...ok, passed: { truss: 1 } }, run], // a truss below 750 points
    [{ rose: 36, mask: 0, star: 0, ground: 0, ceiling: 0 }, { meters: 50, score: 230, metersSent: true }], // more rows than sections
    [{ ground: 0, ceiling: 0, passed: { border: 1 } }, { meters: 60, score: 60, metersSent: true }], // borders only from 80 m
    [ok, { ...run, metersSent: false }], // without the exact metres nothing can be checked
    ['viel', run], [null, run],
  ];
  for (const [stats, r] of bad) assert.equal(checkRunStats(stats, r), null, JSON.stringify(stats));
});

test('implausible statistics count for no mission, the run counts as before', t => {
  const { app, store, sam, play, give } = setup(t);
  give(sam, [{ type: 'distance', target: 100 }, { type: 'collect', kind: 'rose', target: 3 }, { type: 'ground', target: 50 }]);
  // Four roses but points as if there were none: not plausible.
  const run = play(300, { stats: { rose: 4, ground: 120, ceiling: 0 }, score: 300 });
  assert.deepEqual(run.missions.missions.map(m => [m.type, m.progress, m.done]), [['distance', 100, true], ['collect', 0, false], ['ground', 0, false]]);
  assert.equal(run.gained, 300);
  assert.equal(store.get('runnerScores', sam).rounds, 1);
  // The bests take its metres but not its statistics.
  assert.deepEqual([store.get('runnerMissions', sam).best.m, store.get('runnerMissions', sam).best.rose], [300, undefined]);
  // Plausible ones count.
  const next = play(300, { stats: { rose: 4, ground: 120, ceiling: 0 } });
  assert.deepEqual(next.missions.missions.map(m => m.done), [true, true, true]);
});

test('rewards: crate metres once per mission, the Missionskiste for all three, not for the ensemble', t => {
  const { app, store, sam, play, give } = setup(t);
  give(sam, [{ type: 'distance', target: 100 }, { type: 'dailyDistance', target: 500 }, { type: 'collect', kind: 'star', target: 1 }]);
  const first = play(300);
  assert.equal(first.missionBonus, 300);
  assert.deepEqual(first.missions.completed, ['easy']);
  assert.equal(first.missions.missions[0].justDone, true);
  assert.equal(first.missions.missions[1].progress, 300);
  // Again over 100 m: no second reward.
  const second = play(250);
  assert.equal(second.missionBonus, 600);
  assert.deepEqual(second.missions.completed, ['medium']);
  assert.equal(second.missionMeters, 900);
  assert.equal(second.missionCrates, 0);
  const third = play(200, { stats: { star: 1, ground: 0, ceiling: 0 } });
  assert.equal(third.missionBonus, 1000);
  assert.equal(third.missions.allDone, true);
  assert.equal(third.missions.crate.earned, true);
  assert.equal(third.missionCrates, 1);
  assert.equal(third.missions.crate.shinyChance, 0.05);
  // More runs today bring neither metres nor a second crate.
  const more = play(900, { stats: { star: 2, ground: 0, ceiling: 0 } });
  assert.deepEqual([more.missionBonus, more.missionMeters, more.missionCrates], [0, 1900, 1]);
  // Crate metres: real + Tagesbonus (300) + missions; statistics and ensemble: real metres only.
  const w = app.runnerWardrobe('sam');
  assert.equal(w.progress.meters, 1650 + 300 + 1900);
  assert.deepEqual([w.stats.meters, w.stats.missionMeters], [1650, 1900]);
  assert.equal(w.ensemble.meters, 1650);
  assert.equal(store.get('runnerProgress', sam).missionMeters, 1900);
});

test('the Missionskiste opens like a crate, with the shine chance of its kind', t => {
  for (const [random, shiny] of [[0.04, true], [0.06, false]]) {
    const { app, sam, play, give } = setup(t, { random });
    give(sam, [{ type: 'distance', target: 100 }, { type: 'points', target: 100 }, { type: 'dailyDistance', target: 100 }]);
    play(150);
    assert.throws(() => app.runnerOpenCrate('sam', 'mk', { crate: 'mission' }), { status: 400 });
    const opening = app.runnerOpenCrate('sam', `mk-${random}`, { dupes: true, crate: 'mission' });
    assert.equal(opening.outcome.crate, 'mission');
    // 0.04 is below the mission chance (5 %) but above the costume chance (3 %).
    assert.equal(opening.outcome.shiny, shiny);
    assert.equal(opening.wardrobe.progress.missionCrates, 0);
    assert.deepEqual(app.runnerOpenCrate('sam', `mk-${random}`, { dupes: true, crate: 'mission' }), opening);
    assert.throws(() => app.runnerOpenCrate('sam', 'again', { dupes: true, crate: 'mission' }), { status: 409, code: 'no_crate' });
  }
});

test('a new Berlin day brings new missions, also across the change to winter time', t => {
  const { app, store, sam, play } = setup(t, { start: '2026-10-24T12:00:00Z' });
  const first = app.runnerMissions('sam');
  assert.equal(first.day, '2026-10-24');
  // 23:30 CET on 25 October is still the 25th; the 26th begins at 23:00 UTC.
  assert.equal(play(100, { at: '2026-10-24T22:30:00Z' }).missions.day, '2026-10-25');
  assert.deepEqual(store.get('runnerMissions', sam).previousTypes, first.missions.map(m => m.type));
  assert.equal(play(100, { at: '2026-10-25T22:30:00Z' }).missions.day, '2026-10-25');
  assert.equal(play(100, { at: '2026-10-25T23:05:00Z' }).missions.day, '2026-10-26');
  // A day was skipped: nothing to avoid from the day before.
  assert.equal(play(100, { at: '2026-10-28T10:00:00Z' }).missions.day, '2026-10-28');
  assert.deepEqual(store.get('runnerMissions', sam).previousTypes, []);
});

test('one free reroll a day, once per key, never onto a done mission or a type of the day', t => {
  const { app, clock, sam, play, give } = setup(t);
  give(sam, [{ type: 'distance', target: 100 }, { type: 'points', target: 5000 }, { type: 'ground', target: 50 }]);
  play(150);
  assert.throws(() => app.runnerMissionReroll('sam', 'r1', { slot: 'easy' }), { status: 409, code: 'mission_done' });
  assert.throws(() => app.runnerMissionReroll('sam', 'r1', { slot: 'nope' }), { status: 400 });
  const view = app.runnerMissionReroll('sam', 'r2', { slot: 'medium' });
  const medium = view.missions[1];
  assert.equal(medium.rerolled, true);
  assert.ok(!['distance', 'points', 'ground'].includes(medium.type));
  assert.equal(view.rerollAvailable, false);
  assert.deepEqual(app.runnerMissionReroll('sam', 'r2', { slot: 'medium' }), view);
  assert.throws(() => app.runnerMissionReroll('sam', 'r3', { slot: 'hard' }), { status: 409, code: 'reroll_used' });
  // The next day it is there again.
  clock.now = new Date('2026-10-25T09:00:00Z');
  assert.equal(app.runnerMissions('sam').rerollAvailable, true);
});

test('older apps only get missions the server can check without statistics', t => {
  const { app, store, sam, play } = setup(t);
  // Enough history for every type (a record of the earlier version, with its window).
  store.put('runnerMissions', sam, { personId: sam, window: windowOf(300), day: '2026-10-23', missions: [] });
  const old = play(200);
  const basic = Object.entries(missionRules.types).filter(([, d]) => d.basic).map(([type]) => type);
  assert.ok(old.missions.missions.every(m => basic.includes(m.type)), JSON.stringify(old.missions.missions.map(m => m.type)));
  assert.equal(store.get('runnerMissions', sam).stats, false);
  // The next day the new app asks first and gets all types.
  const days = [];
  for (let d = 25; d <= 31; d++) {
    play(200, { at: `2026-10-${d}T06:00:00Z`, stats: { ground: 50, ceiling: 0 } });
    days.push(...store.get('runnerMissions', sam).missions.map(m => m.type));
    assert.equal(store.get('runnerMissions', sam).stats, true);
  }
  assert.ok(days.some(type => !basic.includes(type)));
});

test('instant crashes count for nothing; an earlier window starts the bests once and is dropped', t => {
  const { store, sam, play } = setup(t);
  play(10);
  assert.deepEqual([store.get('runnerMissions', sam).best, store.get('runnerMissions', sam).runs], [{}, 0]);
  for (let i = 0; i < 5; i++) play(100 + i);
  assert.deepEqual([store.get('runnerMissions', sam).best.m, store.get('runnerMissions', sam).runs], [104, 5]);
  store.put('runnerMissions', sam, { personId: sam, window: windowOf(300), day: '2026-10-23', missions: [] });
  play(50);
  const rec = store.get('runnerMissions', sam);
  assert.equal(rec.window, undefined);
  assert.deepEqual([rec.best.m, rec.runs], [480, 31]);
});

test('the HTTP API lists and rerolls missions', async t => {
  const { app } = setup(t);
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  const call = async (method, path, body, key) => {
    const response = await fetch(`${base}${path}`, { method, headers: { Authorization: 'Bearer sam', 'Content-Type': 'application/json', ...(key ? { 'Idempotency-Key': key } : {}) }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    return { status: response.status, body: await response.json() };
  };
  const view = await call('GET', '/games/runner/missions');
  assert.equal(view.status, 200);
  assert.equal(view.body.missions.length, 3);
  assert.equal((await call('POST', '/games/runner/missions/reroll', { slot: 'hard' })).status, 400);
  const rerolled = await call('POST', '/games/runner/missions/reroll', { slot: 'hard' }, 'k1');
  assert.equal(rerolled.status, 200);
  assert.equal(rerolled.body.rerollAvailable, false);
  assert.deepEqual((await call('POST', '/games/runner/missions/reroll', { slot: 'hard' }, 'k1')).body, rerolled.body);
  assert.equal((await call('POST', '/games/runner/missions/reroll', { slot: 'easy' }, 'k2')).body.code, 'reroll_used');
});

test('deleting a person removes their missions', async t => {
  const { app, store, sam, play } = setup(t);
  play(200);
  assert.ok(store.get('runnerMissions', sam));
  await app.deleteAccount('admin', 'sam', store.account('sam').version);
  app.action('admin', { action: 'member.delete', id: sam, version: store.get('members', sam).version }, 'del-1');
  assert.equal(store.get('runnerMissions', sam), null);
});
