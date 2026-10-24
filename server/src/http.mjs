import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { readFile, stat } from 'node:fs/promises';
import { resolve, extname, sep } from 'node:path';
import { AppError } from './theater.mjs';
import { clientAddress } from './bot-check.mjs';
import { linkWebsiteProfile, websiteProfilesView } from './website-team.mjs';
import { adminTicketView, closeOwnFeedback, markFeedbackRead, ownFeedback, ownTicketView, replyAsAdmin, replyAsMember } from './feedback-tickets.mjs';
import { CalendarFeedLimiter, calendarFeed, calendarFeedLink, resetCalendarFeed } from './calendar-feed.mjs';
import { PerfTelemetry, perfTelemetry } from './perf-telemetry.mjs';

// Content-addressed web files from tool/version-web.mjs never change under their name.
// Entry points (index.html, workers, manifests) and unhashed files must stay revalidated.
const hashedWebFile = /^\/(?:main\.[a-f0-9]{16}\.dart\.(?:js|mjs|wasm)|(?:flutter_bootstrap\.[a-f0-9]{16}|pwa\.[a-f0-9]{16})\.js|(?:icons\/)?[\w-]+\.[a-f0-9]{16}\.png|web-(?:renderer|assets)\/[a-f0-9]{16}\/.+)$/;

// `botCheck` (see bot-check.mjs) answers the public knowledge question before sign-in and
// evaluates its proof and the form's bot trap (`botTrap`) when an account is created;
// `clientIpHeader` names the proxy header with the client address for its attempt limit
// (e.g. `cf-connecting-ip`). `appOrigin` is the public address of the app, used for the
// personal calendar feed links (see calendar-feed.mjs).
export function createHttpServer({ theater: defaultTheater, verifyToken, deleteIdentity = null, scriptService: defaultScriptService, focusBridge: defaultFocusBridge = null, media: defaultMedia = null, review = null, botCheck = null, clientIpHeader = '', allowedOrigins = [], authProviders = ['password', 'google.com'], webDir = null, appOrigin = null, calendarLimiter = new CalendarFeedLimiter(), perf = null }) {
  const origins = new Set(allowedOrigins);
  const telemetry = perf ?? new PerfTelemetry(defaultTheater.store);
  const json = (res, status, value) => { res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(value)); };
  const readBody = async (req, route) => {
    let body = {}, length = 0; const chunks = [];
    for await (const chunk of req) { length += chunk.length; if (length > (route === '/media' ? 12 * 1024 * 1024 : route === '/telemetry/perf' ? perfTelemetry.maxBytes : 2 * 1024 * 1024)) throw new AppError(413, 'Die Anfrage ist zu groß.'); chunks.push(chunk); }
    if (length) { try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); } catch { throw new AppError(400, 'Ungültiges JSON.'); } }
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new AppError(400, 'Ungültige Anfrage.');
    return body;
  };
  return createServer(async (req, res) => {
    let theater = defaultTheater, scriptService = defaultScriptService, focusBridge = defaultFocusBridge, media = defaultMedia;
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'same-origin');
    const origin = req.headers.origin;
    if (origin && origins.has(origin)) { res.setHeader('Access-Control-Allow-Origin', origin); res.setHeader('Vary', 'Origin'); res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type, Idempotency-Key'); res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS'); }
    try {
      const requestUrl = new URL(req.url, 'http://localhost');
      const path = decodeURIComponent(requestUrl.pathname).replace(/\/+$/, '') || '/';
      if (path === '/api/healthz') return json(res, 200, { ok: true, service: 'theater-app', firebase: true, release: process.env.RELEASE_SHA ?? 'development' });
      // Public: calendar apps send no sign-in; the secret token in the path is the only proof.
      // Unknown tokens and accounts without access look the same (404).
      const calendar = path.match(/^\/api\/calendar\/([^/]+)\.ics$/);
      if (calendar && ['GET', 'HEAD'].includes(req.method)) {
        const feed = calendarFeed(defaultTheater, calendar[1], { appOrigin }) ?? (review ? calendarFeed(review.theater, calendar[1], { appOrigin }) : null);
        const wait = feed ? calendarLimiter.token(calendar[1]) : calendarLimiter.miss(clientAddress(req, clientIpHeader));
        if (wait) throw Object.assign(new AppError(429, 'Zu viele Abrufe. Bitte später erneut versuchen.', 'rate_limited'), { retryAfter: wait });
        if (!feed) throw new AppError(404, 'Nicht gefunden.');
        const headers = { ETag: feed.etag, 'Cache-Control': 'private, max-age=300', 'X-Robots-Tag': 'noindex, nofollow' };
        if (String(req.headers['if-none-match'] ?? '').split(',').map(x => x.trim().replace(/^W\//, '')).includes(feed.etag)) { res.writeHead(304, headers); res.end(); return; }
        const body = Buffer.from(feed.body, 'utf8');
        res.writeHead(200, { ...headers, 'Content-Type': 'text/calendar; charset=utf-8', 'Content-Length': body.length, 'Content-Disposition': 'inline; filename="kolpingtheater.ics"' });
        res.end(req.method === 'HEAD' ? undefined : body); return;
      }
      if (req.method === 'OPTIONS') { if (origin && !origins.has(origin)) throw new AppError(403, 'Diese App-Adresse ist nicht freigegeben.'); res.writeHead(204); res.end(); return; }
      if (!path.startsWith('/api/mobile/v1')) {
        if (webDir && ['GET', 'HEAD'].includes(req.method)) {
          const root = resolve(webDir), requested = resolve(root, `.${path}`);
          if (!requested.startsWith(root + sep) && requested !== root) throw new AppError(404, 'Nicht gefunden.');
          let file = requested;
          const fallback = () => {
            if (extname(path) || /^\/(?:api|assets|icons|canvaskit|web-assets|web-renderer)(?:\/|$)/.test(path)) throw new AppError(404, 'Nicht gefunden.');
            return resolve(root, 'index.html');
          };
          try { if (!(await stat(file)).isFile()) file = fallback(); } catch (error) { if (error instanceof AppError) throw error; file = fallback(); }
          const types = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json', '.wasm': 'application/wasm', '.png': 'image/png', '.webp': 'image/webp', '.mp3': 'audio/mpeg', '.svg': 'image/svg+xml', '.ttf': 'font/ttf', '.woff2': 'font/woff2' };
          const content = await readFile(file);
          const manifest = /\/manifest(?:\.[a-f0-9]{16})?\.json$/.test(file);
          if (path === '/theater-service-worker.js') res.setHeader('Service-Worker-Allowed', '/');
          const cache = file === requested && hashedWebFile.test(path) ? 'public, max-age=31536000, immutable' : ['.html', '.js', '.mjs', '.json'].includes(extname(file)) ? 'private, no-store, max-age=0, must-revalidate' : 'public, max-age=3600';
          res.writeHead(200, { 'Content-Type': manifest ? 'application/manifest+json; charset=utf-8' : types[extname(file)] ?? 'application/octet-stream', 'Content-Length': content.length, 'Cache-Control': cache }); res.end(req.method === 'HEAD' ? undefined : content); return;
        }
        throw new AppError(404, 'Nicht gefunden.');
      }
      if (origin && !origins.has(origin)) throw new AppError(403, 'Diese App-Adresse ist nicht freigegeben.');
      const route = path.slice('/api/mobile/v1'.length);
      if (route === '/config' && req.method === 'GET') return json(res, 200, { authProviders, pushConfigured: theater.pushEnabled, emailConfigured: theater.emailEnabled, scriptSourceConfigured: scriptService?.configured === true });
      // Public: asked before anyone signs in. The answers never leave the server.
      if (route === '/bot-check' && botCheck && req.method === 'GET') return json(res, 200, botCheck.question());
      if (route === '/bot-check' && botCheck && req.method === 'POST') { const { answer, botTrap } = await readBody(req, route); return json(res, 200, botCheck.attempt(clientAddress(req, clientIpHeader), answer, botTrap)); }
      const token = req.headers.authorization?.match(/^Bearer (.+)$/)?.[1];
      if (!token || token.length > 12000) throw new AppError(401, 'Bitte zuerst anmelden.');
      let identity;
      try { identity = await verifyToken(token); } catch { throw new AppError(401, 'Die Anmeldung ist abgelaufen oder wurde gesperrt.'); }
      if (!identity?.uid) throw new AppError(401, 'Ungültige Anmeldung.');
      if (review && identity.uid === review.uid) {
        ({ theater, scriptService, focusBridge, media } = review);
      }
      // Performance telemetry (perf-telemetry.mjs) never shows the app an error: invalid, too large,
      // rate-limited reports and those of the review account or unapproved accounts are dropped.
      if (route === '/telemetry/perf' && req.method === 'POST') {
        try {
          if (theater === defaultTheater) { theater.account(identity.uid); telemetry.record(identity.uid, await readBody(req, route)); }
        } catch (e) { if (!(e instanceof AppError)) console.error('Telemetry:', e.code ?? e.name, e.message); }
        res.writeHead(204, { 'Cache-Control': 'no-store' }); res.end(); return;
      }
      if (!['/auth/session', '/auth/logout', '/devices'].includes(route)) theater.account(identity.uid);
      const body = ['POST', 'PUT', 'DELETE'].includes(req.method) ? await readBody(req, route) : {};
      if (route === '/auth/session' && ['GET', 'POST'].includes(req.method)) return json(res, 200, { user: theater.session(identity, req.method === 'POST' ? body.registrationName : undefined, botCheck?.evaluate(body.botCheckProof, body.botTrap)) });
      if (route === '/auth/logout' && req.method === 'POST') {
        for (const d of theater.store.all('devices').filter(d => d.uid === identity.uid && d.token === body.deviceToken)) theater.store.delete('devices', d.id);
        return json(res, 200, { ok: true });
      }
      // Waiting accounts may already register a device; pushes start with the approval.
      if (route === '/devices' && ['POST', 'DELETE'].includes(req.method)) return json(res, 200, theater.device(identity.uid, body.token, body.platform, req.method === 'DELETE', body.notificationActions));
      theater.account(identity.uid);
      if (route === '/profile' && req.method === 'PUT') {
        theater.action(identity.uid, { ...body, action: 'profile.save' }, req.headers['idempotency-key'] || randomUUID());
        return json(res, 200, { user: theater.profile(theater.account(identity.uid)) });
      }
      if (media) {
        if (route === '/galleries' && req.method === 'GET') return json(res, 200, await media.list(identity.uid));
        if (route === '/galleries' && req.method === 'POST') return json(res, 200, { gallery: await media.saveGallery(identity.uid, body) });
        if (route === '/media' && req.method === 'POST') return json(res, 201, await media.upload(identity.uid, body));
        const galleryPage = route.match(/^\/galleries\/([^/]+)$/);
        if (galleryPage && req.method === 'GET') return json(res, 200, await media.page(identity.uid, galleryPage[1], { offset: requestUrl.searchParams.get('offset'), limit: requestUrl.searchParams.get('limit'), includeHidden: requestUrl.searchParams.get('includeHidden') === 'true' }));
        const publication = route.match(/^\/galleries\/([^/]+)\/visibility$/);
        if (publication && req.method === 'PUT') return json(res, 200, media.publication(identity.uid, publication[1], body.published, body.version));
        const visible = route.match(/^\/media\/([^/]+)\/visibility$/);
        if (visible && req.method === 'PUT') return json(res, 200, media.visibility(identity.uid, visible[1], body.hidden));
        const asset = route.match(/^\/galleries\/([^/]+)\/assets\/([^/]+)(\/original)?$/);
        const direct = route.match(/^\/media\/([^/]+)$/);
        if ((asset || direct) && req.method === 'GET') {
          const result = asset ? await media.galleryImage(identity.uid, asset[1], asset[2], requestUrl.searchParams.get('size') === 'preview', !!asset[3]) : await media.image(identity.uid, direct[1]);
          theater.account(identity.uid);
          const headers = { 'Content-Type': result.mime, 'Content-Length': result.bytes.length, 'Cache-Control': 'private, no-store, max-age=0', Vary: 'Authorization, Origin' };
          if (asset?.[3]) headers['Content-Disposition'] = `attachment; filename="theater-${asset[2].replace(/[^a-zA-Z0-9-]/g, '')}.${({ 'image/jpeg':'jpg', 'image/png':'png', 'image/webp':'webp', 'image/avif':'avif' })[result.mime] || 'img'}"`;
          res.writeHead(200, headers); res.end(result.bytes); return;
        }
      }
      if (route === '/snapshot' && req.method === 'GET') return json(res, 200, theater.snapshot(identity.uid));
      if (route === '/actions' && req.method === 'POST') return json(res, 200, theater.action(identity.uid, body, req.headers['idempotency-key']));
      if (route === '/calendar-feed' && req.method === 'GET') return json(res, 200, calendarFeedLink(theater, identity.uid, appOrigin));
      if (route === '/calendar-feed/reset' && req.method === 'POST') return json(res, 200, resetCalendarFeed(theater, identity.uid, appOrigin));
      if (route === '/participation' && req.method === 'GET') return json(res, 200, theater.participation(identity.uid));
      if (route === '/ensemble/website-profiles' && req.method === 'GET') return json(res, 200, websiteProfilesView(theater, identity.uid));
      const websiteProfile = route.match(/^\/ensemble\/website-profiles\/([^/]+)$/);
      if (websiteProfile && req.method === 'PUT') return json(res, 200, linkWebsiteProfile(theater, identity.uid, websiteProfile[1], body));
      if (route === '/feedback' && req.method === 'POST') return json(res, 200, theater.submitFeedback(identity.uid, body));
      if (route === '/admin/feedback' && req.method === 'GET') return json(res, 200, theater.feedbackList(identity.uid));
      const feedback = route.match(/^\/admin\/feedback\/([^/]+)$/);
      if (feedback && req.method === 'PUT') return json(res, 200, theater.feedbackStatus(identity.uid, feedback[1], body));
      if (feedback && req.method === 'GET') return json(res, 200, adminTicketView(theater, identity.uid, feedback[1]));
      const answer = route.match(/^\/admin\/feedback\/([^/]+)\/messages$/);
      if (answer && req.method === 'POST') return json(res, 200, replyAsAdmin(theater, identity.uid, answer[1], body));
      // A member's own feedback tickets.
      if (route === '/feedback' && req.method === 'GET') return json(res, 200, ownFeedback(theater, identity.uid));
      const ownTicket = route.match(/^\/feedback\/([^/]+)(\/messages|\/read)?$/);
      if (ownTicket && !ownTicket[2] && req.method === 'GET') return json(res, 200, ownTicketView(theater, identity.uid, ownTicket[1]));
      if (ownTicket && !ownTicket[2] && req.method === 'PUT') return json(res, 200, closeOwnFeedback(theater, identity.uid, ownTicket[1], body));
      if (ownTicket?.[2] === '/messages' && req.method === 'POST') return json(res, 200, replyAsMember(theater, identity.uid, ownTicket[1], body));
      if (ownTicket?.[2] === '/read' && req.method === 'PUT') return json(res, 200, markFeedbackRead(theater, identity.uid, ownTicket[1]));
      if (route === '/games/runner/leaderboard' && req.method === 'GET') return json(res, 200, theater.runnerLeaderboard(identity.uid));
      if (route === '/games/runner/rounds' && req.method === 'POST') return json(res, 200, theater.runnerStart(identity.uid));
      if (route === '/games/runner/scores' && req.method === 'POST') return json(res, 200, theater.runnerScore(identity.uid, body));
      if (route === '/games/runner/wardrobe' && req.method === 'GET') return json(res, 200, theater.runnerWardrobe(identity.uid, { roles: requestUrl.searchParams.get('roles') === '1' }));
      if (route === '/games/runner/crates' && req.method === 'POST') return json(res, 200, theater.runnerOpenCrate(identity.uid, req.headers['idempotency-key'], body));
      if (route === '/games/runner/trade' && req.method === 'POST') return json(res, 200, theater.runnerTrade(identity.uid, req.headers['idempotency-key'], body));
      if (route === '/games/runner/buy' && req.method === 'POST') return json(res, 200, theater.runnerBuy(identity.uid, req.headers['idempotency-key'], body));
      if (route === '/games/runner/missions' && req.method === 'GET') return json(res, 200, theater.runnerMissions(identity.uid));
      if (route === '/games/runner/missions/reroll' && req.method === 'POST') return json(res, 200, theater.runnerMissionReroll(identity.uid, req.headers['idempotency-key'], body));
      if (route === '/games/runner/ensemble/seen' && req.method === 'PUT') return json(res, 200, theater.runnerEnsembleSeen(identity.uid, body));
      if (route === '/games/runner/outfit' && req.method === 'PUT') return json(res, 200, theater.runnerOutfit(identity.uid, body));
      const skin = route.match(/^\/games\/runner\/skins\/([^/]+)$/);
      if (skin && req.method === 'GET') {
        const file = theater.runnerSkin(identity.uid, skin[1]);
        // The catalog links each picture with its content hash (`?v=`), so a matching link never changes.
        const cache = requestUrl.searchParams.get('v') === file.hash ? 'private, max-age=31536000, immutable' : 'private, no-cache';
        res.writeHead(200, { 'Content-Type': file.mime, 'Content-Length': file.bytes.length, 'Cache-Control': cache, Vary: 'Authorization, Origin' }); res.end(file.bytes); return;
      }
      if (route === '/admin/accounts' && req.method === 'GET') return json(res, 200, theater.adminData(identity.uid));
      if (route === '/admin/email' && req.method === 'GET') { theater.account(identity.uid, true); return json(res, 200, { configured: theater.emailEnabled, jobs: theater.store.all('emailJobs').slice(-50).map(({ acceptedRecipientIds, failedRecipientIds, ...job }) => job) }); }
      if (route === '/admin/push' && req.method === 'GET') { theater.account(identity.uid, true); return json(res, 200, { configured: theater.pushEnabled, devices: theater.store.all('devices').map(({ token, ...d }) => d), jobs: theater.store.all('pushJobs').slice(-50).map(({ acceptedDeviceIds, ...j }) => j) }); }
      if (route === '/admin/script-source' && req.method === 'GET') { theater.account(identity.uid, true); if (!scriptService?.configured) throw new AppError(409, 'Keine Skriptquelle eingerichtet.'); return json(res, 200, { productions: await scriptService.getProductions() }); }
      if (route === '/admin/import-script' && req.method === 'POST') {
        theater.account(identity.uid, true); if (!scriptService?.configured) throw new AppError(409, 'Keine Skriptquelle eingerichtet.');
        const result = await scriptService.getProductions(); const productions = Array.isArray(result) ? result : result.productions;
        const production = productions?.find(p => p.id === body.productionId); if (!production) throw new AppError(404, 'Produktion in der Quelle nicht gefunden.');
        const document = await scriptService.getScript(production.id);
        return json(res, 200, theater.importScript(identity.uid, production, document));
      }
      const account = route.match(/^\/admin\/accounts\/([^/]+)$/);
      if (account && req.method === 'DELETE') return json(res, 200, await theater.deleteAccount(identity.uid, account[1], body.version, theater === defaultTheater ? deleteIdentity : null));
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
      throw new AppError(404, 'Diese Funktion ist nicht verfügbar.');
    } catch (e) {
      const status = e.status && e.status >= 400 && e.status < 600 ? e.status : 500;
      if (status === 500) console.error('Request failed:', e.code ?? e.name, e.message);
      // Only our own errors carry a machine-readable code; Node's `e.code` (e.g. SQLITE_BUSY) never leaks.
      if (!res.headersSent && e instanceof AppError && Number.isInteger(e.retryAfter)) res.setHeader('Retry-After', String(e.retryAfter));
      if (!res.headersSent) json(res, status, status === 500 ? { error: 'Die Änderung konnte nicht verarbeitet werden. Bitte erneut versuchen.' } : { error: e.message, ...(e instanceof AppError && e.code ? { code: e.code } : {}) });
      else res.end();
    }
  });
}
