import { AppError } from './theater.mjs';
const fail = (status, message) => { throw new AppError(status, message); };

/** Server-only adapter. Shared keys never leave this module or enter client metadata. */
export class Immich {
  constructor({ hosts = ['photo.rittmann.cloud'], fetcher = fetch, clock = Date.now } = {}) {
    this.hosts = new Set(hosts); this.fetcher = fetcher; this.clock = clock; this.cache = new Map();
  }
  url(value) {
    let u; try { u = new URL(value); } catch { fail(400, 'Bitte eine gültige Immich-Freigabe eintragen.'); }
    if (u.protocol !== 'https:' || u.username || u.password || u.port || !this.hosts.has(u.hostname) || !/^\/(s|share)\/[^/]+\/?$/.test(u.pathname) || u.search || u.hash) fail(400, 'Diese Fotoquelle ist nicht freigegeben.');
    return u;
  }
  async request(url, { json = true, maxBytes = 8 * 1024 * 1024 } = {}) {
    let r;
    try { r = await this.fetcher(url, { redirect: 'error', signal: AbortSignal.timeout(20000), headers: { Accept: json ? 'application/json' : '*/*' } }); }
    catch { fail(502, 'Die Fotogalerie ist gerade nicht erreichbar.'); }
    if (!r.ok) fail(r.status === 401 || r.status === 403 || r.status === 404 ? 409 : 502, 'Die Fotofreigabe ist nicht verfügbar oder benötigt ein Passwort.');
    if (Number(r.headers.get('content-length')) > maxBytes) fail(502, 'Die Fotoquelle liefert zu große Daten.');
    const chunks = []; let size = 0;
    for await (const chunk of r.body) { size += chunk.length; if (size > maxBytes) fail(502, 'Die Fotoquelle liefert zu große Daten.'); chunks.push(chunk); }
    const bytes = Buffer.concat(chunks);
    if (!json) return { bytes, mime: r.headers.get('content-type')?.split(';')[0] };
    try { return JSON.parse(bytes.toString()); } catch { fail(502, 'Die Fotoquelle liefert keine gültigen Albumdaten.'); }
  }
  async album(sourceUrl) {
    const u = this.url(sourceUrl), previous = this.cache.get(sourceUrl);
    if (previous && previous.until > this.clock()) return previous.promise;
    const promise = this.load(u);
    this.cache.set(sourceUrl, { until: this.clock() + 5 * 60_000, promise });
    if (this.cache.size > 50) this.cache.delete(this.cache.keys().next().value);
    try { return await promise; } catch (e) { this.cache.delete(sourceUrl); throw e; }
  }
  async load(u) {
    let key;
    if (u.pathname.startsWith('/share/')) key = decodeURIComponent(u.pathname.split('/')[2]);
    else {
      const { bytes } = await this.request(u.href, { json: false, maxBytes: 2 * 1024 * 1024 });
      const tag = bytes.toString().match(/<meta\s+property=["']og:image["']\s+content=["']([^"']+)["']/i)?.[1];
      let image; try { image = new URL(tag?.replaceAll('&amp;', '&'), u); } catch { fail(409, 'Die Freigabe enthält kein verfügbares Album.'); }
      if (image.origin !== u.origin) fail(409, 'Die Freigabe verweist auf eine andere Fotoquelle.');
      key = image.searchParams.get('key');
    }
    if (!key || key.length > 300) fail(409, 'Der Freigabeschlüssel fehlt.');
    const api = (path, query = {}) => `${u.origin}/api${path}?${new URLSearchParams({ key, ...query })}`;
    const share = await this.request(api('/shared-links/me'));
    if (share.type !== 'ALBUM' || !share.album?.id) fail(400, 'Bitte ein ganzes Immich-Album freigeben.');
    const buckets = await this.request(api('/timeline/buckets', { albumId: share.album.id, size: 'MONTH' }));
    if (!Array.isArray(buckets) || buckets.length > 500) fail(502, 'Die Albumübersicht ist ungültig.');
    const assets = [];
    // Bounded batches avoid a burst of requests for albums spanning many years.
    for (let start = 0; start < buckets.length; start += 4) {
      const pages = await Promise.all(buckets.slice(start, start + 4).map(b => this.request(api('/timeline/bucket', { albumId: share.album.id, size: 'MONTH', timeBucket: b.timeBucket }))));
      for (const page of pages) {
        const rows = Array.isArray(page) ? page : (page.id ?? []).map((id, i) => ({ id, isTrashed: page.isTrashed?.[i], type: page.isImage?.[i] ? 'IMAGE' : 'VIDEO', fileCreatedAt: page.fileCreatedAt?.[i], ratio: page.ratio?.[i], thumbhash: page.thumbhash?.[i] }));
        for (const r of rows) if (/^[\w-]{1,80}$/.test(r.id) && !r.isTrashed) assets.push({ id: r.id, type: r.type ?? 'IMAGE', date: r.fileCreatedAt ?? '', ratio: Number(r.ratio) || 1.5, thumbhash: r.thumbhash ?? null });
        if (assets.length > 100_000) fail(502, 'Dieses Album ist zu groß.');
      }
    }
    const unique = [...new Map(assets.map(a => [a.id, a])).values()];
    unique.sort((a, b) => b.date.localeCompare(a.date) || a.id.localeCompare(b.id));
    return { title: share.album.albumName, description: share.album.description ?? '', allowDownload: share.allowDownload === true, assets: unique, ids: new Set(unique.map(a => a.id)), api };
  }
  async image(sourceUrl, assetId, preview = false) {
    const album = await this.album(sourceUrl);
    if (!album.ids.has(assetId)) fail(404, 'Dieses Bild gehört nicht zum Album.');
    const result = await this.request(album.api(`/assets/${encodeURIComponent(assetId)}/thumbnail`, { size: preview ? 'preview' : 'thumbnail' }), { json: false, maxBytes: 12 * 1024 * 1024 });
    if (!['image/jpeg', 'image/png', 'image/webp', 'image/avif'].includes(result.mime)) fail(502, 'Die Fotoquelle liefert kein unterstütztes Bild.');
    return result;
  }
  async original(sourceUrl, assetId) {
    const album = await this.album(sourceUrl);
    if (!album.allowDownload) fail(403, 'Downloads sind für dieses Album nicht freigegeben.');
    if (!album.ids.has(assetId)) fail(404, 'Dieses Bild gehört nicht zum Album.');
    const result = await this.request(album.api(`/assets/${encodeURIComponent(assetId)}/original`), { json: false, maxBytes: 80 * 1024 * 1024 });
    if (!result.mime?.startsWith('image/')) fail(400, 'Videos können im Originalalbum heruntergeladen werden.');
    return result;
  }
}
