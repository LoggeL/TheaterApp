import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { Theater, runnerEntryRounds } from '../src/theater.mjs';

function setup(t) {
  const store = new Store(); t.after(() => store.close());
  const clock = { now: new Date('2026-11-08T10:00:00Z') };
  const app = new Theater(store, { bootstrapEmail: 'admin@example.invalid', clock: () => clock.now });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  let sequence = 0;
  const action = body => app.action('admin', body, `entry-${++sequence}`);
  const person = (uid, name) => {
    const personId = action({ action: 'member.save', name }).id;
    app.session({ uid, name, email: `${uid}@example.invalid`, email_verified: true });
    action({ action: 'account.approve', uid, personId, version: 1, role: 'member' });
    return personId;
  };
  const sam = person('sam', 'Sam Beispiel');
  const play = uid => { const { roundId } = app.runnerStart(uid); clock.now = new Date(+clock.now + 60000); app.runnerScore(uid, { roundId, score: 100 }); };
  return { store, app, sam, play };
}

test('the navigation entry needs strictly more than ten runs', t => {
  const { store, app, sam } = setup(t);
  assert.equal(runnerEntryRounds, 10);
  assert.equal(app.snapshot('sam').user.runnerEntry, false, 'nobody who never played');
  store.put('runnerScores', sam, { personId: sam, best: 10, bestAt: null, rounds: 10, lastPlayedAt: null });
  assert.equal(app.snapshot('sam').user.runnerEntry, false, 'ten runs are not enough');
  store.put('runnerScores', sam, { personId: sam, best: 10, bestAt: null, rounds: 11, lastPlayedAt: null });
  // Both payloads the app has at its start: the session and the snapshot.
  assert.equal(app.snapshot('sam').user.runnerEntry, true);
  assert.equal(app.session({ uid: 'sam', name: 'Sam Beispiel', email: 'sam@example.invalid', email_verified: true }).runnerEntry, true);
  assert.equal(app.snapshot('admin').user.runnerEntry, false, 'per person');
});

test('every counted run brings the entry closer, the eleventh shows it', t => {
  const { app, play } = setup(t);
  for (let i = 0; i < 10; i++) play('sam');
  assert.equal(app.snapshot('sam').user.runnerEntry, false);
  play('sam');
  assert.equal(app.snapshot('sam').user.runnerEntry, true);
});

test('a waiting account without a person has no entry', t => {
  const { app } = setup(t);
  const user = app.session({ uid: 'new', name: 'Neu', email: 'new@example.invalid', email_verified: true });
  assert.equal(user.status, 'pending');
  assert.equal(user.runnerEntry, false);
});
