import { createHash, createHmac, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { AppError } from './theater.mjs';

// A simple knowledge question before sign-in and registration ("Botschutz").
// The client only receives the question; answers stay on the server. A correct
// answer returns a short-lived signed proof that a new account presents once.
// Attempts are limited per client address, which is kept only hashed in memory.
export const botCheckLimits = Object.freeze({ attemptsPerWindow: 10, windowMs: 10 * 60000, proofTtlMs: 30 * 60000, maxTrackedClients: 5000, maxAnswerLength: 100 });

const fail = (status, message, code) => { throw new AppError(status, message, code); };
const fold = value => value.normalize('NFKC').toLowerCase().replace(/ä/g, 'ae').replace(/ö/g, 'oe').replace(/ü/g, 'ue').replace(/ß/g, 'ss');
const b64 = value => Buffer.from(value).toString('base64url');

/** Reads and validates the question and its answers, by default from bot-check.json. */
export function loadBotCheckConfig(file = new URL('./bot-check.json', import.meta.url)) {
  const c = JSON.parse(readFileSync(file, 'utf8'));
  const texts = (value, max) => Array.isArray(value) && value.every(x => typeof x === 'string' && x.trim() && x.length <= max);
  if (typeof c.question !== 'string' || !c.question.trim() || c.question.length > 300) throw new Error('Bot check: question missing');
  if (!texts(c.answers, 100) || !c.answers.length) throw new Error('Bot check: answers missing');
  if (c.extraWords !== undefined && !texts(c.extraWords, 40)) throw new Error('Bot check: invalid extraWords');
  if (c.hint !== undefined && (typeof c.hint !== 'string' || c.hint.length > 300)) throw new Error('Bot check: invalid hint');
  return { question: c.question.trim(), hint: c.hint?.trim() ?? '', answers: c.answers, extraWords: c.extraWords ?? [] };
}

/** Optimal string alignment distance: insertions, deletions, substitutions and swapped neighbours. */
export function editDistance(a, b) {
  const x = [...a], y = [...b], d = Array.from({ length: x.length + 1 }, (_, i) => [i, ...Array(y.length).fill(0)]);
  for (let j = 1; j <= y.length; j++) d[0][j] = j;
  for (let i = 1; i <= x.length; i++) for (let j = 1; j <= y.length; j++) {
    const cost = x[i - 1] === y[j - 1] ? 0 : 1;
    d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost);
    if (i > 1 && j > 1 && x[i - 1] === y[j - 2] && x[i - 2] === y[j - 1]) d[i][j] = Math.min(d[i][j], d[i - 2][j - 2] + 1);
  }
  return d[x.length][y.length];
}

/**
 * Whether `input` answers the question. Case, surrounding spaces, punctuation, a postal code,
 * a part in brackets or after a comma and the configured extra words ("in", "Pfalz") do not
 * matter. Answers with at least five letters also accept one typo.
 */
export function answerMatches(config, input) {
  if (typeof input !== 'string' || input.length > botCheckLimits.maxAnswerLength) return false;
  const extras = new Set(config.extraWords.map(fold));
  const words = fold(input).replace(/\([^)]*\)/g, ' ').split(/[,;/]/)[0].replace(/\b\d{5}\b/g, ' ').replace(/[^\p{L}\p{N}\s-]/gu, ' ').split(/\s+/).filter(Boolean);
  while (words.length && extras.has(words[0])) words.shift();
  while (words.length && extras.has(words.at(-1))) words.pop();
  const given = words.join(' ');
  if (!given) return false;
  return config.answers.some(answer => {
    const expected = fold(answer).split(/\s+/).filter(Boolean).join(' ');
    return given === expected || (expected.length >= 5 && editDistance(given, expected) <= 1);
  });
}

/** The client address for the attempt limit; behind Cloudflare the configured header carries it. */
export const clientAddress = (req, header = '') => (header && String(req.headers[header.toLowerCase()] ?? '').split(',')[0].trim()) || req.socket?.remoteAddress || 'unknown';

export class BotCheck {
  /** `store` keeps the signing secret, so proofs survive a restart. */
  constructor({ store, config = loadBotCheckConfig(), clock = () => Date.now() }) {
    this.config = config; this.clock = clock; this.attempts = new Map(); this.salt = randomBytes(16);
    let secret = store.get('settings', 'botCheckSecret')?.value;
    if (!secret) { secret = randomBytes(32).toString('hex'); store.put('settings', 'botCheckSecret', { value: secret, createdAt: new Date(clock()).toISOString() }); }
    this.secret = Buffer.from(secret, 'hex');
  }
  question() { return { question: this.config.question, hint: this.config.hint }; }
  /** Checks one answer from `client`; at most `attemptsPerWindow` per client in `windowMs`. */
  attempt(client, answer) {
    const at = this.clock(), since = at - botCheckLimits.windowMs;
    const key = createHash('sha256').update(this.salt).update(String(client)).digest('base64url').slice(0, 22);
    if (this.attempts.size >= botCheckLimits.maxTrackedClients) {
      for (const [k, times] of this.attempts) if (!times.some(t => t > since)) this.attempts.delete(k);
      while (this.attempts.size >= botCheckLimits.maxTrackedClients) this.attempts.delete(this.attempts.keys().next().value);
    }
    const recent = (this.attempts.get(key) ?? []).filter(t => t > since);
    if (recent.length >= botCheckLimits.attemptsPerWindow) fail(429, 'Das waren gerade sehr viele Versuche. Bitte warte ein paar Minuten und versuche es dann noch einmal.', 'rate_limited');
    this.attempts.delete(key); this.attempts.set(key, [...recent, at]);
    if (typeof answer !== 'string' || !answer.trim()) fail(400, 'Bitte gib eine Antwort ein.', 'bot_check_wrong');
    if (!answerMatches(this.config, answer)) fail(400, 'Das passt leider nicht. Schau noch einmal genau hin und versuche es erneut.', 'bot_check_wrong');
    const expiresAt = at + botCheckLimits.proofTtlMs;
    const payload = b64(JSON.stringify({ v: 1, id: randomUUID(), exp: expiresAt }));
    return { proof: `${payload}.${this.sign(payload)}`, expiresAt: new Date(expiresAt).toISOString() };
  }
  sign(payload) { return createHmac('sha256', this.secret).update(payload).digest('base64url'); }
  /** `{ status: 'passed', id }` for a valid unexpired proof, else `missing` or `invalid`. */
  evaluate(proof) {
    if (proof === undefined || proof === null || proof === '') return { status: 'missing' };
    if (typeof proof !== 'string' || proof.length > 500) return { status: 'invalid' };
    const [payload, signature, ...rest] = proof.split('.');
    if (!payload || !signature || rest.length) return { status: 'invalid' };
    const expected = Buffer.from(this.sign(payload)), given = Buffer.from(signature);
    if (given.length !== expected.length || !timingSafeEqual(given, expected)) return { status: 'invalid' };
    try {
      const data = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
      if (data.v !== 1 || typeof data.id !== 'string' || !Number.isFinite(data.exp) || data.exp <= this.clock()) return { status: 'invalid' };
      return { status: 'passed', id: data.id };
    } catch { return { status: 'invalid' }; }
  }
}
