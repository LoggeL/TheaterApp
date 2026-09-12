import { mkdir, readFile, writeFile, unlink } from 'node:fs/promises';
import { resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import sharp from 'sharp';
import { AppError } from './theater.mjs';
import { Immich } from './immich.mjs';
sharp.cache({ memory: 16, files: 0, items: 20 });
const fail = (status, message) => { throw new AppError(status, message); };
const text = (v, max) => typeof v === 'string' ? v.trim().slice(0, max) : '';

export class MediaService {
  constructor(theater, { directory = './data/media', immich = new Immich() } = {}) {
    this.theater = theater; this.store = theater.store; this.directory = resolve(directory); this.immich = immich;
  }
  gallery(id, uid = null) { const g = this.store.get('galleries', id); if (!g || g.hidden || (uid && g.published === false && this.theater.account(uid).role !== 'admin')) fail(404, 'Galerie nicht gefunden.'); return g; }
  localAssets(galleryId, includeHidden = false) { return this.store.all('media').filter(m => m.galleryId === galleryId && (includeHidden || !m.hidden)).sort((a,b) => b.createdAt.localeCompare(a.createdAt)); }
  async saveGallery(uid, b) {
    this.theater.account(uid, true);
    const title = text(b.title, 120); if (!title) fail(400, 'Bitte einen Titel eingeben.');
    const sourceUrl = text(b.sourceUrl, 1000);
    if (sourceUrl) await this.immich.album(sourceUrl);
    if (b.productionId && !this.store.get('productions', b.productionId)) fail(400, 'Produktion nicht gefunden.');
    return this.store.transaction(() => {
      this.theater.account(uid, true); const old = b.id ? this.gallery(b.id) : null;
      if (old && old.version !== b.version) fail(409, 'Die Galerie wurde inzwischen geändert.');
      const g = { ...old, id: old?.id ?? randomUUID(), title, description: text(b.description, 2000), sourceUrl, productionId: b.productionId || null, version: (old?.version ?? 0) + 1, createdAt: old?.createdAt ?? new Date().toISOString() };
      this.store.put('galleries', g.id, g); this.store.audit(uid, 'gallery.save', g.id); return g;
    });
  }
  async list(uid) {
    this.theater.account(uid);
    const galleries = this.store.all('galleries').filter(g => !g.hidden && (g.published !== false || this.theater.account(uid).role === 'admin'));
    return { galleries: await Promise.all(galleries.map(async g => {
      let source = null, sourceError = null;
      if (g.sourceUrl) { try { source = await this.immich.album(g.sourceUrl); } catch (e) { sourceError = e.message; } }
      const local = this.localAssets(g.id), cover = local[0] ? `local-${local[0].id}` : source?.assets[0]?.id;
      return { ...g, count: local.length + (source?.assets.length ?? 0), sourceError, coverPath: cover ? `/galleries/${g.id}/assets/${cover}` : null };
    })) };
  }
  async page(uid, id, { offset = 0, limit = 60, includeHidden = false } = {}) {
    const a = this.theater.account(uid); if (includeHidden && a.role !== 'admin') fail(403, 'Admin-Zugang erforderlich.');
    const g = this.gallery(id, uid); offset = Math.max(0, Math.floor(Number(offset)) || 0); limit = Math.min(100, Math.max(1, Math.floor(Number(limit)) || 60));
    let source = null, sourceError = null;
    if (g.sourceUrl) { try { source = await this.immich.album(g.sourceUrl); } catch (e) { sourceError = e.message; } }
    const local = this.localAssets(id, includeHidden).map(m => ({ id: `local-${m.id}`, type: 'IMAGE', date: m.createdAt, ratio: m.width / m.height, caption: m.caption, hidden: m.hidden === true }));
    const all = [...local, ...(source?.assets ?? [])];
    const assets = all.slice(offset, offset + limit).map(m => ({ ...m, path: `/galleries/${id}/assets/${m.id}`, previewPath: `/galleries/${id}/assets/${m.id}?size=preview` }));
    return { gallery: g, assets: assets.map(m => ({ ...m, canDownload: m.id.startsWith('local-') || source?.allowDownload === true })), total: all.length, nextOffset: offset + assets.length < all.length ? offset + assets.length : null, sourceError };
  }
  async upload(uid, b) {
    this.theater.account(uid);
    if ((this.processing ?? 0) >= 2) fail(429, 'Es werden gerade andere Bilder verarbeitet. Bitte kurz danach erneut versuchen.');
    this.processing = (this.processing ?? 0) + 1;
    try { return await this.processUpload(uid, b); } finally { this.processing--; }
  }
  async processUpload(uid, b) {
    const a = this.theater.account(uid), profile = b.kind === 'profile';
    if (!profile) { this.theater.account(uid, true); this.gallery(b.galleryId); }
    if (typeof b.content !== 'string' || b.content.length > 12 * 1024 * 1024 || !/^[A-Za-z0-9+/]*={0,2}$/.test(b.content)) fail(400, 'Bitte ein Bild bis 8 MB auswählen.');
    const input = Buffer.from(b.content, 'base64'); if (!input.length || input.length > 8 * 1024 * 1024) fail(413, 'Bitte ein Bild bis 8 MB auswählen.');
    const recent = this.store.all('media').filter(m => m.ownerPersonId === a.personId && Date.parse(m.createdAt) > Date.now() - 86400_000);
    if (recent.length >= (a.role === 'admin' ? 500 : 30)) fail(429, 'Für heute wurden bereits viele Bilder hochgeladen. Bitte später erneut versuchen.');
    let result;
    try {
      const image = sharp(input, { limitInputPixels: 40_000_000, animated: false }); const metadata = await image.metadata();
      if (!['jpeg', 'png', 'webp', 'heif', 'avif'].includes(metadata.format)) fail(400, 'Bitte JPEG, PNG oder WebP auswählen.');
      result = await image.rotate().resize(profile ? { width: 512, height: 512, fit: 'cover' } : { width: 2048, height: 2048, fit: 'inside', withoutEnlargement: true }).webp({ quality: 85 }).toBuffer({ resolveWithObject: true });
    } catch (e) { if (e instanceof AppError) throw e; fail(400, 'Das Bild konnte nicht gelesen werden. Bitte JPEG, PNG oder WebP auswählen.'); }
    const id = randomUUID(); await mkdir(this.directory, { recursive: true }); await writeFile(resolve(this.directory, `${id}.webp`), result.data, { flag: 'wx', mode: 0o600 });
    // Recheck access after image processing; no upload may grant itself a profile link.
    try { const current = this.theater.account(uid, !profile); if (current.personId !== a.personId) fail(409, 'Die Kontoverknüpfung hat sich geändert.'); } catch (e) { await unlink(resolve(this.directory, `${id}.webp`)); throw e; }
    const m = { id, kind: profile ? 'profile' : 'gallery', ownerPersonId: a.personId, galleryId: profile ? null : b.galleryId, caption: text(b.caption, 500), width: result.info.width, height: result.info.height, createdAt: new Date().toISOString() };
    this.store.put('media', id, m); this.store.audit(uid, 'media.upload', id);
    return { id, path: `/media/${id}`, width: m.width, height: m.height };
  }
  async image(uid, id) {
    const a = this.theater.account(uid), m = this.store.get('media', id);
    if (!m || (m.hidden && a.role !== 'admin')) fail(404, 'Bild nicht gefunden.');
    if (m.kind === 'profile' && m.ownerPersonId !== a.personId && !this.store.all('members').some(p => p.avatarId === id)) fail(404, 'Bild nicht gefunden.');
    if (m.galleryId) this.gallery(m.galleryId, uid);
    return { bytes: await readFile(resolve(this.directory, `${m.id}.webp`)), mime: 'image/webp' };
  }
  async galleryImage(uid, galleryId, assetId, preview, original = false) {
    this.theater.account(uid); const g = this.gallery(galleryId, uid);
    if (assetId.startsWith('local-')) {
      const id = assetId.slice(6); if (this.store.get('media', id)?.galleryId !== galleryId) fail(404, 'Bild nicht gefunden.');
      return this.image(uid, id);
    }
    if (!g.sourceUrl) fail(404, 'Bild nicht gefunden.');
    return original ? this.immich.original(g.sourceUrl, assetId) : this.immich.image(g.sourceUrl, assetId, preview);
  }
  publication(uid, id, published, version) {
    this.theater.account(uid, true); const g = this.gallery(id);
    if (g.version !== version) fail(409, 'Die Galerie wurde inzwischen geändert. Bitte neu laden.');
    const next = { ...g, published: published === true, version: g.version + 1 };
    this.store.put('galleries', id, next); this.store.audit(uid, 'gallery.publication', id); return { gallery: next };
  }
  visibility(uid, id, hidden) {
    this.theater.account(uid, true); const m = this.store.get('media', id);
    if (!m || m.kind !== 'gallery') fail(404, 'Galeriebild nicht gefunden.');
    this.store.put('media', id, { ...m, hidden: hidden === true }); this.store.audit(uid, 'media.visibility', id); return { ok: true };
  }
}
