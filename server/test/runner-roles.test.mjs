import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { bundledCatalog, loadCatalog, roleName } from '../src/runner-wardrobe.mjs';

// Role figures of the stage runner: every stage role of an actor is an item of its own with `role`,
// `play` and `year`; a technician is one figure with the function as `role` and no play or year.

const rarities = [
  { id: 'hell', name: 'Hellblau', color: '#5E98D9', weight: 1, gage: 10 },
  { id: 'tech', name: 'Technik', color: '#2FBF71', weight: 1, gage: 30, crew: true },
];
const defaults = [
  { id: 'c0', kind: 'character', name: 'Engel Logge', rarity: 'hell', default: true },
  { id: 'b0', kind: 'backdrop', name: 'Wand', rarity: 'hell', default: true },
  { id: 'o0', kind: 'obstacles', name: 'Lager', rarity: 'hell', default: true },
  { id: 'f0', kind: 'fx', name: 'Ohne', rarity: 'hell', default: true },
];
const roleCatalog = items => loadCatalog({ roleFigures: true, rarities, items: [...defaults, ...items] });
const elena = { id: 'elena', kind: 'character', name: 'Elena', role: 'Lucy', play: 'Creepshow', year: 2026, rarity: 'hell', personId: 6 };
const florian = { id: 'florian', kind: 'character', name: 'Florian', role: 'Lichttechnik', rarity: 'tech', personId: 35 };

test('every actor figure of the bundled catalog has role, play and year; technicians only their function', () => {
  const c = bundledCatalog();
  assert.equal(c.roleFigures, true);
  const raw = JSON.parse(readFileSync(new URL('../src/wardrobe/catalog.json', import.meta.url), 'utf8')).items;
  // Waiting figures (`disabled`) are checked too: they only lack their picture.
  const people = raw.filter(x => x.kind === 'character' && x.personId !== undefined);
  const crew = people.filter(x => x.rarity === 'technik'), cast = people.filter(x => x.rarity !== 'technik');
  const complete = x => typeof x.role === 'string' && x.role.trim() && typeof x.play === 'string' && x.play.trim() && Number.isInteger(x.year);
  assert.deepEqual(cast.filter(x => !complete(x)).map(x => x.id), [], 'actor figures without a complete role');
  assert.deepEqual(crew.filter(x => !x.role?.trim() || x.play !== undefined || x.year !== undefined).map(x => x.id), [], 'technicians: a function, no play or year');
  assert.equal(crew.length, 8, 'one figure per technician');
  // A person without a single active figure (new members without a picture yet: Lucia and the
  // technicians Daniel, Elea, Emilia and Julian) is not in the catalog at all, not even disabled;
  // waiting roles of people who already have an active figure stay (Romeo und Julia; in Nexus the KI
  // of Logge and Fynn's ensemble role, both without a costume photo).
  const active = new Set(people.filter(x => x.disabled !== true).map(x => x.personId));
  assert.deepEqual(people.filter(x => !active.has(x.personId)).map(x => x.id), [], 'people without an active figure');
  for (const id of ['lucia', 'daniel', 'elea', 'emilia', 'julian-technik']) assert.ok(!raw.some(x => x.id === `character.${id}` || x.id.startsWith(`character.${id}--`)), id);
  // No person plays the same role twice; ids name person and play.
  assert.equal(new Set(cast.map(x => `${x.personId}|${x.play}|${x.year}|${x.role}`)).size, cast.length);
  assert.ok(cast.filter(x => x.id.includes('--')).every(x => /^character\.[a-z]+--[a-z-]+$/.test(x.id)));
  // Rarities from the importance of the role (proposal of 24.10.2026); Louis stays gold.
  const at = id => c.byId.get(id);
  assert.deepEqual(['elena', 'elena--anno', 'elena--schicksal', 'louis', 'sebastian', 'sebastian--anno', 'raphael--schicksal', 'jonas', 'maren', 'nele--anno', 'anton', 'theo--schicksal'].map(id => at(`character.${id}`)?.rarity),
    ['gold', 'gold', 'rot', 'gold', 'rot', 'rot', 'legacy', 'rot', 'technik', 'gold', 'legacy', 'legacy']);
  // Raphael is a former member: all his roles are legacy, whatever they weigh.
  assert.deepEqual(raw.filter(x => x.personId === 24).map(x => x.rarity), ['legacy', 'legacy', 'legacy']);
  assert.deepEqual([at('character.maren').role, at('character.maren').play], ['Bühnentechnik', undefined]);
  assert.deepEqual([at('character.jonas').role, at('character.jonas').departments], ['Vetter Viktor', ['licht']]);
  assert.deepEqual(['role', 'play', 'year', 'name'].map(k => at('character.raphael--schicksal')[k]), ['Hades', 'Schicksalsfäden', 2025, 'Raphael']);
  // Figures with a picture take part; the others wait for it (Romeo und Julia, earlier plays).
  // Nexus (2024) came in with 24 figures: 10 light blue, 2 blue, 3 pink, 6 legacy, 2 red, 1 gold.
  const count = id => c.collectible.filter(x => x.kind === 'character' && x.rarity === id).length;
  assert.deepEqual(['hellblau', 'blau', 'technik', 'pink', 'legacy', 'rot', 'gold'].map(count), [31, 15, 8, 15, 15, 11, 7]);
  assert.ok(raw.filter(x => x.id.endsWith('--romeo-julia')).every(x => x.disabled === true));
  const nexus = raw.filter(x => x.id.endsWith('--nexus'));
  assert.equal(nexus.length, 26);
  assert.deepEqual(nexus.filter(x => x.disabled === true).map(x => x.id), ['character.logge--nexus', 'character.fynn--nexus']);
  assert.ok(nexus.every(x => x.play === 'Nexus' && x.year === 2024));
  assert.ok(nexus.filter(x => !x.disabled).every(x => c.collectible.includes(at(x.id)) && at(x.id).harness && at(x.id).portrait), 'active Nexus figures can be drawn');
  // Former members stay legacy in Nexus as well, whatever their roles weigh (Raven, Hunter …).
  assert.deepEqual(nexus.filter(x => x.rarity === 'legacy').map(x => x.name), ['Lea', 'Anton', 'Maria', 'Leon', 'Magdalena', 'Theo']);
  assert.deepEqual(['louis', 'sebastian', 'theresa', 'vanessa'].map(id => at(`character.${id}--nexus`).rarity), ['gold', 'rot', 'rot', 'hellblau']);
  // The 34 former role variants are figures of their own, still shown as variants to older apps,
  // like Raphael in Anno 1146 on his Hades, and so are the 24 Nexus roles.
  assert.equal(c.baseOf.size, 59);
  assert.equal(c.baseOf.get('character.raphael--anno'), 'character.raphael--schicksal');
});

test('with role figures an actor figure needs role, play and year, a technician only a function', () => {
  assert.equal(roleCatalog([elena, florian]).byId.get('elena').role, 'Lucy');
  assert.throws(() => roleCatalog([{ ...elena, year: undefined }]), /role, play and year/);
  assert.throws(() => roleCatalog([{ ...elena, play: undefined }]), /role, play and year/);
  assert.throws(() => roleCatalog([{ ...elena, role: ' ' }]), /role of elena/);
  assert.throws(() => roleCatalog([{ ...florian, play: 'Creepshow', year: 2026 }]), /technician/);
  assert.throws(() => roleCatalog([{ ...florian, rarities: ['tech', 'hell'], rarity: undefined }]), /one figure of one rarity/);
  assert.throws(() => roleCatalog([elena, { ...elena, id: 'elena2' }]), /same role twice/);
  // Waiting figures are checked as well.
  assert.throws(() => roleCatalog([{ ...elena, disabled: true, year: undefined }]), /role, play and year/);
  // Figures without a person (the default Engel Logge) need no role.
  assert.ok(roleCatalog([]).byId.get('c0'));
  // Without `roleFigures` older catalogs keep loading as they were.
  assert.equal(loadCatalog({ rarities, items: [...defaults, { id: 'x', kind: 'character', name: 'X', rarity: 'hell', personId: 1 }] }).roleFigures, false);
});

test('variantOf names the person\'s figure an older app shows the role on; it is checked', () => {
  const c = roleCatalog([elena, { ...elena, id: 'elena--anno', role: 'Johanna', play: 'Anno 1146', year: 2025, variantOf: 'elena' }]);
  assert.deepEqual([...c.baseOf], [['elena--anno', 'elena']]);
  assert.deepEqual(c.rolesOf.get('elena').map(x => x.id), ['elena--anno']);
  assert.equal(Object.keys(c.byId.get('elena--anno')).includes('variantOf'), false, 'only for the older view, never sent');
  assert.throws(() => roleCatalog([{ ...elena, variantOf: 'nobody' }]), /variantOf/);
  assert.throws(() => roleCatalog([{ ...elena, variantOf: 'c0' }]), /variantOf/);
  assert.equal(roleName({ role: 'Johanna', play: 'Anno 1146', year: 2025 }), 'Johanna (Anno 1146, 2025)');
  assert.equal(roleName({ role: 'Lucy' }), 'Lucy');
  assert.throws(() => roleCatalog([{ ...elena, importance: 120 }]), /importance/);
});
