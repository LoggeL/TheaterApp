import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import sharp from 'sharp';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { MediaService } from '../src/media.mjs';
import { Immich } from '../src/immich.mjs';
import { createHttpServer } from '../src/http.mjs';

async function setup(t) {
  const store = new Store(), directory = await mkdtemp(join(tmpdir(), 'theater-media-'));
  t.after(async () => { store.close(); await rm(directory, { recursive: true, force: true }); });
  const app = new Theater(store, { bootstrapEmail: 'admin@example.com' });
  app.session({ uid: 'admin', email: 'admin@example.com', email_verified: true });
  const personId = app.action('admin', { action: 'member.save', name: 'Sam' }, 'member').id;
  app.session({ uid: 'sam', email: 'sam@example.com', email_verified: true });
  app.action('admin', { action: 'account.approve', uid: 'sam', personId, role: 'member', version: 1 }, 'approve');
  app.session({ uid: 'pending', email: 'pending@example.com', email_verified: true });
  const media = new MediaService(app, { directory });
  const input = await sharp({ create: { width: 800, height: 400, channels: 3, background: '#ab5010' } }).jpeg().withMetadata({ exif: { IFD0: { Artist: 'private metadata' } } }).toBuffer();
  return { app, store, media, personId, content: input.toString('base64') };
}

test('profile uploads require approval and profile save cannot select another person or image', async t => {
  const { app, store, media, personId, content } = await setup(t);
  await assert.rejects(media.upload('pending', { kind: 'profile', content }), { status: 403 });
  const image = await media.upload('sam', { kind: 'profile', content });
  await assert.rejects(media.image('admin', image.id), { status: 404 });
  assert.throws(() => app.action('admin', { action: 'profile.save', avatarId: image.id, tagline: '', profileVersion: 0 }, 'spoof'), { status: 403 });
  app.action('sam', { action: 'profile.save', avatarId: image.id, tagline: '  Auf der Bühne!  ', profileVersion: 0, personId: 1, role: 'admin' }, 'save');
  assert.equal(app.snapshot('sam').user.tagline, 'Auf der Bühne!');
  assert.equal(store.account('sam').role, 'member');
  assert.equal(store.get('members', 1).avatarId, undefined);
  assert.equal(store.get('members', personId).avatarId, image.id);
  const processed = await media.image('admin', image.id), metadata = await sharp(processed.bytes).metadata();
  assert.equal(metadata.format, 'webp'); assert.equal(metadata.width, 512); assert.equal(metadata.height, 512); assert.equal(metadata.exif, undefined);
  assert.throws(() => app.action('sam', { action: 'profile.save', avatarId: image.id, tagline: 'Stale', profileVersion: 0 }, 'stale'), { status: 409 });
  assert.throws(() => app.action('sam', { action: 'profile.save', avatarId: image.id, tagline: 'x'.repeat(121), profileVersion: 1 }, 'long'), { status: 400 });
});

test('gallery uploads are admin-only, paginate, hide and restore without crossing album boundaries', async t => {
  const { media, content } = await setup(t);
  await assert.rejects(media.saveGallery('sam', { title: 'Unauthorized' }), { status: 403 });
  const g = await media.saveGallery('admin', { title: 'Rehearsal' });
  const other = await media.saveGallery('admin', { title: 'Other' });
  await assert.rejects(media.upload('sam', { kind: 'gallery', galleryId: g.id, content }), { status: 403 });
  const one = await media.upload('admin', { galleryId: g.id, content });
  await media.upload('admin', { galleryId: g.id, content });
  const page = await media.page('sam', g.id, { limit: 1 });
  assert.equal(page.total, 2); assert.equal(page.assets.length, 1); assert.equal(page.nextOffset, 1);
  assert.equal((await media.page('sam', g.id, { offset: 1, limit: 1 })).nextOffset, null);
  await assert.rejects(media.galleryImage('sam', other.id, `local-${one.id}`), { status: 404 });
  media.visibility('admin', one.id, true);
  await assert.rejects(media.image('sam', one.id), { status: 404 });
  await assert.rejects(media.page('sam', g.id, { includeHidden: true }), { status: 403 });
  assert.equal((await media.page('sam', g.id)).total, 1);
  assert.equal((await media.page('admin', g.id, { includeHidden: true })).total, 2);
  media.visibility('admin', one.id, false);
  assert.equal((await media.page('sam', g.id)).total, 2);
  await assert.rejects(media.upload('sam', { kind: 'profile', content: Buffer.from('<svg/>').toString('base64') }), { status: 400 });
});

function fakeSource({ allowDownload = true, fetches = [] } = {}) {
  return new Immich({ fetcher: async input => {
    const u = new URL(input); fetches.push(u.pathname);
    if (u.pathname === '/s/photos') return new Response('<meta property="og:image" content="https://photo.rittmann.cloud/api/assets/a/thumbnail?key=private-share-key">');
    assert.equal(u.searchParams.get('key'), 'private-share-key');
    if (u.pathname === '/api/shared-links/me') return Response.json({ type: 'ALBUM', allowDownload, album: { id: 'album', albumName: 'Photos' } });
    if (u.pathname === '/api/timeline/buckets') return Response.json([{ timeBucket: '2026-08-01' }, { timeBucket: '2026-07-01' }]);
    if (u.pathname === '/api/timeline/bucket') return Response.json(u.searchParams.get('timeBucket') === '2026-08-01' ? { id: ['a', 'b', 'trash'], isImage: [true, false, true], isTrashed: [false, false, true], fileCreatedAt: ['2026-08-02', '2026-08-01', '2026-08-03'], ratio: [1.5, .75, 1] } : [{ id: 'a', type: 'IMAGE', fileCreatedAt: '2026-08-02' }, { id: 'c', type: 'IMAGE', fileCreatedAt: '2026-07-01' }]);
    if (/\/assets\/a\/(thumbnail|original)$/.test(u.pathname)) return new Response('original-image-bytes', { headers: { 'Content-Type': 'image/jpeg' } });
    throw Error('Unexpected request');
  } });
}
test('Immich validates source hosts, resolves custom slugs, deduplicates columnar and legacy pages', async t => {
  const { media } = await setup(t), fetches = []; media.immich = fakeSource({ fetches });
  for (const url of ['http://photo.rittmann.cloud/s/photos', 'https://127.0.0.1/s/photos', 'https://photo.rittmann.cloud.evil.test/s/photos', 'https://user:pw@photo.rittmann.cloud/s/photos', 'https://photo.rittmann.cloud/api/server', 'https://photo.rittmann.cloud/s/photos?foo=bar']) assert.throws(() => media.immich.url(url), { status: 400 });
  const g = await media.saveGallery('admin', { title: 'Photos', sourceUrl: 'https://photo.rittmann.cloud/s/photos' });
  const page = await media.page('sam', g.id);
  assert.deepEqual(page.assets.map(a => a.id), ['a', 'b', 'c']); assert.equal(page.assets[1].type, 'VIDEO');
  assert.equal(JSON.stringify(page).includes('private-share-key'), false); assert.equal(page.assets[0].canDownload, true);
  assert.equal(fetches.filter(p => p === '/api/shared-links/me').length, 1);
  assert.equal((await media.galleryImage('sam', g.id, 'a', true, true)).bytes.toString(), 'original-image-bytes');
  await assert.rejects(media.galleryImage('sam', g.id, 'unrelated'), { status: 404 });
});
test('Immich download restriction is enforced at the original endpoint', async t => {
  const { media } = await setup(t); media.immich = fakeSource({ allowDownload: false });
  const g = await media.saveGallery('admin', { title: 'Photos', sourceUrl: 'https://photo.rittmann.cloud/s/photos' });
  assert.equal((await media.page('sam', g.id)).assets[0].canDownload, false);
  await assert.rejects(media.galleryImage('sam', g.id, 'a', false, true), { status: 403 });
  assert.equal((await media.galleryImage('sam', g.id, 'a')).mime, 'image/jpeg');
});
test('media HTTP routes are authenticated, binary, private and revoke immediately', async t => {
  const { app, media, content } = await setup(t);
  const g = await media.saveGallery('admin', { title: 'Local' }); const image = await media.upload('admin', { galleryId: g.id, content });
  const server = createHttpServer({ theater: app, media, verifyToken: async uid => ({ uid }) });
  await new Promise(r => server.listen(0, '127.0.0.1', r)); t.after(() => new Promise(r => server.close(r)));
  const base = `http://127.0.0.1:${server.address().port}/api/mobile/v1`, path = `${base}/galleries/${g.id}/assets/local-${image.id}/original/`;
  assert.equal((await fetch(path)).status, 401);
  assert.equal((await fetch(path, { headers: { Authorization: 'Bearer pending' } })).status, 403);
  let r = await fetch(path, { headers: { Authorization: 'Bearer sam' } });
  assert.equal(r.status, 200); assert.equal(r.headers.get('content-type'), 'image/webp'); assert.match(r.headers.get('cache-control'), /no-store/); assert.match(r.headers.get('content-disposition'), /attachment/);
  assert.equal((await fetch(`${base}/galleries/${g.id}/?offset=0&limit=1`, { headers: { Authorization: 'Bearer sam' } }).then(r => r.json())).assets.length, 1);
  app.action('admin', { action: 'account.status', uid: 'sam', status: 'suspended', version: 2 }, 'suspend');
  r = await fetch(path, { headers: { Authorization: 'Bearer sam' } }); assert.equal(r.status, 403);
});

test('withdrawing an album blocks member metadata and images while admins can restore it', async t => {
  const { media, content } = await setup(t);
  const g = await media.saveGallery('admin', { title: 'Withdrawable' });
  const image = await media.upload('admin', { galleryId: g.id, content });
  assert.throws(() => media.publication('sam', g.id, false, 1), { status: 403 });
  media.publication('admin', g.id, false, 1);
  assert.equal((await media.list('sam')).galleries.length, 0);
  assert.equal((await media.list('admin')).galleries.length, 1);
  await assert.rejects(media.page('sam', g.id), { status: 404 });
  await assert.rejects(media.image('sam', image.id), { status: 404 });
  media.publication('admin', g.id, true, 2);
  assert.equal((await media.page('sam', g.id)).total, 1);
});
