import { readFileSync } from 'node:fs';
import { Store } from './store.mjs';
import { AppError, Theater } from './theater.mjs';
import { MediaService } from './media.mjs';
import { Immich } from './immich.mjs';

// The store's reviewer is an admin of the sample data, but the wardrobe is the real one: the admins'
// Skin-Viewer would show every unreleased and secret figure. So it is neither announced nor served.
class ReviewTheater extends Theater {
  snapshot(uid) {
    const data = super.snapshot(uid);
    return { ...data, capabilities: { ...data.capabilities, features: data.capabilities.features.filter(f => f !== 'runnerAdminCatalog') } };
  }
  runnerAdminCatalog() { throw new AppError(403, 'Hierfür ist ein Admin-Zugang erforderlich.'); }
  runnerAdminSkin() { throw new AppError(403, 'Hierfür ist ein Admin-Zugang erforderlich.'); }
}

// The reviewer uses the normal authenticated API with a separate database and
// media directory. Only an exact, server-configured Firebase UID selects it.
export function createReviewServices({ uid, email, databasePath, mediaDirectory, pushEnabled = false }) {
  if (!uid || !email || !databasePath || !mediaDirectory) throw new Error('Incomplete review configuration');
  const fixture = JSON.parse(readFileSync(new URL('./review-data.json', import.meta.url), 'utf8'));
  const store = new Store(databasePath);
  const theater = new ReviewTheater(store, { pushEnabled });
  if (!store.get('settings', 'reviewSeeded')) store.transaction(() => {
    for (const kind of ['members', 'events', 'productions']) {
      for (const item of fixture.snapshot[kind]) store.put(kind, item.id, { ...item, version: 1 });
    }
    for (const script of fixture.scripts) store.put('scripts', script.productionId, script);
    const personId = theater.nextPersonId();
    store.put('members', personId, { id: personId, name: 'Alex Testleitung', initials: 'AT', active: true, roleIds: ['role-2'], version: 1 });
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
