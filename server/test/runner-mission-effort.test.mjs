import test from 'node:test';
import assert from 'node:assert/strict';
import { missionOptions, missionSlots, dayMissions, seeded } from '../src/runner-missions.mjs';

const recent = Array.from({ length: 10 }, (_, i) => ({ m: 80 + i * 10, s: 120 + i * 15,
  st: { rose: 4, mask: 2, star: 0, ground: 25, ceiling: 0, beforePickup: 12, passed: { crate: 3 } } }));

// Independent reference evaluator: all three slots progress in parallel, including the
// multi-success and cumulative types. Synthetic fixtures are NOT historical counterfactuals.
function completionRuns(missions, population, random) {
  const progress = missions.map(() => 0);
  for (let run = 1; run <= 100; run++) {
    const x = population[Math.floor(random() * population.length)];
    missions.forEach((m, i) => {
      const value = m.type === 'distance' || m.type === 'reach' ? x.m : m.type === 'points' ? x.s
        : m.type === 'collect' ? x.st?.[m.kind] ?? 0 : m.type === 'pass' ? x.st?.passed?.[m.kind] ?? 0
        : m.type === 'noPickup' ? x.st?.beforePickup ?? 0 : x.st?.[m.type] ?? 0;
      progress[i] = m.type === 'dailyDistance' ? progress[i] + x.m
        : m.type === 'runs' ? progress[i] + (x.m >= m.min ? 1 : 0) : Math.max(progress[i], value);
    });
    if (missions.length === 3 && missions.every((m, i) => progress[i] >= m.target)) return run;
  }
  return Infinity;
}

test('whole daily crate median stays within ten runs across seeded synthetic skill fixtures', t => {
  for (const skill of [25, 100, 500, 1500, 6000]) {
    const random = seeded('synthetic-population', skill);
    const population = Array.from({ length: 100 }, (_, i) => {
      // Include 20% instant exits in future effort, even though they cannot calibrate skill.
      const m = i < 20 ? 0 : Math.max(20, Math.round(skill * (0.25 + 1.5 * random())));
      const rose = Math.floor(m / 20 * random()), mask = Math.floor(m / 60 * random()), star = Math.floor(m / 300 * random());
      return { m, s: m + rose * 5 + mask * 10 + star * 25, st: { rose, mask, star,
        ground: Math.floor(m / 3 * random()), ceiling: Math.floor(m / 8 * random()),
        beforePickup: rose + mask + star === 0 ? m : Math.floor(m / 10 * random()), passed: { crate: Math.floor(m / 30 * random()) } } };
    });
    for (const stats of [false, true]) {
      const outcomes = [];
      for (let day = 0; day < 1000; day++) {
        const draw = seeded('synthetic-day', skill, stats, day);
        const attempts = population.filter(x => x.m >= 20);
        const recent = Array.from({ length: 10 }, () => attempts[Math.floor(draw() * attempts.length)]);
        const ctx = { stats, best: { m: skill * 50, s: skill * 100 }, runs: 500, recent };
        const missions = dayMissions(day, '2026-11-11', ctx);
        assert.equal(missions.length, 3);
        outcomes.push(completionRuns(missions, population, draw));
      }
      outcomes.sort((a, b) => a - b);
      const median = (outcomes[499] + outcomes[500]) / 2;
      const withinTen = outcomes.filter(n => n <= 10).length;
      t.diagnostic(JSON.stringify({ fixture: 'synthetic', skill, stats, days: outcomes.length, median, withinTen }));
      assert.ok(median <= 10, `skill ${skill}, stats ${stats}: median ${median}`);
      assert.ok(withinTen >= 500, 'denominator includes failures, not only completed crates');
    }
  }
});

test('zero and rare specialties are omitted instead of inflated to a minimum', () => {
  const ctx = { stats: true, runs: 500, best: { m: 9000, noPickup: 9000 }, recent };
  for (const slot of missionSlots) {
    assert.deepEqual(missionOptions('ceiling', slot, ctx), []);
    assert.ok(!missionOptions('collect', slot, ctx).some(o => o.kind === 'star'));
    assert.ok(!missionOptions('pass', slot, ctx).some(o => o.kind === 'drop'));
    assert.ok(missionOptions('noPickup', slot, ctx)[0].target <= 12);
  }
  const rare = { ...ctx, recent: recent.map((x, i) => ({ ...x, st: { ...x.st, beforePickup: i === 0 ? 2000 : 0 } })) };
  assert.deepEqual(missionOptions('noPickup', 'hard', rare), []);
});

test('cold-start goals cap lifetime records; noPickup never borrows normal distance', () => {
  const ctx = { runs: 500, stats: true, best: { m: 9000, s: 20000, noPickup: 40 } };
  for (const slot of missionSlots) {
    assert.ok(missionOptions('distance', slot, ctx)[0].target <= 400);
    assert.ok(missionOptions('noPickup', slot, ctx).every(o => o.target <= 40));
  }
  assert.deepEqual(missionOptions('noPickup', 'hard', { ...ctx, best: { m: 9000 } }), []);
});

test('every low-performance day still has all three distinct missions', () => {
  const ctx = { stats: false, runs: 100, best: { m: 9000, s: 20000 }, recent: Array.from({ length: 10 }, () => ({ m: 25, s: 25 })) };
  for (let person = 0; person < 500; person++) {
    const missions = dayMissions(person, '2026-11-11', ctx);
    assert.equal(missions.length, 3, `person ${person}`);
    assert.equal(new Set(missions.map(m => m.type)).size, 3);
  }
});

test('recent ordinary performance bounds every distance tier despite a lifetime outlier', () => {
  const ctx = { runs: 500, stats: true, best: { m: 9000, s: 20000 }, recent };
  for (const slot of missionSlots) {
    assert.ok(missionOptions('distance', slot, ctx)[0].target <= 150);
    assert.ok(missionOptions('points', slot, ctx)[0].target <= 225);
  }
});
