import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { bundledCatalog, crateMilestone, loadCatalog } from '../src/runner-wardrobe.mjs';
import { missionRules, missionSlots } from '../src/runner-missions.mjs';

// Advent Calendar unlock & wardrobe rules:
// - 24 skins released in catalog.json's `adventCalendar` order, Dec 1..24 2026 (Europe/Berlin).
// - Before Day D: completely hidden (catalog, collection, 404 assets, crates, trades, Gage, outfit).
// - On Day D: visible in wardrobe with server lock hint (darkened preview if unowned, full once
//   earned); exclusively unlocked by completing all three Tagesmissionen (replacing Missionskiste).
// - Missed Days D+1..24: stays visible & locked until Dec 25 00:00 Europe/Berlin.
// - Dec 25 00:00 Europe/Berlin+: all 24 enter general random crate & standard Gage economy
//   (Hellblau–Rot directly buyable; Gold via random crate / 50-Gage random crate / Tauschvertrag;
//   Legacy obeys normal 10-hellblau gate), while staying OUT of play-specific crates (`play:*`),
//   play-unique requirements, and starter gifts.

const fixtures = new URL('./fixtures/wardrobe/', import.meta.url);
const bundledOrder = [
  'character.yunus--explosion',
  'character.nele--mumie',
  'character.sophie--waisenhaus',
  'character.elena--ritterin',
  'character.marcella--dienerin',
  'character.carina--anno-mathilde',
  'character.logge--creepshow',
  'character.nele--ballkleid',
  'character.hendrik--partygast',
  'character.maren--creepshow',
  'character.nela--gauklerin',
  'character.lina--gauklerin',
  'character.theresa--falkenstein',
  'character.jakob--partygast',
  'character.julian--partygast',
  'character.elena--strohkleid',
  'character.theo--dorfbewohner',
  'character.theresa--isets-ballkleid',
  'character.till--creepshow',
  'character.logge--partygast',
  'character.niko--butlerpraktikant',
  'character.elena--bademantel',
  'character.lena--anno',
  'character.kuschel--weihnachten',
];

function setupBundled(t, { start = '2026-11-30T22:59:59.000Z', random = () => 0.5 } = {}) {
  const store = new Store(); t.after(() => store.close());
  const clock = { at: new Date(start) };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.at, random });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let n = 0;
  const member = (uid, name) => {
    const personId = app.action('admin', { action: 'member.save', name }, `m-${++n}`).id;
    app.session({ uid, name, email: `${uid}@example.invalid`, email_verified: true });
    app.action('admin', { action: 'account.approve', uid, personId, version: 1, role: 'member' }, `m-${++n}`);
    return personId;
  };
  const sam = member('sam', 'Sam Beispiel');
  const giveMissions = (personId, missions, extra = {}) => {
    app.runnerMissions('sam');
    const rec = store.get('runnerMissions', personId);
    store.put('runnerMissions', personId, {
      ...rec,
      missions: missions.map((m, i) => ({ slot: missionSlots[i], reward: missionRules.slots[missionSlots[i]].reward, unit: 'points', progress: 0, done: false, ...m })),
      ...extra,
    });
  };
  const play = (meters, { uid = 'sam', score = meters, stats } = {}) => {
    const startAt = +clock.at;
    const { roundId } = app.runnerStart(uid);
    clock.at = new Date(startAt + 600000);
    return app.runnerScore(uid, { roundId, score, meters, ...(stats ? { missionStats: stats } : {}) }).progress;
  };
  const patchProgress = (personId, change) => {
    app.runnerWardrobe('sam', { roles: true, unique: true });
    const p = store.get('runnerProgress', personId);
    store.put('runnerProgress', personId, { ...p, ...change(p) });
  };
  return { store, app, clock, sam, member, giveMissions, play, patchProgress };
}

const fileOf = link => link.match(/\/skins\/([^?]+)/)[1];

test('progressive reveal follows Europe/Berlin midnight without restart across Dec 1..25', t => {
  const { app, clock } = setupBundled(t, { start: '2026-11-30T22:59:59.999Z' }); // 23:59:59.999 CET Nov 30
  const base = bundledCatalog();
  assert.deepEqual(base.adventCalendar.entries.map(e => e.item), bundledOrder);

  // Before Dec 1 00:00 Berlin: none of the 24 appear anywhere and all their assets return 404.
  const pre = app.runnerWardrobe('sam', { roles: true, unique: true });
  for (const id of bundledOrder) {
    assert.ok(!pre.catalog.items.some(x => x.id === id), `hidden before Dec 1: ${id}`);
    const full = base.byId.get(id);
    for (const key of ['image', 'portrait', 'thumb']) {
      assert.throws(() => app.runnerSkin('sam', fileOf(full[key])), { status: 404 }, `${id} ${key}`);
    }
  }
  const preTotal = pre.collection.total;

  // Exact Dec 1 00:00:00.000 CET (= Nov 30 23:00:00.000 UTC): Day 1 reveals, Days 2..24 stay hidden!
  clock.at = new Date('2026-11-30T23:00:00.000Z');
  const day1View = app.runnerWardrobe('sam', { roles: true, unique: true });
  const day1 = day1View.catalog.items.find(x => x.id === bundledOrder[0]);
  assert.ok(day1, 'Day 1 revealed at Berlin midnight');
  assert.equal(day1.generalCrateOnly, true);
  assert.equal(day1.lockHint, 'Heute über Tagesmissionen');
  assert.match(day1.lockDetail, /Tagesmissionen/);
  assert.equal(day1View.collection.total, preTotal + 1);
  // Day 1 assets are served for darkened preview portrait; Day 2 assets stay 404.
  assert.equal(app.runnerSkin('sam', fileOf(day1.portrait)).mime, 'image/webp');
  assert.equal(app.runnerSkin('sam', fileOf(day1.thumb)).mime, 'image/webp');
  for (const id of bundledOrder.slice(1)) {
    assert.ok(!day1View.catalog.items.some(x => x.id === id), `still hidden on Dec 1: ${id}`);
    assert.throws(() => app.runnerSkin('sam', fileOf(base.byId.get(id).portrait)), { status: 404 }, id);
  }

  // Dec 2 00:00 Berlin: Day 1 becomes missed-locked, Day 2 gets today's lock hint, Days 3..24 hidden.
  clock.at = new Date('2026-12-01T23:00:00.000Z');
  const day2View = app.runnerWardrobe('sam', { roles: true, unique: true });
  const missed1 = day2View.catalog.items.find(x => x.id === bundledOrder[0]);
  const today2 = day2View.catalog.items.find(x => x.id === bundledOrder[1]);
  assert.equal(missed1.lockHint, 'Ab 25.12. in der Zufallskiste');
  assert.match(missed1.lockDetail, /25\. Dezember/);
  assert.equal(today2.lockHint, 'Heute über Tagesmissionen');
  assert.ok(!day2View.catalog.items.some(x => x.id === bundledOrder[2]));

  // Dec 24 23:59:59.999 CET (= Dec 24 22:59:59.999 UTC): all 24 visible, ALL 24 still locked!
  clock.at = new Date('2026-12-24T22:59:59.999Z');
  const dec24End = app.runnerWardrobe('sam', { roles: true, unique: true });
  for (const id of bundledOrder) {
    const it = dec24End.catalog.items.find(x => x.id === id);
    assert.ok(it, `visible on Dec 24: ${id}`);
    assert.ok(it.lockHint, `still locked before Dec 25: ${id}`);
  }
  assert.equal(dec24End.catalog.items.find(x => x.id === bundledOrder[23]).lockHint, 'Heute über Tagesmissionen');
  assert.equal(dec24End.collection.total, preTotal + 24);

  // Dec 25 00:00:00.000 CET (= Dec 24 23:00:00.000 UTC): lock lifts on ALL 24 without restart!
  clock.at = new Date('2026-12-24T23:00:00.000Z');
  const dec25 = app.runnerWardrobe('sam', { roles: true, unique: true });
  for (const id of bundledOrder) {
    const it = dec25.catalog.items.find(x => x.id === id);
    assert.ok(it, `visible on Dec 25: ${id}`);
    assert.equal(it.lockHint, undefined, `unlocked on Dec 25: ${id}`);
    assert.equal(it.lockDetail, undefined);
    assert.equal(it.generalCrateOnly, true);
  }
});

test('completing all three daily missions on Dec 1..24 awards that day\'s skin instead of a Missionskiste', t => {
  const { app, clock, sam, giveMissions, play } = setupBundled(t, { start: '2026-12-01T10:00:00+01:00' });

  // Before completion: dailyReward hides the skin name/role.
  const before = app.runnerMissions('sam');
  assert.equal(before.day, '2026-12-01');
  assert.equal(before.crate.earned, false);
  assert.equal(before.dailyReward.kind, 'item');
  assert.equal(before.dailyReward.earned, false);
  assert.equal(before.dailyReward.itemId, 'character.yunus--explosion');
  assert.equal(before.dailyReward.name, undefined, 'do not spoil name before unlock');
  assert.equal(before.dailyReward.role, undefined);
  assert.equal(before.dailyReward.earnedSummary, undefined, 'do not leak display name before unlock');
  assert.equal(before.dailyReward.runNote, undefined, 'do not leak runNote before unlock');
  assert.ok(before.dailyReward.summary);

  giveMissions(sam, [
    { type: 'distance', target: 50 },
    { type: 'points', target: 50 },
    { type: 'dailyDistance', target: 50 },
  ]);
  const done = play(100);
  // Individual mission crate points still credit; missionCrates stays 0!
  assert.equal(done.missionBonus, 450 + 900 + 1500);
  assert.equal(done.missionCrates, 0);
  assert.equal(done.missions.allDone, true);
  assert.equal(done.missions.crate.earned, false);
  assert.equal(done.missions.dailyReward.earned, true);
  assert.equal(done.missions.dailyReward.name, 'Yunus');
  assert.match(done.missions.dailyReward.runNote, /Yunus als Dr\. Adrian von Düsterwald \(Explosion\)/);
  assert.match(done.missions.dailyReward.earnedSummary, /Yunus als Dr\. Adrian von Düsterwald \(Explosion\)/);

  // Skin is owned immediately, has no lockHint any more, and can be worn right away!
  const w = app.runnerWardrobe('sam', { roles: true, unique: true });
  assert.ok(w.owned.includes('character.yunus--explosion'));
  assert.equal(w.catalog.items.find(x => x.id === 'character.yunus--explosion').lockHint, undefined);
  assert.equal(app.runnerOutfit('sam', { kind: 'character', itemId: 'character.yunus--explosion', roles: true, unique: true }).selected.character, 'character.yunus--explosion');

  // Further runs on the same day never grant a second copy or a crate.
  const more = play(200);
  assert.equal(more.missionCrates, 0);
  assert.equal(app.runnerWardrobe('sam', { roles: true, unique: true }).owned.filter(id => id === 'character.yunus--explosion').length, 1);

  // Day 17 (Theo Dorfbewohner, rarity: legacy) unlocks unconditionally even with 0 hellblau figures!
  clock.at = new Date('2026-12-17T10:00:00+01:00');
  assert.ok(app.runnerWardrobe('sam', { roles: true, unique: true }).lockedRarities.includes('legacy'));
  giveMissions(sam, [
    { type: 'distance', target: 50 },
    { type: 'points', target: 50 },
    { type: 'dailyDistance', target: 50 },
  ]);
  const day17 = play(100);
  assert.equal(day17.missionCrates, 0);
  assert.equal(day17.missions.dailyReward.itemId, 'character.theo--dorfbewohner');
  assert.ok(app.runnerWardrobe('sam', { roles: true, unique: true }).owned.includes('character.theo--dorfbewohner'));

  // Day 24 (Captain Kuschel Weihnachtsedition, rarity: gold) unlocks directly via Dec 24 missions!
  clock.at = new Date('2026-12-24T10:00:00+01:00');
  giveMissions(sam, [
    { type: 'distance', target: 50 },
    { type: 'points', target: 50 },
    { type: 'dailyDistance', target: 50 },
  ]);
  const day24 = play(100);
  assert.equal(day24.missionCrates, 0);
  assert.equal(day24.missions.dailyReward.itemId, 'character.kuschel--weihnachten');
  assert.match(day24.missions.dailyReward.runNote, /Captain Kuschel \(Weihnachtsedition\)/);
  assert.ok(app.runnerWardrobe('sam', { roles: true, unique: true }).owned.includes('character.kuschel--weihnachten'));

  // Dec 25 reverts back to awarding a normal Missionskiste!
  clock.at = new Date('2026-12-25T10:00:00+01:00');
  assert.equal(app.runnerMissions('sam').dailyReward, undefined);
  giveMissions(sam, [
    { type: 'distance', target: 50 },
    { type: 'points', target: 50 },
    { type: 'dailyDistance', target: 50 },
  ]);
  const dec25 = play(100);
  assert.equal(dec25.missionCrates, 1);
  assert.equal(dec25.missions.crate.earned, true);
  assert.equal(dec25.missions.dailyReward, undefined);
});

test('completing all three missions via reroll on an Advent day awards that day\'s skin once', t => {
  const { app, store, sam, giveMissions, play } = setupBundled(t, { start: '2026-12-02T10:00:00+01:00' });
  play(400);
  giveMissions(sam, [
    { type: 'distance', target: 5000, done: false, progress: 0 },
    { type: 'runs', target: 2, min: 60, done: true, progress: 2 },
    { type: 'points', target: 100, done: true, progress: 100 },
  ], { stats: false, todayMeters: 400 });
  const rerolled = app.runnerMissionReroll('sam', 'reroll-dec2', { slot: 'easy' });
  assert.equal(rerolled.allDone, true);
  assert.equal(rerolled.crate.earned, false);
  assert.equal(rerolled.dailyReward.earned, true);
  assert.equal(rerolled.dailyReward.itemId, 'character.nele--mumie');
  assert.equal(store.get('runnerProgress', sam).missionCrates ?? 0, 0);
  assert.ok(app.runnerWardrobe('sam', { roles: true, unique: true }).owned.includes('character.nele--mumie'));
  // Idempotent retry
  assert.deepEqual(app.runnerMissionReroll('sam', 'reroll-dec2', { slot: 'easy' }), rerolled);
  assert.equal(app.runnerWardrobe('sam', { roles: true, unique: true }).owned.filter(id => id === 'character.nele--mumie').length, 1);
});

test('already-owned Day D skin stays idempotent and rebalanceToday awards Day D skin instead of a crate', t => {
  // Case A: player already owns Day 3 skin before finishing Dec 3 missions.
  const { app, store, sam, giveMissions, play, patchProgress } = setupBundled(t, { start: '2026-12-03T10:00:00+01:00' });
  patchProgress(sam, p => ({ owned: [...(p.owned ?? []), 'character.sophie--waisenhaus'] }));
  giveMissions(sam, [
    { type: 'distance', target: 50 },
    { type: 'points', target: 50 },
    { type: 'dailyDistance', target: 50 },
  ]);
  const done = play(100);
  assert.equal(done.missionCrates, 0);
  assert.equal(done.missions.crate.earned, false);
  assert.equal(done.missions.dailyReward.earned, true);
  assert.equal(store.get('runnerProgress', sam).owned.filter(id => id === 'character.sophie--waisenhaus').length, 1);

  // Case B: legacy effortVersion < current triggers rebalanceToday on Dec 4, lowering an open goal
  // below current progress and completing all three missions -> awards Day 4 skin, not a crate!
  const { app: app2, store: store2, sam: sam2 } = setupBundled(t, { start: '2026-12-04T10:00:00+01:00' });
  app2.runnerWardrobe('sam', { roles: true, unique: true });
  store2.put('runnerMissions', sam2, {
    personId: sam2,
    day: '2026-12-04',
    stats: true,
    effortVersion: 0,
    rerolled: false,
    crate: false,
    todayMeters: 150,
    missions: [
      { slot: 'easy', type: 'distance', target: 100, reward: 450, unit: 'points', progress: 100, done: true },
      { slot: 'medium', type: 'points', target: 150, reward: 900, unit: 'points', progress: 150, done: true },
      // Cold-start hard distance cap is 200 m -> lowering 500 -> 200 completes it with progress 250!
      { slot: 'hard', type: 'distance', target: 500, reward: 1500, unit: 'points', progress: 250, done: false },
    ],
  });
  const view = app2.runnerMissions('sam');
  assert.equal(view.allDone, true);
  assert.equal(view.crate.earned, false);
  assert.equal(view.dailyReward.earned, true);
  assert.equal(view.dailyReward.itemId, 'character.elena--ritterin');
  assert.equal(store2.get('runnerProgress', sam2).missionCrates ?? 0, 0);
  assert.ok(app2.runnerWardrobe('sam', { roles: true, unique: true }).owned.includes('character.elena--ritterin'));
});

test('during Dec 1..24 Advent skins cannot be drawn from crates, traded, or bought; from Dec 25 random crate & standard Gage apply', t => {
  const dice = [];
  const { app, clock, sam, patchProgress } = setupBundled(t, { start: '2026-12-24T12:00:00+01:00', random: () => dice.length ? dice.shift() : 0.99 });

  // Own every non-Advent collectible item so ANY crate or trade would be forced to pick an Advent skin if it were in the pool!
  const dec24Cat = app.runnerCatalog;
  const nonAdventIds = dec24Cat.items.filter(x => !x.default && !x.reward && !x.unique && !bundledOrder.includes(x.id)).map(x => x.id);
  patchProgress(sam, () => ({ owned: nonAdventIds, points: crateMilestone(20), missionCrates: 2, gage: 5000, unlockedRarities: ['legacy'] }));

  // Buying any Advent skin during Dec 1..24 fails with 409 locked (including Gold Day 4 & Day 24!).
  for (const id of ['character.yunus--explosion', 'character.elena--ritterin', 'character.kuschel--weihnachten']) {
    assert.throws(() => app.runnerBuy('sam', `buy-dec24-${id}`, { itemId: id, roles: true, unique: true }), { status: 409, code: 'locked' }, id);
  }
  // Trades offer nothing (every non-Advent item is owned, and Advent skins are excluded!).
  assert.deepEqual(app.runnerWardrobe('sam', { roles: true, unique: true }).trades, []);
  // Opening random crate, mission crate, and 50-Gage crate during Dec 1..24 NEVER draws an Advent skin (every draw is a duplicate of a non-Advent item!).
  for (const [key, body] of [
    ['c-rand', { dupes: true, roles: true, unique: true }],
    ['c-miss', { dupes: true, crate: 'mission', roles: true, unique: true }],
    ['c-gage', { dupes: true, crate: 'gage', roles: true, unique: true }],
  ]) {
    const opened = app.runnerOpenCrate('sam', key, body);
    assert.ok(!bundledOrder.includes(opened.item.id), `${key} must not draw Advent skin: ${opened.item.id}`);
    assert.ok(opened.reel.every(id => !bundledOrder.includes(id)), `${key} reel must not tease Advent skins`);
    assert.equal(opened.outcome.duplicate, true);
  }

  // Cross into Dec 25 00:00 Europe/Berlin!
  clock.at = new Date('2026-12-25T00:00:00+01:00');
  const dec25View = app.runnerWardrobe('sam', { roles: true, unique: true });
  assert.ok(dec25View.trades.length > 0, 'Advent skins now open trades');

  // 1. Direct Gage purchase works for Hellblau–Rot (e.g. pink = 10 * 40 = 400 Gage, hellblau = 100 Gage, legacy = 150 Gage).
  const boughtPink = app.runnerBuy('sam', 'buy-dec25-pink', { itemId: 'character.yunus--explosion', roles: true, unique: true });
  assert.deepEqual(boughtPink.outcome, { type: 'buy', rarity: 'pink', cost: 400 });
  const boughtLegacy = app.runnerBuy('sam', 'buy-dec25-legacy', { itemId: 'character.theo--dorfbewohner', roles: true, unique: true });
  assert.deepEqual(boughtLegacy.outcome, { type: 'buy', rarity: 'legacy', cost: 150 });

  // 2. Gold Advent skins (incl. Day 24 Kuschel) keep standard Gold economy (`not_buyable`, obtainable via random crate & Gold Tauschvertrag).
  assert.throws(() => app.runnerBuy('sam', 'buy-dec25-gold', { itemId: 'character.elena--ritterin', roles: true, unique: true }), { status: 409, code: 'not_buyable' });
  assert.throws(() => app.runnerBuy('sam', 'buy-dec25-kuschel', { itemId: 'character.kuschel--weihnachten', roles: true, unique: true }), { status: 409, code: 'not_buyable' });

  // 3. Random crate & 50-Gage random crate now draw missing Advent skins!
  const randOpen = app.runnerOpenCrate('sam', 'open-dec25-rand', { dupes: true, roles: true, unique: true });
  assert.ok(bundledOrder.includes(randOpen.item.id), `expected Advent skin from random crate, got ${randOpen.item.id}`);
  assert.equal(randOpen.outcome.type, 'new');
  const gageOpen = app.runnerOpenCrate('sam', 'open-dec25-gage', { dupes: true, crate: 'gage', roles: true, unique: true });
  assert.ok(bundledOrder.includes(gageOpen.item.id), `expected Advent skin from 50-Gage random crate, got ${gageOpen.item.id}`);
  assert.equal(gageOpen.outcome.type, 'new');

  // 4. Gold Tauschvertrag (from rot) can draw Gold Advent skins (incl. Kuschel)!
  const tradedGold = app.runnerTrade('sam', 'trade-dec25-gold', { rarity: 'rot', roles: true, unique: true });
  assert.equal(tradedGold.outcome.rarity, 'gold');
  assert.ok(bundledOrder.includes(tradedGold.item.id), `expected Gold Advent skin from trade, got ${tradedGold.item.id}`);

  // 5. Play-specific crates (`play:creepshow`, `play:anno-1146`) STILL NEVER include Advent skins!
  for (const target of ['play:creepshow', 'play:anno-1146']) {
    const pool = app.runnerCatalog.targetItems.get(target);
    assert.ok(pool.length > 0);
    assert.deepEqual(pool.filter(x => bundledOrder.includes(x.id)), [], `${target} must never include Advent skins`);
    const opened = app.runnerOpenCrate('sam', `open-dec25-${target}`, { dupes: true, target, roles: true, unique: true });
    assert.ok(!bundledOrder.includes(opened.item.id), `${target} drew Advent skin ${opened.item.id}`);
    assert.equal(opened.outcome.duplicate, true, `${target} stays complete without Advent skins`);
  }
});

test('Day 17 Legacy obeys normal Legacy requirement after Dec 24; play Uniques and starter gifts stay unaffected', t => {
  const { app, clock, member } = setupBundled(t, { start: '2026-11-25T12:00:00+01:00' });
  const preUniques = app.runnerWardrobe('sam', { roles: true, unique: true }).uniqueFigures.plays.map(p => [p.play, p.total]);

  // On Dec 25, Beatrice / Captain Kuschel / Ritterpuppe required counts are unchanged!
  clock.at = new Date('2026-12-25T12:00:00+01:00');
  const postUniques = app.runnerWardrobe('sam', { roles: true, unique: true }).uniqueFigures.plays.map(p => [p.play, p.total]);
  assert.deepEqual(postUniques, preUniques, 'Advent skins must not change play unique requirements');

  // Fresh member on Dec 25 with 0 hellblau figures cannot buy Day 17 (Legacy) yet.
  const kimId = member('kim', 'Kim Beispiel');
  app.runnerWardrobe('kim', { roles: true, unique: true });
  app.store.put('runnerProgress', kimId, { ...app.store.get('runnerProgress', kimId), gage: 1000 });
  assert.throws(() => app.runnerBuy('kim', 'kim-theo', { itemId: 'character.theo--dorfbewohner', roles: true, unique: true }), { status: 409, code: 'locked', message: 'Sammle 10 hellblaue Figuren' });

  // Starter gift for a member whose personId has a low-rarity Advent skin (e.g. personId 1 = Logge, who has hellblau Advent skins) never picks an Advent skin!
  const synthetic = loadCatalog({
    roleFigures: true,
    rarities: [
      { id: 'hellblau', name: 'Hellblau', color: '#5E98D9', weight: 60, gage: 10 },
      { id: 'gold', name: 'Gold', color: '#E4AE39', weight: 10, gage: 200, buyable: false },
    ],
    adventSchedule: { year: 2026, month: 12 },
    adventCalendar: [{ item: 'character.adv-hell', title: 'Adv' }],
    items: [
      { id: 'c0', kind: 'character', name: 'Engel', rarity: 'hellblau', default: true },
      { id: 'b0', kind: 'backdrop', name: 'Wand', rarity: 'hellblau', default: true },
      { id: 'o0', kind: 'obstacles', name: 'Lager', rarity: 'hellblau', default: true },
      { id: 'f0', kind: 'fx', name: 'Ohne', rarity: 'hellblau', default: true },
      // Regular role is gold; Advent role is hellblau (lower rank) -> gift MUST pick regular gold role, NEVER the Advent role!
      { id: 'character.reg-gold', kind: 'character', name: 'Alex', role: 'Held', play: 'Spuk', year: 2026, rarity: 'gold', personId: 500, image: 'figure.webp' },
      { id: 'character.adv-hell', kind: 'character', name: 'Alex', role: 'Gast', play: 'Spuk', year: 2026, rarity: 'hellblau', personId: 500, image: 'figure.webp' },
    ],
  }, fixtures);
  const store2 = new Store(); t.after(() => store2.close());
  const app2 = new Theater(store2, { bootstrapEmail: 'admin@example.invalid', clock: () => new Date('2026-12-26T12:00:00Z'), runnerCatalog: synthetic, missionRules: null });
  app2.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  store2.put('members', 500, { id: 500, name: 'Alex', active: true });
  app2.session({ uid: 'alex', name: 'Alex', email: 'alex@example.invalid', email_verified: true });
  app2.action('admin', { action: 'account.approve', uid: 'alex', personId: 500, version: 1, role: 'member' }, 'approve-alex');
  const alexW = app2.runnerWardrobe('alex', { roles: true });
  assert.equal(alexW.gift, 'character.reg-gold');
  assert.ok(!alexW.owned.includes('character.adv-hell'));
});

test('over HTTP: Advent assets and daily missions switch cleanly across Berlin midnight', async t => {
  const { app, clock } = setupBundled(t, { start: '2026-11-30T22:59:59.000Z' });
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const baseUrl = `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
  const get = path => fetch(`${baseUrl}${path}`, { headers: { Authorization: 'Bearer sam' } });

  const day1Thumb = fileOf(bundledCatalog().byId.get('character.yunus--explosion').thumb);
  assert.equal((await get(`/games/runner/skins/${day1Thumb}`)).status, 404);
  assert.equal((await (await get('/games/runner/missions')).json()).dailyReward, undefined);

  clock.at = new Date('2026-11-30T23:00:00.000Z'); // Dec 1 00:00 Berlin
  assert.equal((await get(`/games/runner/skins/${day1Thumb}`)).status, 200);
  const missions = await (await get('/games/runner/missions')).json();
  assert.equal(missions.dailyReward.kind, 'item');
  assert.equal(missions.dailyReward.itemId, 'character.yunus--explosion');
  assert.equal(missions.dailyReward.earned, false);
});
