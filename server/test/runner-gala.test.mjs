import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { Theater, apiFeatures } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { deliverPush } from '../src/push.mjs';
import { bundledCatalog, loadCatalog, shinyChanceOf } from '../src/runner-wardrobe.mjs';
import { monthAwardsKind, monthBounds, monthScoresKind } from '../src/runner-monthly.mjs';
import { releasedCatalog } from '../src/runner-content-releases.mjs';
import { galaFirstMonth, galaOpensAt, galaPrizes, settleGala } from '../src/runner-gala.mjs';

// Monatsgala: the frozen close of a month, its prizes, the Gala-Kiste and what the app sees.
const rarities = [{ id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 60, gage: 10 }];
const items = [
  ...['character', 'backdrop', 'obstacles', 'fx'].map(kind => ({ id: `${kind}.default`, kind, name: 'Default', rarity: 'hell', default: true })),
  { id: 'h1', kind: 'character', name: 'Hell 1', rarity: 'hell' },
  { id: 'h2', kind: 'character', name: 'Hell 2', rarity: 'hell' },
  { id: 'h3', kind: 'character', name: 'Hell 3', rarity: 'hell' },
];
const octoberOpens = '2026-11-01T09:00:00.000Z';
const novemberOpens = '2026-12-01T09:00:00.000Z';

function setup(t, { start = '2026-10-29T12:00:00Z', pushEnabled = true, random = () => 0.5, store = new Store(), shinyChance = { costume: 0.03, gala: 0.15 }, runnerReleases = [] } = {}) {
  t.after(() => { try { store.close(); } catch { /* closed by an earlier setup on the same store */ } });
  const clock = { now: new Date(start) };
  const make = () => new Theater(store, { bootstrapEmail: 'admin@example.invalid', pushEnabled, clock: () => clock.now, runnerCatalog: loadCatalog({ rarities, items, dupes: { shinyChance } }), runnerReleases, random, missionRules: null });
  const app = make();
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let n = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `gala-${++n}`);
  const person = uid => {
    const personId = action({ action: 'member.save', name: uid }).id;
    app.session({ uid, name: uid, email: `${uid}@example.invalid`, email_verified: true });
    action({ action: 'account.approve', uid, personId, version: 1, role: 'member' });
    return personId;
  };
  const at = iso => { clock.now = new Date(iso); };
  /** A run of a minute that ends at the current clock time with [score]. */
  const play = (uid, score) => {
    const end = clock.now;
    clock.now = new Date(+end - 60000);
    const { roundId } = app.runnerStart(uid);
    clock.now = end;
    return app.runnerScore(uid, { roundId, score });
  };
  /** Runs [scores] (`{ uid: score }`), one minute apart so the earlier best is the first named. */
  const runs = scores => {
    for (const [uid, score] of Object.entries(scores)) { play(uid, score); clock.now = new Date(+clock.now + 60000); }
  };
  const open = (uid, body = {}, id = `open-${++n}`) => app.runnerOpenCrate(uid, id, { dupes: true, crate: 'gala', roles: true, ...body });
  const gala = month => store.get(monthAwardsKind, month);
  const jobs = () => store.all('pushJobs').filter(j => j.title === 'Der Vorhang hebt sich');
  const places = month => gala(month).placements.map(x => [x.personId, x.rank, x.prize, x.crates, x.gage]);
  return { store, app, make, clock, action, person, at, play, runs, open, gala, jobs, places };
}

const four = s => ['anna', 'ben', 'cleo', 'dora'].map(uid => s.person(uid));

test('servers announce the Monatsgala and the first month is one constant', t => {
  const { app } = setup(t);
  assert.ok(apiFeatures.includes('runnerMonthlyGala'));
  assert.ok(app.snapshot('admin').capabilities.features.includes('runnerMonthlyGala'));
  assert.equal(galaFirstMonth, '2026-10');
  assert.deepEqual(galaPrizes.places[1], { prize: 'gold', trophy: 'gold', crates: 3, gage: 0 });
  assert.equal(galaPrizes.applause.gage, 50);
});

test('the gala opens at 10:00 Berlin on the first, in winter and summer time and over the new year', () => {
  assert.equal(galaOpensAt('2026-10'), octoberOpens); // Winter time on the first of November.
  assert.equal(galaOpensAt('2027-03'), '2027-04-01T08:00:00.000Z'); // Summer time on the first of April.
  assert.equal(galaOpensAt('2026-12'), '2027-01-01T09:00:00.000Z'); // The next year.
});

test('nothing closes before 10:00 Berlin; then the placements freeze with their prizes', t => {
  const s = setup(t), [anna, ben, cleo, dora] = four(s);
  s.runs({ anna: 400, ben: 300, cleo: 200, dora: 100 });
  const eve = s.person('eve'); s.play('eve', 50);
  s.at('2026-11-01T08:59:59.999Z'); settleGala(s.app);
  assert.equal(s.gala('2026-10'), null);
  s.at(octoberOpens); settleGala(s.app);
  assert.deepEqual(s.places('2026-10'), [
    [anna, 1, 'gold', 3, 0], [ben, 2, 'silver', 2, 0], [cleo, 3, 'bronze', 1, 0], [dora, 4, 'applause', 0, 50], [eve, 5, 'applause', 0, 50],
  ]);
  assert.equal(s.gala('2026-10').players, 5);
  assert.deepEqual([s.app.runnerWardrobe('anna').gala.crates, s.app.runnerWardrobe('ben').gala.crates, s.app.runnerWardrobe('cleo').gala.crates, s.app.runnerWardrobe('dora').gala.crates], [3, 2, 1, 0]);
  // Applaus: gage as a duplicate brings it; the others get exactly one prize, no gage on top.
  assert.deepEqual(s.app.runnerWardrobe('dora').gage, { balance: 50, earned: 50 });
  assert.deepEqual(s.app.runnerWardrobe('anna').gage, { balance: 0, earned: 0 });
  assert.deepEqual(s.app.runnerWardrobe('anna').gala.trophies, [{ month: '2026-10', trophy: 'gold' }]);
  assert.equal(s.app.runnerWardrobe('anna').progress.galaCrates, 3);
});

test('repeated runs and a restart give nothing twice; later changes leave the gala alone', t => {
  const s = setup(t), [, ben] = four(s);
  s.runs({ anna: 400, ben: 300, cleo: 200, dora: 100 });
  s.at(octoberOpens); settleGala(s.app);
  const frozen = JSON.stringify(s.gala('2026-10'));
  settleGala(s.app); settleGala(s.app);
  // After a restart: a new Theater on the same database.
  const again = s.make(); settleGala(again);
  // An inactive member and a new best for last month's record change nothing.
  s.store.put('members', ben, { ...s.store.get('members', ben), active: false });
  s.store.put(monthScoresKind, `2026-10:${s.store.account('dora').personId}`, { personId: s.store.account('dora').personId, month: '2026-10', best: 9999, bestAt: '2026-10-30T10:00:00.000Z', rounds: 1 });
  settleGala(again);
  assert.equal(JSON.stringify(s.gala('2026-10')), frozen);
  assert.deepEqual(s.app.runnerWardrobe('dora').gage, { balance: 50, earned: 50 });
  assert.equal(s.app.runnerWardrobe('anna').gala.crates, 3);
  assert.equal(s.jobs().length, 1);
});

test('a server down at the opening catches up, every month once and in order, one push for the newest', t => {
  const s = setup(t); four(s);
  s.runs({ anna: 400, ben: 300 });
  s.at('2026-11-20T10:00:00Z'); s.runs({ cleo: 500, dora: 450 });
  s.at('2027-01-03T02:00:00Z'); settleGala(s.app);
  assert.deepEqual([s.gala('2026-10')?.month, s.gala('2026-11')?.month, s.gala('2026-12')?.month], ['2026-10', '2026-11', '2026-12']);
  assert.equal(s.gala('2026-12').placements.length, 0);
  // The newest month had no players: no push at all, and none for the months before.
  assert.equal(s.jobs().length, 0);
  assert.equal(s.gala('2026-10').closedAt, '2027-01-03T02:00:00.000Z');
});

test('catching up pushes once, for the newest month', t => {
  const s = setup(t), [anna, ben] = four(s);
  s.runs({ anna: 400 });
  s.at('2026-11-20T10:00:00Z'); s.runs({ ben: 300 });
  s.at('2026-12-02T08:00:00Z'); settleGala(s.app);
  const [job, ...more] = s.jobs();
  assert.deepEqual(more, []);
  assert.equal(job.body, 'Die Gala des Monats November ist eröffnet.');
  assert.deepEqual(job.recipientPersonIds, [ben]);
  assert.equal(s.gala('2026-10').recipients, undefined);
  assert.deepEqual(s.gala('2026-10').placements.map(x => x.personId), [anna]);
});

test('the start is the constant: months before it have no gala', t => {
  const s = setup(t, { start: '2026-09-15T12:00:00Z' }); four(s);
  s.runs({ anna: 400, ben: 300 });
  s.at('2026-10-05T12:00:00Z'); settleGala(s.app);
  assert.deepEqual(s.store.all(monthAwardsKind), []);
});

test('equal scores share the rank and each gets the prize of it', t => {
  const s = setup(t), [anna, ben, cleo, dora] = four(s);
  s.runs({ anna: 400, ben: 400, cleo: 200, dora: 100 });
  s.at(octoberOpens); settleGala(s.app);
  assert.deepEqual(s.places('2026-10'), [[anna, 1, 'gold', 3, 0], [ben, 1, 'gold', 3, 0], [cleo, 3, 'bronze', 1, 0], [dora, 4, 'applause', 0, 50]]);
  assert.equal(s.app.runnerWardrobe('ben').gala.crates, 3);
  assert.deepEqual(s.app.runnerGala('ben').gala.podium.map(x => [x.rank, x.name, x.trophy, x.me]), [[1, 'anna', 'gold', false], [1, 'ben', 'gold', true], [3, 'cleo', 'bronze', false]]);
});

test('the Aufsteiger: largest gain from rank 4 with a month before; ties by the higher best, then the list', t => {
  const s = setup(t), [anna, ben, cleo, dora] = four(s), eve = s.person('eve'), finn = s.person('finn'), gert = s.person('gert');
  s.at('2026-10-30T12:00:00Z');
  s.runs({ anna: 100, dora: 100, eve: 200, gert: 100 });
  s.at('2026-11-20T12:00:00Z');
  // Anna gains most but stands on the podium; Finn has no October; Dora gains 50 %, Eve 50 % with the higher best.
  s.runs({ anna: 1000, ben: 900, cleo: 800, eve: 300, dora: 150, finn: 140, gert: 90 });
  s.at(novemberOpens); settleGala(s.app);
  const by = Object.fromEntries(s.gala('2026-11').placements.map(x => [x.personId, x]));
  assert.equal(by[anna].prize, 'gold');
  assert.equal(by[eve].prize, 'climber');
  assert.equal(by[eve].crates, 1);
  assert.equal(by[eve].gage, 0);
  assert.equal(by[eve].previous, 200);
  assert.equal(by[dora].prize, 'applause');
  assert.equal(by[finn].prize, 'applause');
  assert.equal(by[gert].prize, 'applause'); // Fallen: no gain, no candidate.
  assert.deepEqual(s.store.get('runnerGalaPrizes', `2026-11:${eve}`), { month: '2026-11', personId: eve, prize: 'climber', crates: 1, opened: 0 }); // No mask.
  assert.equal(s.app.runnerGala('eve').gala.own.previous, 200);
  assert.deepEqual([ben, cleo].map(id => by[id].prize), ['silver', 'bronze']);
});

test('equal gains and equal bests: the list decides, exactly one Aufsteiger', t => {
  const s = setup(t), [, , , dora] = four(s), eve = s.person('eve');
  s.at('2026-10-30T12:00:00Z'); s.runs({ dora: 100, eve: 100 });
  s.at('2026-11-20T12:00:00Z'); s.runs({ anna: 1000, ben: 900, cleo: 800, dora: 200, eve: 200 });
  s.at(novemberOpens); settleGala(s.app);
  assert.deepEqual(s.gala('2026-11').placements.filter(x => x.prize === 'climber').map(x => x.personId), [dora]);
  assert.equal(s.gala('2026-11').placements.find(x => x.personId === eve).rank, 4);
});

test('no Aufsteiger without a month before: October has no September to compare with', t => {
  const s = setup(t, { start: '2026-09-20T12:00:00Z' }); four(s); s.person('eve');
  // All-time bests set in September would show in its list, but that is no month's record.
  s.runs({ dora: 100, eve: 50 });
  s.at('2026-10-29T12:00:00Z'); s.runs({ anna: 900, ben: 800, cleo: 700, eve: 600 });
  s.at(octoberOpens); settleGala(s.app);
  assert.deepEqual(s.gala('2026-10').placements.map(x => x.prize), ['gold', 'silver', 'bronze', 'applause']);
});

test('a new all-time best after the month ended does not take the old one out of its gala', t => {
  // Sam set the best on 15 October, before the month records (only the all-time record knows it).
  const s = setup(t, { start: '2026-10-15T12:00:00Z' }), [anna, ben] = four(s);
  s.play('anna', 500);
  s.store.delete(monthScoresKind, `2026-10:${anna}`);
  s.at('2026-10-20T12:00:00Z'); s.play('ben', 300);
  // Anna beats it at 00:30 on the first, before the gala closes at 10:00: a run of November.
  s.at('2026-10-31T23:30:00Z'); s.play('anna', 600);
  assert.deepEqual(s.store.get(monthScoresKind, `2026-10:${anna}`), { personId: anna, month: '2026-10', best: 500, bestAt: '2026-10-15T12:00:00.000Z', rounds: 0, lastPlayedAt: '2026-10-15T12:00:00.000Z' });
  s.at(octoberOpens); settleGala(s.app);
  assert.deepEqual(s.places('2026-10'), [[anna, 1, 'gold', 3, 0], [ben, 2, 'silver', 2, 0]]);
  // It also still counts as the month before November.
  assert.equal(s.gala('2026-10').placements[0].score, 500);
});

test('a result that reaches the server after midnight counts for the new month, never for the closed one', t => {
  const s = setup(t), [anna] = four(s);
  s.play('anna', 300);
  // Started at 23:59, the result arrives at 00:10 Berlin, and from the outbox at 11:00 it is too old.
  s.at('2026-10-31T22:59:00Z');
  const late = s.app.runnerStart('anna'), older = s.app.runnerStart('ben');
  s.at('2026-10-31T23:10:00Z');
  s.app.runnerScore('anna', { roundId: late.roundId, score: 900 });
  assert.deepEqual(s.app.runnerLeaderboard('anna', { period: 'month', month: '2026-10' }).top.map(x => [x.personId, x.score]), [[anna, 300]]);
  s.at(octoberOpens); settleGala(s.app);
  assert.throws(() => s.app.runnerScore('ben', { roundId: older.roundId, score: 100 }), e => e.code === 'round_expired');
  assert.deepEqual(s.places('2026-10'), [[anna, 1, 'gold', 3, 0]]);
});

test('inactive members are no participants and get nothing', t => {
  const s = setup(t), [, ben] = four(s);
  s.runs({ anna: 400, ben: 300, cleo: 200 });
  s.store.put('members', ben, { ...s.store.get('members', ben), active: false });
  s.at(octoberOpens); settleGala(s.app);
  assert.deepEqual(s.gala('2026-10').placements.map(x => x.name), ['anna', 'cleo']);
  assert.deepEqual(s.gala('2026-10').placements.map(x => x.rank), [1, 2]);
  assert.equal(s.store.all('runnerGalaPrizes').some(x => x.personId === ben), false);
});

test('a score of zero is no participation', t => {
  const s = setup(t); four(s);
  s.runs({ anna: 0, ben: 10 });
  s.at(octoberOpens); settleGala(s.app);
  assert.deepEqual(s.gala('2026-10').placements.map(x => x.name), ['ben']);
  assert.deepEqual(s.jobs()[0].recipientPersonIds, [s.store.account('ben').personId]);
});

test('one neutral push to the participants, kind direct, without a deep link; none without push', t => {
  const s = setup(t), [anna, ben] = four(s);
  s.runs({ anna: 400, ben: 300 });
  s.at(octoberOpens); settleGala(s.app); settleGala(s.app);
  const [job, ...more] = s.jobs();
  assert.deepEqual(more, []);
  assert.equal(job.body, 'Die Gala des Monats Oktober ist eröffnet.');
  assert.equal(job.pushKind, 'direct');
  assert.deepEqual(job.data, {});
  assert.deepEqual(job.recipientPersonIds.sort((x, y) => x - y), [anna, ben].sort((x, y) => x - y));
  assert.equal(JSON.stringify(job).includes('Bühnenlauf'), false);
  assert.equal(s.gala('2026-10').recipients, 2);
  assert.deepEqual(s.store.all('emailJobs'), []);

  const quiet = setup(t, { pushEnabled: false }); four(quiet);
  quiet.runs({ anna: 400 });
  quiet.at(octoberOpens); settleGala(quiet.app);
  assert.equal(quiet.gala('2026-10').placements.length, 1);
  assert.equal(quiet.gala('2026-10').recipients, undefined);
  assert.deepEqual(quiet.store.all('pushJobs'), []);
});

test('the person switched off "Pushes der Leitung": the delivery leaves them out', async t => {
  const s = setup(t), [, ben] = four(s);
  s.runs({ anna: 400, ben: 300 });
  s.store.put('reminders', ben, { personId: ben, direct: false });
  for (const uid of ['anna', 'ben']) s.store.put('devices', uid, { id: uid, uid, token: `token-${uid}`, platform: 'android' });
  for (const job of s.store.all('pushJobs')) s.store.delete('pushJobs', job.id);
  s.at(octoberOpens); settleGala(s.app);
  const sent = [];
  await deliverPush(s.app, { sendEachForMulticast: async m => { sent.push(...m.tokens); return { responses: m.tokens.map(() => ({ success: true })) }; } });
  assert.deepEqual(sent, ['token-anna']);
});

test('the masks of the last gala show in both lists until the next gala', t => {
  const s = setup(t), [anna, ben, , dora] = four(s);
  s.runs({ anna: 400, ben: 300, cleo: 200, dora: 100 });
  s.at(octoberOpens); settleGala(s.app);
  const allTime = s.app.runnerLeaderboard('dora');
  assert.deepEqual(allTime.top.map(x => [x.personId, x.trophy]), [[anna, 'gold'], [ben, 'silver'], [s.store.account('cleo').personId, 'bronze'], [dora, undefined]]);
  s.at('2026-11-05T12:00:00Z'); s.runs({ dora: 900, ben: 800, anna: 700 });
  const month = s.app.runnerLeaderboard('anna', { period: 'month' });
  assert.deepEqual(month.top.map(x => [x.personId, x.trophy]), [[dora, undefined], [ben, 'silver'], [anna, 'gold']]);
  assert.equal(month.own.trophy, 'gold');
  s.at(novemberOpens); settleGala(s.app);
  assert.deepEqual(s.app.runnerLeaderboard('anna').top.filter(x => x.trophy).map(x => [x.personId, x.trophy]), [[dora, 'gold'], [ben, 'silver'], [anna, 'bronze']]);
  // Trophies stay for good, the newest first.
  assert.deepEqual(s.app.runnerWardrobe('anna').gala.trophies, [{ month: '2026-11', trophy: 'bronze' }, { month: '2026-10', trophy: 'gold' }]);
});

test('the celebration is shown once, remembered on the server, and not to who never played', t => {
  const s = setup(t); four(s); s.person('nia');
  s.runs({ anna: 400, ben: 300 });
  s.play('cleo', 0);
  assert.equal(s.app.runnerWardrobe('anna').gala.unseen, null);
  assert.deepEqual(s.app.runnerGala('anna'), { gala: null });
  s.at(octoberOpens); settleGala(s.app);
  const seen = s.app.runnerGala('anna').gala;
  assert.equal(seen.month, '2026-10');
  assert.equal(seen.monthName, 'Oktober');
  assert.deepEqual(seen.own, { rank: 1, score: 400, prize: 'gold', crates: 3, gage: 0, trophy: 'gold' });
  assert.equal(s.app.runnerWardrobe('anna').gala.unseen, '2026-10');
  // Played, but not this month: the podium without an own prize.
  assert.equal(s.app.runnerWardrobe('cleo').gala.unseen, '2026-10');
  assert.equal(s.app.runnerGala('cleo').gala.own, null);
  assert.equal(s.app.runnerWardrobe('nia').gala.unseen, null);
  assert.equal(s.app.runnerGalaSeen('anna', { month: '2026-10', roles: true }).gala.unseen, null);
  assert.equal(s.make().runnerWardrobe('anna').gala.unseen, null);
  // Not beyond the latest gala: the next one is still celebrated.
  assert.equal(s.app.runnerGalaSeen('ben', { month: '2027-05' }).gala.unseen, null);
  assert.equal(s.store.get('runnerProgress', s.store.account('ben').personId).galaSeen, '2026-10');
  assert.throws(() => s.app.runnerGalaSeen('ben', { month: 'x' }), e => e.status === 400);
});

test('deleting a person removes their prizes and every trace in the record', async t => {
  const s = setup(t), [anna, ben, cleo] = four(s);
  s.runs({ anna: 400, ben: 300, cleo: 200 });
  s.at(octoberOpens); settleGala(s.app);
  s.open('ben');
  await s.app.deleteAccount('admin', 'ben', s.store.account('ben').version);
  s.action({ action: 'member.delete', id: ben, version: s.store.get('members', ben).version });
  const record = JSON.stringify(s.gala('2026-10'));
  assert.equal(record.includes('"ben"'), false);
  assert.equal(s.gala('2026-10').placements.some(x => x.personId === ben), false);
  assert.deepEqual(s.gala('2026-10').placements.map(x => [x.personId, x.rank]), [[anna, 1], [cleo, 3]]);
  assert.equal(s.gala('2026-10').players, 3);
  assert.equal(s.store.all('runnerGalaPrizes').some(x => x.personId === ben), false);
  assert.deepEqual(s.app.runnerGala('anna').gala.podium.map(x => x.name), ['anna', 'cleo']);
  assert.deepEqual(s.app.runnerLeaderboard('anna').top.map(x => x.personId), [anna, cleo]);
});

test('no other member\'s name lands in the stored result of an opening', t => {
  const s = setup(t); four(s);
  s.runs({ anna: 400, ben: 300 });
  s.at(octoberOpens); settleGala(s.app);
  s.open('ben', {}, 'stored');
  const { result } = s.store.db.prepare('SELECT result FROM requests WHERE request_id=?').get('runner-crate:stored');
  assert.equal(result.includes('anna'), false);
});

test('a Gala-Kiste draws from everything with its own shine chance and never lapses', t => {
  const s = setup(t); four(s);
  s.runs({ anna: 400 });
  s.at(octoberOpens); settleGala(s.app);
  s.at('2028-05-01T10:00:00Z');
  settleGala(s.app);
  const shiny = setup(t, { random: () => 0.1 }); four(shiny);
  shiny.runs({ anna: 400 });
  shiny.at(octoberOpens); settleGala(shiny.app);
  const opened = shiny.open('anna');
  assert.equal(opened.outcome.crate, 'gala');
  assert.equal(opened.outcome.shiny, true); // 0.1 < 0.15, but not below the 0.03 of a costume crate.
  assert.equal(opened.outcome.month, '2026-10');
  assert.equal(opened.wardrobe.progress.galaCrates, 2);
  assert.equal(opened.wardrobe.progress.crates, 0);
  assert.equal(opened.wardrobe.progress.opened, 0);
  assert.equal(s.app.runnerWardrobe('anna').gala.crates, 3); // Two years later, still there.
  assert.equal(shinyChanceOf(bundledCatalog(), 'gala'), 0.15);
});

test('a repeated request id opens one crate; without a crate 409; older apps get 400', t => {
  const s = setup(t); four(s);
  s.runs({ anna: 400, ben: 300, cleo: 200 });
  s.at(octoberOpens); settleGala(s.app);
  const first = s.open('cleo', {}, 'same');
  const again = s.open('cleo', {}, 'same');
  assert.equal(again.item.id, first.item.id);
  assert.equal(again.wardrobe.gala.crates, 0);
  assert.equal(s.store.all('runnerGalaPrizes').find(x => x.prize === 'bronze').opened, 1);
  assert.throws(() => s.open('cleo'), e => e.status === 409 && e.code === 'no_crate');
  assert.throws(() => s.app.runnerOpenCrate('anna', 'old', { crate: 'gala' }), e => e.status === 400);
  assert.throws(() => s.open('anna', { target: 'random' }), e => e.code === 'unknown_target');
});

test('crates of several galas open the earliest first', t => {
  const s = setup(t); four(s);
  s.runs({ anna: 400, ben: 300, cleo: 200 });
  s.at(octoberOpens); settleGala(s.app);
  s.at('2026-11-05T12:00:00Z'); s.runs({ cleo: 900 });
  s.at(novemberOpens); settleGala(s.app);
  assert.equal(s.app.runnerWardrobe('cleo').gala.crates, 4);
  assert.deepEqual([s.open('cleo'), s.open('cleo')].map(x => x.outcome.month), ['2026-10', '2026-11']);
});

test('older apps see their gage and nothing breaks; a complete wardrobe still opens', t => {
  const s = setup(t); four(s);
  s.runs({ anna: 400, ben: 300, cleo: 200, dora: 100 });
  s.at(octoberOpens); settleGala(s.app);
  // An app that does not ask for roles or know the crate: extra fields only, its counts unchanged.
  const older = s.app.runnerWardrobe('dora');
  assert.equal(older.progress.crates, 0);
  assert.equal(older.gage.balance, 50);
  assert.equal(s.app.runnerWardrobe('anna').progress.crates, 0);
  for (let i = 0; i < 3; i++) s.open('anna');
  assert.equal(s.app.runnerWardrobe('anna').gala.crates, 0);
});

test('without pictures the catalog still has its crate; a hidden release keeps the pictures of crate and masks', t => {
  const data = { rarities, items, crates: { gala: { animation: 'burst', box: [49, 178, 463, 492] } } };
  const plain = loadCatalog(data);
  assert.deepEqual(plain.galaCrate, { id: 'gala', kind: 'gala', name: 'Gala-Kiste', animation: 'burst' });
  assert.deepEqual(plain.galaMasks, {});
  const dir = mkdtempSync(join(tmpdir(), 'gala-art-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  for (const name of ['crate-gala.webp', 'crate-gala-open.webp', 'crate-gala-fx.webp', 'trophy-mask-gold.webp']) writeFileSync(join(dir, name), name);
  const base = loadCatalog(data, new URL(`file://${dir}/`));
  assert.match(base.galaCrate.image, /^\/games\/runner\/skins\/crate-gala\.webp\?v=/);
  assert.deepEqual(base.galaCrate.imageBox, [49, 178, 463, 492]);
  assert.deepEqual(Object.keys(base.galaMasks), ['gold']);
  const hidden = releasedCatalog(base, [{ id: 'later', name: 'Später', startsAt: '2030-01-01T00:00:00.000Z', itemIds: ['h3'], gatedItemIds: [], freeItemIds: [] }], new Date('2026-11-01T12:00:00Z'));
  assert.notEqual(hidden, base);
  for (const name of ['crate-gala.webp', 'crate-gala-open.webp', 'crate-gala-fx.webp', 'trophy-mask-gold.webp']) assert.ok(hidden.files.has(name), name);
  assert.equal(bundledCatalog().galaCrate.animation, 'burst');
});

test('the routes answer with the session of the caller', async t => {
  const s = setup(t); four(s);
  s.runs({ anna: 400 });
  s.at(octoberOpens); settleGala(s.app);
  const server = createHttpServer({ theater: s.app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`, headers = { authorization: 'Bearer anna', 'content-type': 'application/json' };
  const gala = await (await fetch(`${base}/games/runner/gala`, { headers })).json();
  assert.equal(gala.gala.own.prize, 'gold');
  const seen = await (await fetch(`${base}/games/runner/gala/seen`, { method: 'PUT', headers, body: JSON.stringify({ month: '2026-10', roles: true }) })).json();
  assert.equal(seen.gala.unseen, null);
});

test('monthBounds and the gala agree on where a month ends', () => {
  for (const month of ['2026-10', '2026-12', '2027-03']) {
    const end = Date.parse(monthBounds(month).endsAt), opens = Date.parse(galaOpensAt(month));
    // Ten hours after midnight, whatever the offset.
    assert.equal(opens - end, 10 * 3600000);
  }
});
