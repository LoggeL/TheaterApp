// Local fixtures only. This script neither reads credentials nor sends mail.
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { eventEmail } from '../src/email.mjs';
import { firebasePasswordResetTemplate } from '../src/email-template.mjs';

const directory = resolve(process.argv[2] ?? '../artifacts/email-preview');
await mkdir(directory, { recursive: true });
const event = { id: 'preview', title: 'Ensembleprobe', place: 'Kolpingheim Ramsen', startsAt: '2026-11-12T18:00:00Z' };
for (const [name, job] of [
  ['termin', { newEvent: true }],
  ['erinnerung', { remindOpen: true }],
  ['absage', { cancelled: true, reason: 'Die Probe wird verschoben. Ein neuer Termin folgt.' }],
  ['test', { test: true }],
]) {
  const mail = eventEmail(job, event, 'https://app.example.invalid');
  await writeFile(resolve(directory, `${name}.html`), mail.html);
  await writeFile(resolve(directory, `${name}.txt`), mail.text);
}
await writeFile(resolve(directory, 'passwort.html'), firebasePasswordResetTemplate().body.replaceAll('%LINK%', 'https://app.example.invalid/reset-preview'));
console.log(`E-Mail-Vorschauen: ${directory}`);
