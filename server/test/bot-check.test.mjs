import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { Theater } from '../src/theater.mjs';
import { createHttpServer } from '../src/http.mjs';
import { BotCheck, answerMatches, botCheckLimits, clientAddress, editDistance, loadBotCheckConfig } from '../src/bot-check.mjs';

const config = loadBotCheckConfig();

function setup(t, { clock = () => Date.now() } = {}) {
  const store = new Store(); t.after(() => store.close());
  const app = new Theater(store, { pushEnabled: true, bootstrapEmail: 'admin@example.invalid' });
  app.session({ uid: 'admin', name: 'Admin', email: 'admin@example.invalid', email_verified: true });
  const botCheck = new BotCheck({ store, clock });
  const registrations = () => store.all('pushJobs').filter(j => j.title === 'Neue Registrierung');
  return { store, app, botCheck, registrations };
}

async function serve(t, options) {
  const server = createHttpServer(options);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  return `http://127.0.0.1:${server.address().port}/api/mobile/v1`;
}

test('the configured question is "Ramsen" and accepts sensible variants only', () => {
  assert.equal(config.question, 'In welchem Ort ist das Kolpingtheater?');
  for (const answer of ['Ramsen', 'ramsen', '  RAMSEN  ', 'Ramsen (Pfalz)', '67305 Ramsen', 'Ramsen, Pfalz', 'in Ramsen', 'Ramsen in der Pfalz', 'Ramsen.', 'Ramsen!', 'Ramsn', 'Rasmen', 'Rammsen', 'Bamsen'])
    assert.ok(answerMatches(config, answer), answer);
  for (const answer of ['', '   ', 'Ramstein', 'Rmsn', 'Pfalz', '67305', 'nicht Ramsen', 'Ramsen Kaiserslautern', 'Kolpingtheater', 'R'.repeat(101), 42, null])
    assert.ok(!answerMatches(config, answer), String(answer));
  assert.equal(editDistance('ramsen', 'rasmen'), 1);
  assert.equal(editDistance('ramsen', 'rmsn'), 2);
});

test('short answers need an exact match and other questions are configurable', () => {
  const custom = { question: 'Welche Farbe hat der Vorhang?', hint: '', answers: ['Rot', 'Bad Dürkheim'], extraWords: [] };
  assert.ok(answerMatches(custom, 'rot'));
  assert.ok(!answerMatches(custom, 'rof'), 'no typo tolerance below five letters');
  assert.ok(answerMatches(custom, 'bad  duerkheim'));
  assert.ok(answerMatches(custom, 'Bad Dürkhem'));
  const file = join(mkdtempSync(join(tmpdir(), 'bot-check-')), 'config.json');
  writeFileSync(file, JSON.stringify(custom));
  assert.deepEqual(loadBotCheckConfig(file).answers, custom.answers);
  writeFileSync(file, '{"question":"Frage?","answers":[]}');
  assert.throws(() => loadBotCheckConfig(file), /answers missing/);
});

test('a correct answer yields a signed short-lived proof; wrong and forged ones do not', t => {
  let now = Date.parse('2026-10-19T10:00:00Z');
  const { botCheck, store } = setup(t, { clock: () => now });
  assert.deepEqual(botCheck.question(), { question: config.question, hint: config.hint });
  assert.throws(() => botCheck.attempt('a', 'Mannheim'), { status: 400, code: 'bot_check_wrong' });
  assert.throws(() => botCheck.attempt('a', '  '), { status: 400, code: 'bot_check_wrong' });
  const { proof, expiresAt } = botCheck.attempt('a', 'ramsen');
  assert.equal(Date.parse(expiresAt) - now, botCheckLimits.proofTtlMs);
  assert.ok(!proof.toLowerCase().includes('ramsen'));
  const passed = botCheck.evaluate(proof);
  assert.equal(passed.status, 'passed');
  assert.deepEqual(botCheck.evaluate(undefined), { status: 'missing' });
  assert.deepEqual(botCheck.evaluate('x.y'), { status: 'invalid' });
  const [payload] = proof.split('.');
  const forged = Buffer.from(JSON.stringify({ v: 1, id: 'other', exp: now + 1e9 })).toString('base64url');
  assert.deepEqual(botCheck.evaluate(`${forged}.${proof.split('.')[1]}`), { status: 'invalid' });
  assert.deepEqual(botCheck.evaluate(`${payload}.${'A'.repeat(43)}`), { status: 'invalid' });
  // The secret persists, so a restart keeps proofs valid; they still expire.
  assert.equal(new BotCheck({ store, clock: () => now }).evaluate(proof).status, 'passed');
  now += botCheckLimits.proofTtlMs + 1;
  assert.deepEqual(botCheck.evaluate(proof), { status: 'invalid' });
});

test('attempts are limited per client address within the window', t => {
  let now = 0;
  const { botCheck } = setup(t, { clock: () => now });
  for (let i = 0; i < botCheckLimits.attemptsPerWindow; i++) assert.throws(() => botCheck.attempt('10.0.0.1', 'falsch'), { code: 'bot_check_wrong' });
  assert.throws(() => botCheck.attempt('10.0.0.1', 'Ramsen'), { status: 429, code: 'rate_limited' });
  assert.equal(botCheck.attempt('10.0.0.2', 'Ramsen').proof.length > 20, true, 'other addresses are not affected');
  now += botCheckLimits.windowMs + 1;
  assert.ok(botCheck.attempt('10.0.0.1', 'Ramsen').proof);
  assert.ok([...botCheck.attempts.keys()].every(k => !k.includes('10.0.0')), 'addresses are kept only hashed');
  assert.equal(clientAddress({ headers: { 'cf-connecting-ip': '203.0.113.7, 10.0.0.1' }, socket: { remoteAddress: '10.0.0.9' } }, 'cf-connecting-ip'), '203.0.113.7');
  assert.equal(clientAddress({ headers: { 'cf-connecting-ip': '203.0.113.7' }, socket: { remoteAddress: '10.0.0.9' } }), '10.0.0.9', 'headers count only when configured');
});

test('only new accounts with a valid unused proof are announced to admins', t => {
  const { app, store, botCheck, registrations } = setup(t);
  const identity = uid => ({ uid, name: uid, email: `${uid}@example.invalid`, email_verified: true, firebase: { sign_in_provider: 'google.com' } });
  const proof = botCheck.attempt('client', 'Ramsen').proof;
  app.session(identity('sam'), undefined, botCheck.evaluate(proof));
  assert.equal(store.account('sam').botCheck, 'passed');
  assert.equal(registrations().length, 1);
  // The same proof for a second account is not accepted again.
  app.session(identity('copy'), undefined, botCheck.evaluate(proof));
  assert.equal(store.account('copy').botCheck, 'invalid');
  // Older apps without proof: the account waits for approval, unannounced.
  app.session(identity('old-app'), 'Alte Version', botCheck.evaluate(undefined));
  assert.equal(store.account('old-app').status, 'pending');
  assert.equal(store.account('old-app').botCheck, 'missing');
  assert.equal(registrations().length, 1);
  assert.ok(app.adminData('admin').accounts.some(a => a.uid === 'old-app' && a.botCheck === 'missing'), 'admins see the missing proof');
  // After an update the waiting account catches up once.
  app.session(identity('old-app'), undefined, botCheck.evaluate(botCheck.attempt('client', 'ramsen').proof));
  assert.equal(store.account('old-app').botCheck, 'passed');
  assert.equal(registrations().length, 2);
  // Existing accounts and internal callers keep working without a proof.
  app.session(identity('sam'), undefined, botCheck.evaluate(undefined));
  assert.equal(store.account('sam').botCheck, 'passed');
  app.session(identity('legacy'));
  assert.equal(store.account('legacy').botCheck, undefined);
  assert.equal(registrations().length, 3);
});

test('HTTP: the question is public, the answer stays on the server and the proof reaches the account', async t => {
  const { app, store, botCheck, registrations } = setup(t);
  const base = await serve(t, { theater: app, botCheck, verifyToken: async token => ({ uid: token, name: 'Neu', email: `${token}@example.invalid`, email_verified: true, firebase: { sign_in_provider: 'google.com' } }) });
  const question = await fetch(`${base}/bot-check/`);
  assert.equal(question.status, 200);
  const text = await question.text();
  assert.equal(JSON.parse(text).question, config.question);
  assert.ok(!text.toLowerCase().includes('ramsen'), 'no answer in the response');
  const post = (path, body, token) => fetch(`${base}${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) });
  const wrong = await post('/bot-check/', { answer: 'Berlin' });
  assert.equal(wrong.status, 400);
  assert.equal((await wrong.json()).code, 'bot_check_wrong');
  const right = await post('/bot-check/', { answer: ' Ramsen (Pfalz) ' });
  assert.equal(right.status, 200);
  const { proof } = await right.json();
  assert.equal((await post('/auth/session/', { botCheckProof: proof }, 'new-user')).status, 200);
  assert.equal(store.account('new-user').botCheck, 'passed');
  assert.equal((await fetch(`${base}/auth/session/`, { headers: { Authorization: 'Bearer older-app' } })).status, 200);
  assert.equal(store.account('older-app').botCheck, 'missing');
  assert.deepEqual(registrations().map(j => j.data.accountUid), ['new-user']);
});

test('HTTP: attempts beyond the limit are refused', async t => {
  const { app, botCheck } = setup(t);
  const base = await serve(t, { theater: app, botCheck, verifyToken: async () => ({}) });
  const statuses = [];
  for (let i = 0; i <= botCheckLimits.attemptsPerWindow; i++) statuses.push((await fetch(`${base}/bot-check`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{"answer":"nein"}' })).status);
  assert.deepEqual(statuses, [...Array(botCheckLimits.attemptsPerWindow).fill(400), 429]);
});

test('the privacy notice describes the attempt limit', () => {
  const privacy = readFileSync(new URL('../../web/privacy.html', import.meta.url), 'utf8');
  assert.match(privacy, /id="botschutz"/);
  assert.match(privacy, /10 Minuten/);
});
