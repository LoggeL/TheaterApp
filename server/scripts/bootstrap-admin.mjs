import { initializeApp, applicationDefault } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { randomBytes } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { Store } from '../src/store.mjs';

const email = (process.argv[2] ?? process.env.BOOTSTRAP_ADMIN_EMAIL ?? '').trim().toLowerCase();
if (!email.includes('@') || !process.env.FIREBASE_PROJECT_ID) throw new Error('Aufruf: npm run bootstrap-admin -- email@example.org; FIREBASE_PROJECT_ID und Server-Credentials erforderlich.');
const auth = getAuth(initializeApp({ projectId: process.env.FIREBASE_PROJECT_ID, ...(process.env.FIREBASE_AUTH_EMULATOR_HOST ? {} : { credential: applicationDefault() }) }));
let user, password;
try { user = await auth.getUserByEmail(email); }
catch (e) {
  if (e.code !== 'auth/user-not-found') throw e;
  password = randomBytes(24).toString('base64url');
  user = await auth.createUser({ email, password, displayName: process.env.ADMIN_DISPLAY_NAME || email.split('@')[0], emailVerified: false });
}
const store = new Store(process.env.DATABASE_PATH ?? './data/theater.sqlite');
const previous = store.account(user.uid);
if (previous?.role === 'admin' && previous.status === 'approved') { console.log('Admin-Zuordnung bereits vorhanden.'); store.close(); process.exit(0); }
store.transaction(() => {
  const personId = previous?.personId ?? Math.max(0, ...store.all('members').map(x => x.id)) + 1;
  if (!store.get('members', personId)) store.put('members', personId, { id: personId, name: process.env.ADMIN_DISPLAY_NAME || user.displayName || email, group: 'Theaterleitung', initials: 'TL', active: true, version: 1 });
  store.saveAccount({ ...previous, uid: user.uid, personId, name: user.displayName || email, email, emailVerified: user.emailVerified, identityReady: user.emailVerified, provider: 'password', role: 'admin', status: 'approved', approvedAt: new Date().toISOString(), approvedBy: 'server-bootstrap', version: (previous?.version ?? 0) + 1 });
  store.put('settings', 'bootstrap', { uid: user.uid, at: new Date().toISOString() });
  store.audit('server-bootstrap', 'account.approve', user.uid);
});
store.close();
const privateFile = resolve(process.env.ADMIN_SETUP_FILE ?? '../.secrets/admin-setup.json');
await mkdir(dirname(privateFile), { recursive: true, mode: 0o700 });
const verificationUrl = user.emailVerified ? null : await auth.generateEmailVerificationLink(email);
await writeFile(privateFile, JSON.stringify({ email, uid: user.uid, ...(password ? { initialPassword: password } : {}), verificationUrl, note: 'Die Freigabe ist erteilt. Vor Datenzugriff E-Mail bestätigen oder mit Google derselben Adresse anmelden. Bestehende Passwörter wurden nicht geändert.' }, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
console.log(`Admin eingerichtet: ${email}. Private Startdaten: ${privateFile}. E-Mail-Bestätigung bleibt erforderlich.`);
