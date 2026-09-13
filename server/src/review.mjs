import { readFileSync } from 'node:fs';
import { Store } from './store.mjs';
import { Theater } from './theater.mjs';
import { MediaService } from './media.mjs';
import { Immich } from './immich.mjs';

// The reviewer uses the normal authenticated API with a separate database and
// media directory. Only an exact, server-configured Firebase UID selects it.
export function createReviewServices({ uid, email, databasePath, mediaDirectory, pushEnabled = false }) {
  if (!uid || !email || !databasePath || !mediaDirectory) throw new Error('Incomplete review configuration');
  const fixture = JSON.parse(readFileSync(new URL('./review-data.json', import.meta.url), 'utf8'));
  const store = new Store(databasePath);
  const theater = new Theater(store, { pushEnabled });
  if (!store.get('settings', 'reviewSeeded')) store.transaction(() => {
    for (const kind of ['members', 'events', 'productions']) {
      for (const item of fixture.snapshot[kind]) store.put(kind, item.id, { ...item, version: 1 });
    }
    for (const script of fixture.scripts) store.put('scripts', script.productionId, script);
    const personId = theater.nextPersonId();
    store.put('members', personId, { id: personId, name: 'Alex Testleitung', initials: 'AT', group: 'Testbereich · Beispieldaten', active: true, roleIds: ['role-2'], version: 1 });
    store.saveAccount({ uid, email, name: 'Alex Testleitung', personId, status: 'approved', role: 'admin', identityReady: true, emailVerified: true, provider: 'password', version: 1 });
    for (const p of store.all('productions')) store.put('productions', p.id, { ...p, casting: Object.fromEntries(p.roles.map(r => [r.id, personId])), directorMemberIds: [personId] });
    store.put('settings', 'sampleData', { enabled: true });
    store.put('settings', 'bootstrap', { uid });
    store.put('settings', 'reviewSeeded', { uid, at: new Date().toISOString() });
  });
  if (store.get('settings', 'reviewSeeded').uid !== uid) { store.close(); throw new Error('Review UID changed: explicit migration required'); }
  return {
    uid, theater, focusBridge: null,
    media: new MediaService(theater, { directory: mediaDirectory, immich: new Immich({ hosts: [] }) }),
    scriptService: {
      configured: true,
      getProductions: async () => structuredClone(fixture.snapshot.productions),
      getScript: async id => structuredClone(fixture.scripts.find(s => s.productionId === id)),
    },
    close: () => store.close(),
  };
}
