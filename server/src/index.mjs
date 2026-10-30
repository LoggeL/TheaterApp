import { createReviewServices } from './review.mjs';
import { dirname, resolve } from 'node:path';
import { readFileSync } from 'node:fs';
import { ScriptFocusBridge } from './script-focus.mjs';
import { initializeApp, applicationDefault } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { getMessaging } from 'firebase-admin/messaging';
import { Store } from './store.mjs';
import { MediaService } from './media.mjs';
import { Immich } from './immich.mjs';
import { Theater } from './theater.mjs';
import { createHttpServer } from './http.mjs';
import { createTokenVerifier } from './auth-cache.mjs';
import { BotCheck, loadBotCheckConfig } from './bot-check.mjs';
import { createScriptService } from './mobile-scripts.mjs';
import { deliverPush, scheduleReminders } from './push.mjs';
import { settleAttendance } from './runner-event-crates.mjs';
import { purgeExpired } from './retention.mjs';
import { emailFromEnvironment, deliverEmail } from './email.mjs';

const projectId = process.env.FIREBASE_PROJECT_ID;
if (!projectId) throw new Error('FIREBASE_PROJECT_ID fehlt. Siehe server/.env.example.');
if (process.env.FIREBASE_AUTH_EMULATOR_HOST && process.env.NODE_ENV === 'production') throw new Error('Ein Produktionsserver darf keine Emulator-Tokens akzeptieren.');
const firebase = initializeApp({ projectId, ...(process.env.FIREBASE_AUTH_EMULATOR_HOST ? {} : { credential: applicationDefault() }) });
const auth = getAuth(firebase);
const store = new Store(process.env.DATABASE_PATH ?? './data/theater.sqlite');
const pushEnabled = process.env.MOBILE_PUSH_ENABLED === 'true' && !process.env.FIREBASE_AUTH_EMULATOR_HOST;
const email = emailFromEnvironment();
// Termin-Kisten: hours after an event's end until the own commitments become its attendance, and
// minutes after the end until the reminder to record it (see runner-event-crates.mjs).
const envMs = (name, unit) => process.env[name] ? Number(process.env[name]) * unit : undefined;
const attendanceRules = Object.fromEntries(Object.entries({ autoAdoptAfterMs: envMs('ATTENDANCE_AUTO_ADOPT_HOURS', 3600000), reminderAfterMs: envMs('ATTENDANCE_REMINDER_MINUTES', 60000) }).filter(([, v]) => Number.isFinite(v) && v >= 0));
const theater = new Theater(store, { bootstrapEmail: process.env.BOOTSTRAP_ADMIN_EMAIL, pushEnabled, emailEnabled: email.configured && !process.env.FIREBASE_AUTH_EMULATOR_HOST, attendanceRules });
const focusBridge = process.env.SCRIPT_FOCUS_BRIDGE === 'true' ? new ScriptFocusBridge(theater, { url: process.env.SCRIPT_SERVICE_URL, password: process.env.SCRIPT_DIRECTOR_PASSWORD_FILE ? readFileSync(process.env.SCRIPT_DIRECTOR_PASSWORD_FILE, 'utf8').trim() : '' }) : null;
const reviewConfig = process.env.PLAY_REVIEW_CONFIG_FILE ? JSON.parse(readFileSync(process.env.PLAY_REVIEW_CONFIG_FILE, 'utf8')) : null;
const review = reviewConfig ? createReviewServices({ ...reviewConfig, pushEnabled, databasePath: resolve(dirname(process.env.DATABASE_PATH ?? './data/theater.sqlite'), 'review.sqlite'), mediaDirectory: resolve(dirname(process.env.DATABASE_PATH ?? './data/theater.sqlite'), 'review-media') }) : null;
// Revocation state cached per uid (auth-cache.mjs); the emulator always asks, so tests see every change.
const verifier = process.env.FIREBASE_AUTH_EMULATOR_HOST ? { verify: token => auth.verifyIdToken(token, true), forget() {} } : createTokenVerifier(auth);
// Forgotten before and after: a lookup running during the deletion must not keep the user alive.
const deleteIdentity = async uid => { verifier.forget(uid); try { await auth.deleteUser(uid).catch(e => { if (e.code !== 'auth/user-not-found') throw e; }); } finally { verifier.forget(uid); } };
const mediaDirectory = process.env.MEDIA_DIR ?? resolve(dirname(process.env.DATABASE_PATH ?? './data/theater.sqlite'), 'media');
const server = createHttpServer({ theater, review, focusBridge, media: new MediaService(theater, { directory: mediaDirectory, immich: new Immich({ hosts: (process.env.GALLERY_HOSTS ?? 'photo.rittmann.cloud').split(',').map(s => s.trim()) }) }), verifyToken: (token, options) => verifier.verify(token, options), deleteIdentity, botCheck: new BotCheck({ store, config: loadBotCheckConfig(process.env.BOT_CHECK_CONFIG_FILE || undefined) }), clientIpHeader: process.env.CLIENT_IP_HEADER ?? '', scriptService: createScriptService(), allowedOrigins: (process.env.ALLOWED_ORIGINS ?? 'http://localhost:8080,http://127.0.0.1:8080,http://127.0.0.1:8787,http://localhost:8787').split(',').map(x => x.trim()), authProviders: (process.env.AUTH_PROVIDERS ?? 'password,google.com').split(','), webDir: process.env.WEB_APP_DIR ?? '../build/web', appOrigin: process.env.APP_ORIGIN ?? null });
let delivering = false, purgedAt = 0;
const tick = async () => { if (delivering) return; delivering = true; try { if (Date.now() - purgedAt > 24 * 3600000) { purgedAt = Date.now(); await purgeExpired(theater, { mediaDirectory, deleteIdentity }).then(counts => console.log('Retention:', JSON.stringify(counts)), e => console.error('Retention:', e.code ?? e.message)); } scheduleReminders(theater); settleAttendance(theater); await deliverPush(theater, pushEnabled ? getMessaging(firebase) : null); await deliverEmail(theater, email, process.env.APP_ORIGIN); if (review) { scheduleReminders(review.theater); await deliverPush(review.theater, pushEnabled ? getMessaging(firebase) : null); } } finally { delivering = false; } };
const interval = setInterval(() => tick().catch(e => console.error('Push worker:', e.code ?? e.message)), 15000);
const host = process.env.HOST ?? '127.0.0.1', port = Number(process.env.PORT ?? 8787);
server.listen(port, host, () => console.log(`Theater-App: http://${host}:${port}; Firebase ${projectId}; push ${pushEnabled ? 'enabled' : 'disabled'}`));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { clearInterval(interval); focusBridge?.close(); server.close(() => { review?.close(); store.close(); process.exit(0); }); });
