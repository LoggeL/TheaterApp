import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { crateMilestone, loadCatalog, openRarities, reel, runnerUnlocks } from '../src/runner-wardrobe.mjs';

// Legacy is the rarest rarity but stays locked until all blue characters are owned.
const rarities = [
  { id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 60, gage: 10 },
  { id: 'blau', name: 'Blau', color: '#4B69FF', weight: 30, gage: 20 },
  { id: 'gold', name: 'Gold', color: '#E4AE39', weight: 10, gage: 200, exclusive: true, buyable: false },
  { id: 'legacy', name: 'Legacy', color: '#A47A4B', weight: 8, style: 'antique', requires: { rarity: 'blau', kind: 'character' }, hint: 'Sammle alle blauen Figuren' },
];
const defaults = [
  { id: 'c0', kind: 'character', name: 'Engel Logge', rarity: 'hell', default: true },
  { id: 'b0', kind: 'backdrop', name: 'Wand', rarity: 'hell', default: true },
  { id: 'o0', kind: 'obstacles', name: 'Lager', rarity: 'hell', default: true },
  { id: 'f0', kind: 'fx', name: 'Ohne', rarity: 'hell', default: true },
];
const items = [
  { id: 'h1', kind: 'character', name: 'Hell 1', rarity: 'hell' },
  { id: 'h2', kind: 'fx', name: 'Hell 2', rarity: 'hell' },
  { id: 'b1', kind: 'character', name: 'Blau 1', rarity: 'blau' },
  { id: 'b2', kind: 'backdrop', name: 'Blau 2', rarity: 'blau' },
  { id: 'g1', kind: 'character', name: 'Gold 1', rarity: 'gold' },
  { id: 'g2', kind: 'backdrop', name: 'Gold 2', rarity: 'gold' },
  { id: 'g3', kind: 'fx', name: 'Gold 3', rarity: 'gold' },
  { id: 'l1', kind: 'character', name: 'Anton', rarity: 'legacy' },
];
const fixtures = new URL('./fixtures/wardrobe/', import.meta.url);
const c = loadCatalog({ rarities, items: [...defaults, ...items] }, fixtures);
const rankOf = id => c.rarity.get(c.byId.get(id).rarity).rank;
const seeded = (seed = 7) => () => (seed = (seed * 16807) % 2147483647) / 2147483647;
const baseOwned = ['c0', 'b0', 'o0', 'f0'];

/**
 * The near miss of each of [runs] reels for [winner] (null when there is none). The dice are
 * counted: after two per filler card come the near-miss chance, its side and its pick.
 */
function nearMisses(winner, owned, runs = 20000) {
  const have = new Set(owned), open = openRarities(c, have), random = seeded();
  let dice = [];
  const t = { runnerCatalog: c, random: () => { const r = random(); dice.push(r); return r; } };
  return Array.from({ length: runs }, () => {
    dice = [];
    const { reel: cards, winnerIndex } = reel(t, c.byId.get(winner), open, have);
    assert.equal(cards.length, runnerUnlocks.reelLength);
    assert.equal(cards[winnerIndex], winner);
    assert.ok(!cards.includes('l1'), 'locked rarities are not teased');
    const filler = 2 * runnerUnlocks.reelLength;
    if (dice.length === filler + 1) return null;
    assert.equal(dice.length, filler + 3);
    const id = cards[winnerIndex + (dice[filler + 1] < 0.5 ? -1 : 1)];
    assert.notEqual(id, winner);
    assert.ok(rankOf(id) > rankOf(winner), `${id} is rarer than ${winner}`);
    return id;
  });
}
const tally = ids => { const counts = {}; for (const id of ids.filter(Boolean)) counts[id] = (counts[id] ?? 0) + 1; return counts; };
const even = counts => { const v = Object.values(counts); return Math.min(...v) / Math.max(...v); };

test('the near miss is rarer than the winner, never the winner or locked, spread at random', () => {
  assert.equal(runnerUnlocks.nearMissChance, 0.28);
  const runs = 20000, misses = nearMisses('h1', baseOwned, runs), counts = tally(misses);
  // Everything rarer than hell and open: blue and gold alike, no catalog-order favourite.
  assert.deepEqual(Object.keys(counts).sort(), ['b1', 'b2', 'g1', 'g2', 'g3'], JSON.stringify(counts));
  assert.ok(even(counts) > 0.85, JSON.stringify(counts));
  const shown = misses.filter(Boolean).length;
  assert.ok(Math.abs(shown / runs - 0.28) < 0.01, `${shown / runs}`);
  // For a blue winner only gold is rarer: all three gold items show up, roughly evenly.
  const gold = tally(nearMisses('b1', baseOwned, runs));
  assert.deepEqual(Object.keys(gold).sort(), ['g1', 'g2', 'g3'], JSON.stringify(gold));
  assert.ok(even(gold) > 0.85, JSON.stringify(gold));
  // Missing ones first: with g1 and g3 owned only g2 is teased; with all owned, all of them again.
  assert.deepEqual(Object.keys(tally(nearMisses('b1', [...baseOwned, 'g1', 'g3'], 3000))), ['g2']);
  assert.deepEqual(Object.keys(tally(nearMisses('b1', [...baseOwned, 'g1', 'g2', 'g3'], 3000))).sort(), ['g1', 'g2', 'g3']);
});

test('nothing rarer than the winner: no near miss and no extra die', () => {
  // Gold is the rarest open rarity (legacy is locked).
  const have = new Set(baseOwned); let calls = 0;
  const t = { runnerCatalog: c, random: () => { calls++; return 0; } };
  reel(t, c.byId.get('g1'), openRarities(c, have), have);
  assert.equal(calls, 2 * runnerUnlocks.reelLength);
});

test('the near miss happens with nearMissChance and prefers missing items', () => {
  // Dice: no rarer filler (all hell), then the near miss and its pick decide.
  const fillerOnlyHell = () => { let i = 0; return () => (i++ < 2 * runnerUnlocks.reelLength ? 0.01 : null); };
  const run = (owned, after) => {
    const filler = fillerOnlyHell(), rest = [...after];
    const t = { runnerCatalog: c, random: () => filler() ?? rest.shift() };
    const have = new Set(owned);
    return reel(t, c.byId.get('b1'), openRarities(c, have), have).reel;
  };
  // Below the chance: a near miss, left (die < .5) ...
  const left = run(baseOwned, [0.27, 0.1, 0]);
  assert.equal(left[runnerUnlocks.reelWinner - 1], 'g1');
  // ... or right, and the pick goes by the die, not the catalog order.
  const right = run(baseOwned, [0.27, 0.9, 0.99]);
  assert.equal(right[runnerUnlocks.reelWinner + 1], 'g3');
  // At or above the chance: no near miss.
  const none = run(baseOwned, [0.28]);
  assert.ok(!none.some(id => id.startsWith('g')));
  // g1 and g3 owned: only g2 is missing, whatever the die.
  for (const die of [0, 0.5, 0.99]) assert.equal(run([...baseOwned, 'g1', 'g3'], [0.1, 0.1, die])[runnerUnlocks.reelWinner - 1], 'g2');
  // All gold owned: any of them again.
  const all = [...baseOwned, 'g1', 'g2', 'g3'];
  assert.deepEqual([0, 0.5, 0.99].map(die => run(all, [0.1, 0.1, die])[runnerUnlocks.reelWinner - 1]), ['g1', 'g2', 'g3']);
});

test('crate openings tease what the person was missing before, and a repeat answers the same', t => {
  const filler = Array(2 * runnerUnlocks.reelLength).fill(0.01);
  for (const dupes of [true, false]) {
    const store = new Store(); t.after(() => store.close());
    const dice = [];
    const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => new Date('2026-10-24T10:00:00Z'), runnerCatalog: c, random: () => dice.length ? dice.shift() : 0.99 });
    app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
    app.runnerWardrobe('admin');
    const personId = app.account('admin').personId, p = store.get('runnerProgress', personId);
    // Missing above hell: b1 and g2 (l1 stays locked until b1 is owned).
    store.put('runnerProgress', personId, { ...p, points: crateMilestone(4), owned: [...p.owned, 'b2', 'g1', 'g3'] });
    // The draw (hell, h1; for the new app no shine), the filler, then near miss, left, last pick.
    dice.push(0.01, 0, ...(dupes ? [0.99] : []), ...filler, 0.1, 0.1, 0.99);
    const body = dupes ? { dupes: true, roles: true } : undefined;
    const r = app.runnerOpenCrate('admin', 'k1', body);
    assert.equal(dice.length, 0, `${dupes}: every die used`);
    assert.equal(r.item.id, 'h1');
    assert.equal(r.reel[r.winnerIndex], 'h1');
    // Without the ownership the last of b1, b2, g1, g2, g3 would be g3.
    assert.equal(r.reel[r.winnerIndex - 1], 'g2', `${dupes}`);
    assert.deepEqual(app.runnerOpenCrate('admin', 'k1', body), r, 'a repeat returns the stored result');
  }
});
