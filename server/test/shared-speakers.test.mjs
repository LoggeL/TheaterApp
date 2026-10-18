import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { toScriptDocument } from '../src/mobile-scripts.mjs';
import { migrateSharedSpeakers, sharedSpeakersMigrationId, splitSharedSpeakers } from '../src/shared-speakers.mjs';

const row = (Szene, Kategorie, Charakter, text) => ({ Szene, Kategorie, Charakter, Mikrofon: '', 'Text/Anweisung': text });
const rows = [
  row('0', 'Rolle', 'Romeo', 'Niko'),
  row('0', 'Rolle', 'Julia', 'Jule'),
  row('0', 'Rolle', 'Amme', 'Lina'),
  row('0', 'Rolle', 'Romeo und Julia', 'Niko / Jule'),
  row('1', 'Szenenbeginn', '', 'Balkon'),
  row('1', 'Schauspieler', 'AMME', 'Kinder, es ist spät.'),
  row('1', 'Schauspieler', 'ROMEO UND JULIA', 'Das würde mich glücklich machen.'),
  row('1', 'Schauspieler', 'JULIA & AMME', 'Gute Nacht!'),
  row('1', 'Schauspieler', 'Romeo, Julia und Amme', 'Auf uns!'),
  row('1', 'Schauspieler', 'ALLE', 'Hurra!'),
  row('1', 'Schauspieler', 'ROMEO UND MERCUTIO', 'Wer ist Mercutio?'),
];

test('import turns "X und Y" into a cue with several known speakers', () => {
  const doc = toScriptDocument('romeo', rows);
  const cue = text => doc.cues.find(c => c.text === text);
  assert.deepEqual(cue('Das würde mich glücklich machen.').roles, ['ROMEO', 'JULIA']);
  assert.equal(cue('Das würde mich glücklich machen.').role, 'ROMEO & JULIA');
  assert.deepEqual(cue('Gute Nacht!').roles, ['JULIA', 'AMME']);
  assert.deepEqual(cue('Auf uns!').roles, ['ROMEO', 'JULIA', 'AMME']);
  assert.deepEqual(cue('Kinder, es ist spät.').roles, ['AMME']);
  // Groups and names with unknown parts stay a speaker of their own.
  assert.deepEqual(cue('Hurra!').roles, ['ALLE']);
  assert.deepEqual(cue('Wer ist Mercutio?').roles, ['ROMEO UND MERCUTIO']);
  assert.deepEqual(doc.roles.map(r => r.id), ['ROMEO', 'JULIA', 'AMME', 'ALLE', 'ROMEO UND MERCUTIO']);
  // Cue ids and the revision still match the legacy Skript service.
  const unsplit = rows.map(r => ({ ...r }));
  assert.equal(doc.revision, toScriptDocument('romeo', unsplit).revision);
  assert.deepEqual(splitSharedSpeakers(doc).document, doc, 'already split documents stay unchanged');
  assert.deepEqual(splitSharedSpeakers(doc).unresolved.map(u => [u.roleId, u.reason]), [['ALLE', 'group'], ['ROMEO UND MERCUTIO', 'unknown_roles']]);
});

test('importing a script drops the casting of a combined role', t => {
  const store = new Store(); t.after(() => store.close());
  const theater = new Theater(store);
  store.saveAccount({ uid: 'admin', personId: 1, status: 'approved', role: 'admin', identityReady: true, version: 1 });
  store.put('members', 1, { id: 1, name: 'Niko', active: true });
  const legacy = { productionId: 'romeo', revision: 'r1', scenes: [{ id: '1', title: 'Balkon', ordinal: 0 }], roles: [{ id: 'ROMEO', name: 'ROMEO' }, { id: 'JULIA', name: 'JULIA' }, { id: 'ROMEO UND JULIA', name: 'ROMEO UND JULIA' }], cues: [{ id: 'c1', ordinal: 0, sceneId: '1', category: 'dialogue', role: 'ROMEO UND JULIA', text: 'Ja!' }] };
  store.put('productions', 'romeo', { id: 'romeo', title: 'Romeo und Julia', roles: legacy.roles, casting: { ROMEO: 1, 'ROMEO UND JULIA': 1 }, version: 1 });
  const result = theater.importScript('admin', { id: 'romeo', title: 'Romeo und Julia' }, legacy);
  assert.deepEqual(result.unresolvedSpeakers, []);
  assert.deepEqual(store.get('productions', 'romeo').casting, { ROMEO: 1 });
  assert.deepEqual(store.get('productions', 'romeo').roles.map(r => r.id), ['ROMEO', 'JULIA']);
  assert.deepEqual(theater.script('admin', 'romeo').cues[0].roles, ['ROMEO', 'JULIA']);
});

test('migration splits stored combined roles once and reports groups', t => {
  const store = new Store(); t.after(() => store.close());
  new Theater(store);
  // Simulate data stored before the migration existed.
  store.delete('migrations', sharedSpeakersMigrationId);
  const roles = [
    { id: 'JUNGE MARIE', name: 'JUNGE MARIE', actor: 'Nela' }, { id: 'JUNGE EMMA', name: 'JUNGE EMMA', actor: 'Lina' }, { id: 'JUNGE JOHANNA', name: 'JUNGE JOHANNA', actor: 'Sophie' },
    { id: 'JUNGE EMMA, JUNGE JOHANNA, JUNGE MARIE', name: 'JUNGE EMMA, JUNGE JOHANNA, JUNGE MARIE', actor: '' },
    { id: 'JUNGE JOHANNA & JUNGE EMMA', name: 'JUNGE JOHANNA & JUNGE EMMA', actor: '' },
    { id: 'ALLE', name: 'ALLE', actor: '' }, { id: 'ENSEMBLE 3', name: 'ENSEMBLE 3', actor: 'Julian' },
  ];
  const cue = (id, role) => ({ id, ordinal: Number(id.slice(1)), sceneId: '1', category: 'dialogue', role, text: id });
  const doc = { productionId: 'sommer', revision: 'script-v1-x', scenes: [{ id: '1', title: 'Szene 1', ordinal: 0 }], roles, cues: [cue('c0', 'JUNGE MARIE'), cue('c1', 'JUNGE EMMA, JUNGE JOHANNA, JUNGE MARIE'), cue('c2', 'JUNGE JOHANNA & JUNGE EMMA'), cue('c3', 'ALLE'), cue('c4', 'ENSEMBLE 3'), { id: 'c5', ordinal: 5, sceneId: '1', category: 'direction', role: '', text: 'Abgang.' }] };
  store.put('scripts', 'sommer', doc);
  store.put('productions', 'sommer', { id: 'sommer', title: 'Sommer', roles, casting: { 'JUNGE MARIE': 20, 'JUNGE JOHANNA & JUNGE EMMA': 14 }, revision: 'script-v1-x', version: 4 });
  store.put('comments', 'k1', { id: 'k1', productionId: 'sommer', cueId: 'c2', revision: 'script-v1-x', text: 'Gemeinsam!' });

  new Theater(store);
  const script = store.get('scripts', 'sommer'), production = store.get('productions', 'sommer');
  assert.deepEqual(script.cues.map(c => c.roles ?? null), [['JUNGE MARIE'], ['JUNGE EMMA', 'JUNGE JOHANNA', 'JUNGE MARIE'], ['JUNGE JOHANNA', 'JUNGE EMMA'], ['ALLE'], ['ENSEMBLE 3'], null]);
  assert.equal(script.cues[2].role, 'JUNGE JOHANNA & JUNGE EMMA');
  assert.deepEqual(script.cues.map(c => c.id), doc.cues.map(c => c.id));
  assert.equal(script.revision, 'script-v1-x');
  assert.deepEqual(script.roles.map(r => r.id), ['JUNGE MARIE', 'JUNGE EMMA', 'JUNGE JOHANNA', 'ALLE', 'ENSEMBLE 3']);
  assert.deepEqual(production.roles.map(r => r.id), script.roles.map(r => r.id));
  assert.deepEqual(production.casting, { 'JUNGE MARIE': 20 });
  assert.equal(production.version, 5);
  // Comments refer to cue ids and stay attached.
  assert.equal(store.get('comments', 'k1').cueId, 'c2');
  const { report } = store.get('migrations', sharedSpeakersMigrationId);
  assert.deepEqual(report.productions, [{ productionId: 'sommer', combined: [
    { roleId: 'JUNGE EMMA, JUNGE JOHANNA, JUNGE MARIE', roles: ['JUNGE EMMA', 'JUNGE JOHANNA', 'JUNGE MARIE'], cues: 1 },
    { roleId: 'JUNGE JOHANNA & JUNGE EMMA', roles: ['JUNGE JOHANNA', 'JUNGE EMMA'], cues: 1 },
  ], removedCasting: [{ roleId: 'JUNGE JOHANNA & JUNGE EMMA', personId: 14 }] }]);
  assert.deepEqual(report.unresolved, [{ productionId: 'sommer', roleId: 'ALLE', cues: 1, reason: 'group' }]);

  // A second start, and even a forced re-run, leave everything as it is.
  const snapshot = JSON.stringify([store.all('scripts'), store.all('productions')]);
  new Theater(store);
  assert.equal(migrateSharedSpeakers(store).alreadyApplied, true);
  store.delete('migrations', sharedSpeakersMigrationId);
  assert.deepEqual(migrateSharedSpeakers(store).productions, []);
  assert.equal(JSON.stringify([store.all('scripts'), store.all('productions')]), snapshot);
});
