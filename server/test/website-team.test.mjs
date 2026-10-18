import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import sharp from 'sharp';
import { Store } from '../src/store.mjs';
import { Theater, aboutMaxLength } from '../src/theater.mjs';
import { MediaService } from '../src/media.mjs';
import { createHttpServer } from '../src/http.mjs';
import { applyImport, describePlan, linkWebsiteProfile, parseTeam, planImport, publishedSlugs, sameRole, websiteProfilesView } from '../src/website-team.mjs';

// Shaped like src/data/team.json of the website; roles are listed per play, oldest first.
const teamData = () => ({
  plays: [
    { play: 'Altes Stück', slug: 'alt', year: 2025, location: 'Open-Air-Bühne', gallery: true },
    { play: 'Gruselnacht', slug: 'grusel', year: 2026, location: 'Open-Air-Bühne', gallery: false },
  ],
  current: [
    { id: 'Lina', roles: ['Fee', 'Fiona'], images: 3 },
    { id: 'LinaK', name: 'Lina', roles: ['Ensemble', 'Portrait'], images: 3 },
    { id: 'Tom', roles: ['Ritter', 'Graf Dracula'], images: 3 },
    { id: 'Uli', roles: ['König', null], images: 3 },
    { id: 'Kim', roles: [null, 'Ensemble'], images: 1 },
    { id: 'Robin', roles: [null, 'Ensemble'], images: 1 },
    { id: 'Zoe', roles: [null, 'Ensemble'], images: 1, placeholderAvatar: true },
    { id: 'Ghost', roles: [null, 'Geist'], images: 1 },
  ],
  tech: [
    { id: 'Alex', jobs: [{ job: 'Lichttechnik', icon: 'lightbulb' }], images: 1, since: 2019, placeholderAvatar: true },
    { id: 'Tom', jobs: [{ job: 'Website' }], images: 2, since: 2017 },
  ],
});
// The live team page links every published profile; "Ghost" is not published.
const teamPage = ['Lina', 'LinaK', 'Tom', 'Uli', 'Kim', 'Robin', 'Zoe', 'Alex'].map(s => `<a href="/team/${s}">${s}</a>`).join('');

async function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid' });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let sequence = 0;
  const action = (body, uid = 'admin') => app.action(uid, body, `website-${++sequence}`);
  const ids = {};
  for (const name of ['Lina R.', 'Lina K.', 'Tom', 'Uli', 'Alex', 'Kim Muster', 'Kim Beispiel', 'Robin Sonnenschein']) ids[name] = action({ action: 'member.save', name }).id;
  store.put('productions', 'p-2026', { id: 'p-2026', title: 'Sommerstück 2026 (Gruselnacht)', roles: [{ id: 'FIONA', name: 'FIONA' }, { id: 'GRAF', name: 'GRAF' }], casting: { FIONA: ids['Lina R.'], GRAF: ids.Tom }, version: 1 });
  store.put('productions', 'p-2025', { id: 'p-2025', title: 'Sommerstück 2025', roles: [{ id: 'FEE', name: 'FEE' }, { id: 'RITTER', name: 'RITTER' }, { id: 'KOENIG', name: 'KÖNIG' }], casting: { FEE: ids['Lina R.'], RITTER: ids.Tom, KOENIG: ids.Uli }, version: 1 });
  app.session({ uid: 'sam', name: 'Tom', email: 'tom@example.invalid', email_verified: true });
  action({ action: 'account.approve', uid: 'sam', personId: ids.Tom, version: 1, role: 'member' });
  const media = await mkdtemp(join(tmpdir(), 'website-team-')); t.after(() => rm(media, { recursive: true, force: true }));
  const jpeg = await sharp({ create: { width: 300, height: 400, channels: 3, background: '#a33' } }).jpeg().toBuffer();
  const fetched = [];
  const fetchImpl = async url => { fetched.push(url); return new Response(jpeg, { headers: { 'content-type': 'image/jpeg' } }); };
  const team = parseTeam(teamData(), { published: publishedSlugs(teamPage) });
  return { store, app, action, ids, media, fetchImpl, fetched, team };
}

test('website team data becomes one public profile per person', () => {
  const team = parseTeam(teamData(), { published: publishedSlugs(teamPage) });
  assert.deepEqual(team.skipped, ['Ghost']);
  const tom = team.profiles.find(p => p.slug === 'Tom');
  assert.deepEqual(tom.kinds, ['cast', 'crew']);
  assert.deepEqual(tom.credits, [{ play: 'alt', role: 'Ritter' }, { play: 'grusel', role: 'Graf Dracula' }]);
  assert.deepEqual(tom.current, { play: 'grusel', role: 'Graf Dracula' });
  assert.deepEqual(tom.jobs, [{ job: 'Website', description: 'Gestaltung und Pflege des digitalen Auftritts' }]);
  assert.equal(tom.since, 2025, 'cast members count from their first role, like the website');
  assert.equal(tom.photo, '/img/team/avatar/Tom.jpg');
  const alex = team.profiles.find(p => p.slug === 'Alex');
  assert.equal(alex.since, 2019);
  assert.equal(alex.photo, null, 'placeholder avatars are no photos');
  assert.equal(team.profiles.find(p => p.slug === 'LinaK').name, 'Lina');
  assert.equal(team.profiles.find(p => p.slug === 'Uli').current, null);
  assert.throws(() => parseTeam({ plays: [] }), /Format/);
});

test('role labels match across word forms and alternatives', () => {
  assert.ok(sameRole('GRAF', 'Graf Thaddäus von Falkenstein'));
  assert.ok(sameRole('JUNGE EMMA', 'Emma (jung)'));
  assert.ok(sameRole('MATHILDE', 'Maribel / Mathilde'));
  assert.ok(sameRole('KÖNIG', 'König'));
  assert.ok(!sameRole('FIONA', 'Felia'));
  assert.ok(!sameRole('MIA', 'Mias Mutter'), 'short words must be equal');
});

test('only clear matches are linked; doubtful and missing ones are listed', async t => {
  const { store, ids, team } = await setup(t);
  const plan = planImport(store, team), report = describePlan(store, team, plan);
  const linked = Object.fromEntries(report.linked.map(l => [l.website, l.person]));
  assert.deepEqual(linked, { LinaK: 'Lina K.', Lina: 'Lina R.', Tom: 'Tom', Uli: 'Uli', Alex: 'Alex' });
  assert.match(report.linked.find(l => l.website === 'LinaK').reason, /Namenszusatz/);
  assert.match(report.linked.find(l => l.website === 'Lina').reason, /Fiona/);
  assert.deepEqual(report.uncertain.map(u => [u.website, u.candidates.map(c => c.person).sort()]), [['Kim', ['Kim Beispiel', 'Kim Muster']], ['Robin', ['Robin Sonnenschein']]]);
  assert.deepEqual(report.unmatched.map(u => u.website), ['Zoe']);
  // "Sommerstück 2026 (Gruselnacht)" by its title, "Sommerstück 2025" by its matching cast.
  assert.deepEqual(report.productions.map(p => [p.play, p.production, p.link]), [['Altes Stück (2025)', 'Sommerstück 2025', 'cast'], ['Gruselnacht (2026)', 'Sommerstück 2026 (Gruselnacht)', 'title']]);
  assert.equal(plan.people.get('Uli').personId, ids.Uli);
  assert.equal(store.all('websiteProfiles').length, 0, 'planning writes nothing');
});

test('a contradicting cast keeps a same-name match unlinked', async t => {
  const { store, ids, team } = await setup(t);
  store.put('productions', 'p-2026', { ...store.get('productions', 'p-2026'), casting: { FIONA: ids['Lina R.'], GRAF: ids.Uli } });
  const plan = planImport(store, team);
  assert.equal(plan.people.get('Tom').status, 'auto', 'Tom is still confirmed by the older play');
  store.put('productions', 'p-2026', { ...store.get('productions', 'p-2026'), casting: { FIONA: ids.Tom, GRAF: ids['Lina R.'] } });
  const contradicted = planImport(store, team).people.get('Tom');
  assert.equal(contradicted.status, 'uncertain');
  assert.match(contradicted.candidates[0].contra[0], /spielt in Gruselnacht „FIONA“ statt „Graf Dracula“/);
});

test('applying stores profiles and photos once, keeps manual links and removes departed people', async t => {
  const { store, app, ids, media, fetchImpl, fetched, team } = await setup(t);
  const first = await applyImport(store, team, planImport(store, team), { mediaDirectory: media, fetchImpl });
  assert.deepEqual(first, { photos: 6, newPhotos: 6, photoErrors: [], removedPhotos: 0 });
  assert.ok(fetched.every(url => url.startsWith('https://kolpingtheater-ramsen.de/img/team/avatar/')));
  const tom = store.get('websiteProfiles', 'Tom');
  assert.equal(tom.personId, ids.Tom);
  assert.equal(tom.personLink, 'auto');
  assert.deepEqual(store.get('media', tom.photoId).kind, 'website');
  assert.equal((await readdir(media)).length, 6);
  assert.equal(store.get('websiteProfiles', 'Kim').personId, null, 'uncertain matches stay unlinked');
  assert.equal(store.get('websitePlays', 'grusel').productionId, 'p-2026');

  linkWebsiteProfile(app, 'admin', 'Robin', { personId: ids['Robin Sonnenschein'] });
  linkWebsiteProfile(app, 'admin', 'Lina', { personId: null });
  assert.throws(() => linkWebsiteProfile(app, 'admin', 'Kim', { personId: ids['Robin Sonnenschein'] }), { status: 409 });
  assert.throws(() => linkWebsiteProfile(app, 'sam', 'Kim', { personId: ids['Kim Muster'] }), { status: 403 });
  assert.throws(() => linkWebsiteProfile(app, 'admin', 'Nobody', { personId: null }), { status: 404 });

  const data = teamData(); data.current = data.current.filter(p => p.id !== 'Zoe' && p.id !== 'Uli');
  const next = parseTeam(data, { published: publishedSlugs(teamPage) });
  const plan = planImport(store, next);
  assert.deepEqual(plan.removed.sort(), ['Uli', 'Zoe']);
  assert.equal(plan.people.get('Robin').status, 'manual');
  assert.equal(plan.people.get('Lina').status, 'manualNone', 'an explicit "nobody" is not linked again');
  const second = await applyImport(store, next, plan, { mediaDirectory: media, fetchImpl });
  assert.deepEqual(second, { photos: 5, newPhotos: 0, photoErrors: [], removedPhotos: 1 });
  assert.equal(store.get('websiteProfiles', 'Uli'), null);
  assert.equal(store.get('websiteProfiles', 'Robin').personId, ids['Robin Sonnenschein']);
  assert.equal(store.get('websiteProfiles', 'Lina').personId, null);
  assert.equal((await readdir(media)).length, 5);
  assert.equal(store.all('media').filter(m => m.kind === 'website').length, 5);
});

test('members see linked profiles without private data and may hide theirs', async t => {
  const { store, app, action, ids, media, fetchImpl, team } = await setup(t);
  await applyImport(store, team, planImport(store, team), { mediaDirectory: media, fetchImpl });
  const view = websiteProfilesView(app, 'sam');
  assert.deepEqual(view.profiles.map(p => p.slug).sort(), ['Alex', 'Lina', 'LinaK', 'Tom', 'Uli']);
  const tom = view.profiles.find(p => p.slug === 'Tom');
  assert.deepEqual(tom.credits, [
    { title: 'Gruselnacht', year: 2026, location: 'Open-Air-Bühne', role: 'Graf Dracula', productionId: 'p-2026', galleryUrl: null },
    { title: 'Altes Stück', year: 2025, location: 'Open-Air-Bühne', role: 'Ritter', productionId: 'p-2025', galleryUrl: 'https://kolpingtheater-ramsen.de/gallery/alt' },
  ]);
  assert.equal(tom.url, 'https://kolpingtheater-ramsen.de/team/Tom');
  assert.equal(tom.personLink, undefined, 'link details are for admins');
  const serialized = JSON.stringify(view);
  for (const secret of ['example.invalid', 'attendance', 'photoHash', 'matchReason']) assert.ok(!serialized.includes(secret), secret);
  assert.ok(websiteProfilesView(app, 'admin').profiles.some(p => p.slug === 'Kim' && p.personId === null), 'admins also see unlinked profiles');

  const mediaService = new MediaService(app, { directory: media });
  assert.ok((await mediaService.image('sam', tom.photoId)).bytes.length > 0);
  const profileVersion = store.get('members', ids.Tom).profileVersion ?? 0;
  action({ action: 'profile.save', profileVersion, avatarId: null, websiteHidden: true }, 'sam');
  assert.ok(!websiteProfilesView(app, 'sam').profiles.some(p => p.slug === 'Tom'));
  assert.deepEqual(websiteProfilesView(app, 'admin').profiles.find(p => p.slug === 'Tom'), { slug: 'Tom', name: 'Tom', personId: ids.Tom, personLink: 'auto', hidden: true });
  await assert.rejects(mediaService.image('sam', tom.photoId), { status: 404 });
});

test('people write their own about text; older clients keep it', async t => {
  const { store, action, ids } = await setup(t);
  const version = () => store.get('members', ids.Tom).profileVersion ?? 0;
  action({ action: 'profile.save', profileVersion: version(), avatarId: null, about: '  Spielt seit 2017 mit.\r\n\n\n\nMag Licht.\u0007 ' }, 'sam');
  assert.equal(store.get('members', ids.Tom).about, 'Spielt seit 2017 mit.\n\nMag Licht.');
  action({ action: 'profile.save', profileVersion: version(), avatarId: null }, 'sam');
  assert.equal(store.get('members', ids.Tom).about, 'Spielt seit 2017 mit.\n\nMag Licht.');
  assert.equal(store.get('members', ids.Tom).websiteHidden, false);
  assert.throws(() => action({ action: 'profile.save', profileVersion: version(), avatarId: null, about: 'x'.repeat(aboutMaxLength + 1) }, 'sam'), { status: 400 });
  assert.throws(() => action({ action: 'profile.save', profileVersion: version(), avatarId: null, about: 42 }, 'sam'), { status: 400 });
  action({ action: 'profile.save', profileVersion: version(), avatarId: null, about: '' }, 'sam');
  assert.equal(store.get('members', ids.Tom).about, '');
});

test('website profiles are served to approved members; linking needs an admin', async t => {
  const { store, app, ids, media, fetchImpl, team } = await setup(t);
  await applyImport(store, team, planImport(store, team), { mediaDirectory: media, fetchImpl });
  const server = createHttpServer({ theater: app, verifyToken: async token => ({ uid: token }) });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1/ensemble/website-profiles`;
  const call = (uid, method = 'GET', path = '', body) => fetch(`${base}${path}`, { method, headers: { Authorization: `Bearer ${uid}`, 'Content-Type': 'application/json' }, ...(body ? { body: JSON.stringify(body) } : {}) });
  const list = await call('sam');
  assert.equal(list.status, 200);
  assert.ok((await list.json()).profiles.some(p => p.slug === 'Tom'));
  assert.equal((await call('stranger')).status, 403);
  assert.equal((await call('sam', 'PUT', '/Kim', { personId: ids['Kim Muster'] })).status, 403);
  const linked = await call('admin', 'PUT', '/Kim', { personId: ids['Kim Muster'] });
  assert.equal(linked.status, 200);
  assert.equal((await linked.json()).profiles.find(p => p.slug === 'Kim').personId, ids['Kim Muster']);
});
