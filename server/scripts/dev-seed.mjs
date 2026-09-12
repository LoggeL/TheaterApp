import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { readFile } from 'node:fs/promises';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';

const projectId = process.env.FIREBASE_PROJECT_ID ?? 'demo-theater-app';
if (!process.env.FIREBASE_AUTH_EMULATOR_HOST || !projectId.startsWith('demo-')) throw new Error('Beispieldaten sind ausschließlich im lokalen Firebase-Emulator erlaubt.');
const auth = getAuth(initializeApp({ projectId }));
const store = new Store(process.env.DATABASE_PATH ?? './data/local.sqlite');
const email = 'admin@theater.test', password = process.env.DEV_ADMIN_PASSWORD ?? 'TheaterProbe!2026';
const fixture = JSON.parse(await readFile(new URL('../fixtures/example-data.json', import.meta.url), 'utf8'));
if (!store.get('settings', 'exampleSeeded')) {
  store.transaction(() => {
    for (const kind of ['members', 'events', 'productions']) for (const entity of fixture.snapshot[kind]) store.put(kind, entity.id, { ...entity, version: 1 });
    for (const doc of fixture.scripts) store.put('scripts', doc.productionId, doc);
    store.put('settings', 'sampleData', { enabled: true });
    store.put('settings', 'exampleSeeded', { at: new Date().toISOString() });
  });
}
let user;
try { user = await auth.getUserByEmail(email); } catch (e) { if (e.code !== 'auth/user-not-found') throw e; user = await auth.createUser({ email, password, displayName: 'Alex Theaterleitung', emailVerified: true }); }
const theater = new Theater(store, { bootstrapEmail: email });
theater.session({ uid: user.uid, email, name: user.displayName, email_verified: true });
const a = store.account(user.uid);
if (a.status !== 'approved') {
  const adminPerson = store.accounts().find(x => x.role === 'admin')?.personId;
  if (adminPerson) { for (const old of store.accounts().filter(x => x.personId === adminPerson)) store.saveAccount({ ...old, personId: null, status: 'suspended' }); store.saveAccount({ ...a, personId: adminPerson, role: 'admin', status: 'approved', approvedBy: 'local-seed', approvedAt: new Date().toISOString() }); }
}
for (const p of store.all('productions')) {
  if (!p.casting) store.put('productions', p.id, { ...p, casting: Object.fromEntries(p.roles.map((r, i) => [r.id, i === 0 ? store.account(user.uid).personId : i === 1 ? 2 : 5])) });
}
for (const [memberEmail, name, verified] of [['sam@theater.test', 'Sam Weber', true], ['neu@theater.test', 'Neues Mitglied', false]]) {
  let member;
  try { member = await auth.getUserByEmail(memberEmail); } catch (e) { if (e.code !== 'auth/user-not-found') throw e; member = await auth.createUser({ email: memberEmail, password, displayName: name, emailVerified: verified }); }
  theater.session({ uid: member.uid, email: memberEmail, name, email_verified: verified });
}
store.close();
console.log(`Lokale Testkonten eingerichtet: ${email}, sam@theater.test, neu@theater.test. Passwort aus DEV_ADMIN_PASSWORD oder dem dokumentierten lokalen Standard. Keine produktiven Konten verändert.`);
