import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { resolve, extname, sep } from 'node:path';
import { AppError } from './theater.mjs';

export function createHttpServer({ theater, verifyToken, scriptService, focusBridge = null, allowedOrigins = [], authProviders = ['password', 'google.com'], webDir = null }) {
  const origins = new Set(allowedOrigins);
  const json = (res, status, value) => { res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(value)); };
  return createServer(async (req, res) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'same-origin');
    const origin = req.headers.origin;
    if (origin && origins.has(origin)) { res.setHeader('Access-Control-Allow-Origin', origin); res.setHeader('Vary', 'Origin'); res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type, Idempotency-Key'); res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS'); }
    try {
      const path = decodeURIComponent(new URL(req.url, 'http://localhost').pathname).replace(/\/+$/, '') || '/';
      if (path === '/api/healthz') return json(res, 200, { ok: true, service: 'theater-app', firebase: true, release: process.env.RELEASE_SHA ?? 'development' });
      if (req.method === 'OPTIONS') { if (origin && !origins.has(origin)) throw new AppError(403, 'Diese App-Adresse ist nicht freigegeben.'); res.writeHead(204); res.end(); return; }
      if (!path.startsWith('/api/mobile/v1')) {
        if (webDir && req.method === 'GET') {
          const root = resolve(webDir), requested = resolve(root, `.${path}`);
          if (!requested.startsWith(root + sep) && requested !== root) throw new AppError(404, 'Nicht gefunden.');
          let file = requested;
          try { if (!(await stat(file)).isFile()) file = resolve(root, 'index.html'); } catch { file = resolve(root, 'index.html'); }
          const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.json': 'application/json', '.wasm': 'application/wasm', '.png': 'image/png', '.svg': 'image/svg+xml', '.ttf': 'font/ttf', '.woff2': 'font/woff2' };
          const content = await readFile(file);
          res.writeHead(200, { 'Content-Type': types[extname(file)] ?? 'application/octet-stream', 'Cache-Control': ['.html', '.js', '.json'].includes(extname(file)) ? 'no-cache' : 'public, max-age=3600' }); res.end(content); return;
        }
        throw new AppError(404, 'Nicht gefunden.');
      }
      if (origin && !origins.has(origin)) throw new AppError(403, 'Diese App-Adresse ist nicht freigegeben.');
      const route = path.slice('/api/mobile/v1'.length);
      if (route === '/config' && req.method === 'GET') return json(res, 200, { authProviders, pushConfigured: theater.pushEnabled, scriptSourceConfigured: scriptService?.configured === true });
      const token = req.headers.authorization?.match(/^Bearer (.+)$/)?.[1];
      if (!token || token.length > 12000) throw new AppError(401, 'Bitte zuerst anmelden.');
      let identity;
      try { identity = await verifyToken(token); } catch { throw new AppError(401, 'Die Anmeldung ist abgelaufen oder wurde gesperrt.'); }
      if (!identity?.uid) throw new AppError(401, 'Ungültige Anmeldung.');
      let body = {};
      if (['POST', 'PUT', 'DELETE'].includes(req.method)) {
        let length = 0; const chunks = [];
        for await (const chunk of req) { length += chunk.length; if (length > 2 * 1024 * 1024) throw new AppError(413, 'Die Anfrage ist zu groß.'); chunks.push(chunk); }
        if (length) { try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new AppError(400, 'Ungültiges JSON.'); } }
        if (!body || typeof body !== 'object' || Array.isArray(body)) throw new AppError(400, 'Ungültige Anfrage.');
      }
      if (route === '/auth/session' && ['GET', 'POST'].includes(req.method)) return json(res, 200, { user: theater.session(identity) });
      if (route === '/auth/logout' && req.method === 'POST') {
        for (const d of theater.store.all('devices').filter(d => d.uid === identity.uid && d.token === body.deviceToken)) theater.store.delete('devices', d.id);
        return json(res, 200, { ok: true });
      }
      theater.account(identity.uid);
      if (route === '/snapshot' && req.method === 'GET') return json(res, 200, theater.snapshot(identity.uid));
      if (route === '/actions' && req.method === 'POST') return json(res, 200, theater.action(identity.uid, body, req.headers['idempotency-key']));
      if (route === '/admin/accounts' && req.method === 'GET') return json(res, 200, theater.adminData(identity.uid));
      if (route === '/admin/push' && req.method === 'GET') { theater.account(identity.uid, true); return json(res, 200, { configured: theater.pushEnabled, devices: theater.store.all('devices').map(({ token, ...d }) => d), jobs: theater.store.all('pushJobs').slice(-50).map(({ acceptedDeviceIds, ...j }) => j) }); }
      if (route === '/admin/script-source' && req.method === 'GET') { theater.account(identity.uid, true); if (!scriptService?.configured) throw new AppError(409, 'Keine Skriptquelle eingerichtet.'); return json(res, 200, { productions: await scriptService.getProductions() }); }
      if (route === '/admin/import-script' && req.method === 'POST') {
        theater.account(identity.uid, true); if (!scriptService?.configured) throw new AppError(409, 'Keine Skriptquelle eingerichtet.');
        const result = await scriptService.getProductions(); const productions = Array.isArray(result) ? result : result.productions;
        const production = productions?.find(p => p.id === body.productionId); if (!production) throw new AppError(404, 'Produktion in der Quelle nicht gefunden.');
        const document = await scriptService.getScript(production.id);
        return json(res, 200, theater.importScript(identity.uid, production, document));
      }
      const detail = route.match(/^\/admin\/events\/([^/]+)$/);
      if (detail && req.method === 'GET') return json(res, 200, theater.eventDetails(identity.uid, detail[1]));
      const script = route.match(/^\/productions\/([^/]+)\/script$/);
      if (script && req.method === 'GET') return json(res, 200, theater.script(identity.uid, script[1]));
      const comments = route.match(/^\/productions\/([^/]+)\/comments$/);
      if (comments && req.method === 'GET') { theater.script(identity.uid, comments[1]); return json(res, 200, { comments: theater.store.all('comments').filter(c => c.productionId === comments[1]) }); }
      const focus = route.match(/^\/productions\/([^/]+)\/focus$/);
      if (focus && ['GET', 'POST', 'PUT', 'DELETE'].includes(req.method)) {
        const data = req.method === 'GET' ? null : req.method === 'DELETE' ? { cueId: null, revision: theater.store.get('scripts', focus[1])?.revision } : body;
        return json(res, 200, focusBridge ? await focusBridge.focus(identity.uid, focus[1], data) : theater.focus(identity.uid, focus[1], data));
      }
      if (route === '/devices' && ['POST', 'DELETE'].includes(req.method)) return json(res, 200, theater.device(identity.uid, body.token, body.platform, req.method === 'DELETE'));
      throw new AppError(404, 'Diese Funktion ist nicht verfügbar.');
    } catch (e) {
      const status = e.status && e.status >= 400 && e.status < 600 ? e.status : 500;
      if (status === 500) console.error('Request failed:', e.code ?? e.name, e.message);
      if (!res.headersSent) json(res, status, { error: status === 500 ? 'Die Änderung konnte nicht verarbeitet werden. Bitte erneut versuchen.' : e.message });
      else res.end();
    }
  });
}
