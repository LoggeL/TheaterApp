import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Store } from '../src/store.mjs';
import { Theater, runnerMaxMeters } from '../src/theater.mjs';
import { bundledCatalog, loadCatalog } from '../src/runner-wardrobe.mjs';
import { weekRunsKind, weeklyRules } from '../src/runner-weekly.mjs';

// Ghost figures of the Wochenprobe (`runnerGhostFigures`): every ghost keeps the character it was
// run in, checked against what the person owns, and the weekly view says how to draw it.
const rarities = [{ id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 60 }];
const items = [
  ...['character', 'backdrop', 'obstacles', 'fx'].map(kind => ({ id: `${kind}.default`, kind, name: 'Default', rarity: 'hell', default: true })),
  { id: 'h1', kind: 'character', name: 'Hell 1', rarity: 'hell', image: 'character-h1.webp' },
  { id: 'h2', kind: 'character', name: 'Hell 2', rarity: 'hell', image: 'character-h2.webp' },
  // A figure whose picture is not there yet: a silhouette.
  { id: 'h3', kind: 'character', name: 'Hell 3', rarity: 'hell' },
  { id: 'f1', kind: 'fx', name: 'Funken', rarity: 'hell' },
];

/** A catalog with the pictures of [items] in a folder of its own. */
function catalogWithPictures(t) {
  const dir = mkdtempSync(join(tmpdir(), 'ghost-figures-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  for (const name of ['character-h1.webp', 'character-h2.webp']) writeFileSync(join(dir, name), Buffer.from(`RIFF${name}`));
  return loadCatalog({ rarities, items }, pathToFileURL(`${dir}/`));
}

function setup(t, { runnerCatalog = catalogWithPictures(t) } = {}) {
  const store = new Store(); t.after(() => store.close());
  const clock = { now: new Date('2026-11-04T10:00:00Z') };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.now, random: () => 0.5, runnerCatalog, missionRules: null });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let sequence = 0;
  const action = body => app.action('admin', body, `figures-${++sequence}`);
  const ids = {};
  for (const [uid, name] of Object.entries({ sam: 'Sam Beispiel', kim: 'Kim Muster' })) {
    const personId = action({ action: 'member.save', name }).id;
    app.session({ uid, name, email: `${uid}@example.invalid`, email_verified: true });
    action({ action: 'account.approve', uid, personId, version: 1, role: 'member' });
    ids[uid] = personId;
  }
  /**
   * A ranked run of [seconds] that ends now, in [character] as the app says (none: left out). The
   * attempts are given back first: these tests need more than three.
   */
  const play = (uid, seconds, character) => {
    const week = app.runnerWeekly(uid).week, record = store.get(weekRunsKind, `${week}:${ids[uid]}`);
    if (record) store.put(weekRunsKind, `${week}:${ids[uid]}`, { ...record, used: 0 });
    const end = clock.now;
    clock.now = new Date(+end - seconds * 1000);
    const { roundId } = app.runnerStart(uid, { weekly: { week: app.runnerWeekly(uid).week, ranked: true } });
    clock.now = end;
    const meters = Math.floor(runnerMaxMeters(seconds)), n = Math.floor(seconds * weeklyRules.hz) + 1;
    const ghost = Buffer.from([...Array(n).fill(128), 1]).toString('base64');
    const result = app.runnerScore(uid, { roundId, score: meters, meters, ghost, ...(character === undefined ? {} : { character }) });
    clock.now = new Date(+clock.now + 60000);
    return result;
  };
  /** Gives [uid] these items (and selects [selected]). */
  const give = (uid, owned, selected = {}) => {
    app.runnerWardrobe(uid, { roles: true });
    const p = store.get('runnerProgress', ids[uid]);
    store.put('runnerProgress', ids[uid], { ...p, owned: [...p.owned, ...owned], selected: { ...p.selected, ...selected } });
  };
  const stored = uid => store.get(weekRunsKind, `${app.runnerWeekly(uid).week}:${ids[uid]}`).ghost.character;
  const figures = uid => Object.fromEntries(app.runnerWeekly(uid).ghosts.map(x => [x.personId, x.character]));
  return { store, app, ids, play, give, stored, figures };
}

test('a ghost keeps the figure it was run in when the person owns it', t => {
  const { app, ids, play, give, stored, figures } = setup(t);
  give('sam', ['h1', 'h2'], { character: 'h2' });
  play('sam', 60, 'h1');
  // Run in h1, though h2 is selected now: the ghost shows h1.
  assert.equal(stored('sam'), 'h1');
  const h1 = app.runnerWardrobe('sam', { roles: true }).catalog.items.find(x => x.id === 'h1');
  assert.deepEqual(figures('kim')[ids.sam], { id: 'h1', image: h1.image });
  assert.match(h1.image, /^\/games\/runner\/skins\/character-h1\.webp\?v=/);
  // A worse run keeps the ghost of the best, with its figure.
  play('sam', 30, 'h2');
  assert.equal(stored('sam'), 'h1');
  // A better one brings its own.
  play('sam', 90, 'h2');
  assert.equal(stored('sam'), 'h2');
});

test('an unowned, unknown or wrong figure falls back to the selected one', t => {
  const { ids, play, give, stored, figures } = setup(t);
  give('sam', ['h1', 'f1'], { character: 'h1' });
  // h2 is not Sam's: the selected h1 instead, and the run still counts.
  assert.equal(play('sam', 30, 'h2').weekly.improved, true);
  assert.equal(stored('sam'), 'h1');
  for (const [seconds, wanted] of [[40, 'nope'], [50, 'f1'], [60, 42], [70, null], [80, undefined]]) {
    assert.equal(play('sam', seconds, wanted).weekly.improved, true, String(wanted));
    assert.equal(stored('sam'), 'h1', String(wanted));
  }
  // Nothing chosen: the default figure, drawn with the app's own atlas.
  play('kim', 30, 'h1');
  assert.equal(stored('kim'), 'character.default');
  assert.deepEqual(figures('sam')[ids.kim], { id: 'character.default', image: null, default: true });
  // A figure without its picture yet: drawn as a silhouette.
  give('kim', ['h3']);
  play('kim', 60, 'h3');
  assert.deepEqual(figures('sam')[ids.kim], { id: 'h3', image: null });
});

test('a ghost from before figures shows the current selection; one gone from the catalog none', t => {
  const { store, app, ids, play, give, figures } = setup(t);
  give('sam', ['h1'], { character: 'h1' });
  play('sam', 60, 'h1');
  const id = `${app.runnerWeekly('sam').week}:${ids.sam}`, record = store.get(weekRunsKind, id);
  const { character: _, ...old } = record.ghost;
  store.put(weekRunsKind, id, { ...record, ghost: old });
  give('sam', ['h2'], { character: 'h2' });
  assert.equal(figures('kim')[ids.sam].id, 'h2');
  store.put(weekRunsKind, id, { ...record, ghost: { ...old, character: 'gone' } });
  assert.equal(figures('kim')[ids.sam], null);
});

test('a unique figure’s picture only goes to those who may see it', t => {
  const c = bundledCatalog(), unique = c.uniques.find(x => x.image);
  const { store, ids, play, stored, figures } = setup(t, { runnerCatalog: c });
  play('kim', 10);
  const p = store.get('runnerProgress', ids.sam) ?? (play('sam', 5), store.get('runnerProgress', ids.sam));
  store.put('runnerProgress', ids.sam, { ...p, uniques: [unique.id], selected: { ...p.selected, character: unique.id } });
  play('sam', 60, unique.id);
  assert.equal(stored('sam'), unique.id);
  // Sam unlocked it and gets its picture; Kim did not, and draws a silhouette.
  assert.equal(figures('sam')[ids.sam].image, unique.image);
  assert.deepEqual(figures('kim')[ids.sam], { id: unique.id, image: null });
});
