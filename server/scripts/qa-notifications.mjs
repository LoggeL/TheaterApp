// Manual companion for testing the signed APK's notification buttons.
// Uses only the explicitly isolated Play review account and restores its event.
import { readFile, writeFile, unlink } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
const root = new URL('../../', import.meta.url);
const mode = process.argv[2];
const statePath = new URL('.secrets/notification-qa-state.json', root);
try {
  const credentials = JSON.parse(await readFile(new URL('.secrets/play-review-credentials.json', root)));
  const config = JSON.parse(await readFile(new URL('config/production.android.json', root)));
  const auth = await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${config.FIREBASE_API_KEY}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: credentials.email, password: credentials.password, returnSecureToken: true }),
  });
  assert.equal(auth.status, 200, 'Review sign-in failed');
  const { idToken, localId } = await auth.json();
  assert.equal(localId, credentials.uid);
  const api = async (path, body) => {
    const r = await fetch(`${config.API_BASE_URL}/api/mobile/v1${path}/`, {
      method: body ? 'POST' : 'GET',
      headers: { Authorization: `Bearer ${idToken}`, 'Content-Type': 'application/json', 'Idempotency-Key': randomUUID() },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    assert.equal(r.status, 200, `Unexpected status for ${path}`);
    return r.json();
  };
  await api('/auth/session', {});
  let snapshot = await api('/snapshot');
  assert.equal(snapshot.capabilities.sampleData, true, 'Refusing to change the real ensemble');
  if (mode === 'prepare') {
    const original = snapshot.events[0];
    assert.ok(original);
    await writeFile(statePath, JSON.stringify({ event: original, status: snapshot.attendanceByEvent[original.id] ?? 'open', reason: snapshot.declineReasons[original.id], expectedArrivalAt: snapshot.expectedArrivals[original.id], reminders: snapshot.reminders }), { mode: 0o600, flag: 'wx' });
    await api('/actions', { action: 'settings.reminders', value: { dayBefore: false, twoHours: false, changes: true } });
    await api('/actions', { ...original, action: 'event.save', title: 'Push-Prüfung 0.4.1', locked: false, startsAt: new Date(Date.now() + 48 * 3600000).toISOString(), endsAt: new Date(Date.now() + 50 * 3600000).toISOString(), place: 'Kolpingheim' });
    await api('/actions', { action: 'attendance', eventId: original.id, status: 'open' });
    console.log('Isolated review event prepared.');
  } else if (mode === 'send') {
    const state = JSON.parse(await readFile(statePath));
    const event = snapshot.events.find(e => e.id === state.event.id);
    await api('/actions', { ...event, action: 'event.save' });
    console.log('Review event push queued.');
  } else if (mode === 'status') {
    const state = JSON.parse(await readFile(statePath));
    const status = snapshot.attendanceByEvent[state.event.id];
    if (process.argv[3]) assert.equal(status, process.argv[3], 'Notification response has not been saved');
    const push = await api('/admin/push');
    console.log(JSON.stringify({ event: state.event.id, status, devices: push.devices.map(d => ({ platform: d.platform, notificationActions: d.notificationActions })), lastJob: push.jobs.at(-1)?.status }));
  } else if (mode === 'cleanup') {
    const state = JSON.parse(await readFile(statePath));
    const current = snapshot.events.find(e => e.id === state.event.id);
    // Restore the response while the temporary event still allows changes.
    await api('/actions', { action: 'attendance', eventId: current.id, status: state.status, reason: state.reason, expectedArrivalAt: state.expectedArrivalAt });
    await api('/actions', { ...state.event, action: 'event.save', version: current.version });
    await api('/actions', { action: 'settings.reminders', value: state.reminders });
    await unlink(statePath);
    console.log('Review event, response and reminder settings restored.');
  } else throw new Error('Usage: qa-notifications.mjs prepare|send|status [yes|no]|cleanup');
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
