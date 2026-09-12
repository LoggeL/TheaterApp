import { readFile, writeFile } from 'node:fs/promises';
const file = process.argv[2];
if (!file) throw new Error('Aufruf: node tool/configure.mjs config/<build>.json');
const c = JSON.parse(await readFile(file, 'utf8'));
for (const key of ['API_BASE_URL', 'FIREBASE_PROJECT_ID', 'FIREBASE_API_KEY', 'FIREBASE_APP_ID', 'FIREBASE_MESSAGING_SENDER_ID']) {
  if (!c[key] || /REPLACE|YOUR_|<|>/.test(c[key])) throw new Error(`${key} fehlt oder enthält einen Platzhalter.`);
}
const emulator = String(c.USE_FIREBASE_EMULATORS) === 'true';
if (!emulator && !c.API_BASE_URL.startsWith('https://')) throw new Error('Reale Anmeldung benötigt eine HTTPS-API.');
if (String(c.PUSH_ENABLED) === 'true' && !c.FIREBASE_VAPID_KEY) throw new Error('FIREBASE_VAPID_KEY fehlt für Web-Push.');
const firebase = { apiKey: c.FIREBASE_API_KEY, appId: c.FIREBASE_WEB_APP_ID || c.FIREBASE_APP_ID, projectId: c.FIREBASE_PROJECT_ID, messagingSenderId: c.FIREBASE_MESSAGING_SENDER_ID, authDomain: c.FIREBASE_AUTH_DOMAIN };
await writeFile(new URL('../web/firebase-web-config.js', import.meta.url), `// Public Firebase client identifiers. No server credentials.\nself.theaterFirebaseConfig = ${emulator ? 'null' : JSON.stringify(firebase, null, 2)};\n`);
console.log(`Konfiguration geprüft: ${c.FIREBASE_PROJECT_ID} (${emulator ? 'lokaler Emulator' : 'Firebase'})`);
