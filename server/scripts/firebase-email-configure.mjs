// Configure existing Firebase Auth mail delivery. This does not create users or send mail.
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { GoogleAuth } from 'google-auth-library';

async function main() {
const project = process.env.FIREBASE_PROJECT_ID;
if (!project || !process.env.GOOGLE_APPLICATION_CREDENTIALS || !process.env.RESEND_API_KEY_FILE) throw new Error('Firebase-Projekt, Server-Credentials und privater Resend-Schlüssel erforderlich.');
const deployment = JSON.parse(await readFile(new URL('../../config/dokploy.json', import.meta.url), 'utf8'));
const sender = deployment.email?.senderEmail;
if (!sender || !sender.endsWith('@kolpingtheater-ramsen.de')) throw new Error('Theater-Absender fehlt.');
const key = (await readFile(process.env.RESEND_API_KEY_FILE, 'utf8')).trim();
if (!key.startsWith('re_')) throw new Error('Ungültiger Resend-Schlüssel.');
const client = await new GoogleAuth({ scopes: ['https://www.googleapis.com/auth/cloud-platform'] }).getClient();
const url = `https://identitytoolkit.googleapis.com/admin/v2/projects/${project}/config`;
const { data: before } = await client.request({ url });
const backupDir = new URL('../../artifacts/resend-2026-10-10/', import.meta.url);
await mkdir(backupDir, { recursive: true });
const backup = structuredClone(before.notification ?? {});
if (backup.sendEmail?.smtp) delete backup.sendEmail.smtp.password;
await writeFile(new URL('firebase-notification-before.json', backupDir), JSON.stringify(backup, null, 2) + '\n', { mode: 0o600, flag: 'wx' }).catch(e => { if (e.code !== 'EEXIST') throw e; });
const template = { senderDisplayName: 'Kolpingtheater Ramsen', senderLocalPart: sender.split('@')[0], replyTo: deployment.email.replyTo };
const fields = ['notification.sendEmail.method', 'notification.sendEmail.smtp', 'notification.defaultLocale'];
const sendEmail = { method: 'CUSTOM_SMTP', smtp: { host: 'smtp.resend.com', port: 465, username: 'resend', password: key, senderEmail: sender, securityMode: 'SSL' } };
for (const kind of ['verifyEmailTemplate', 'resetPasswordTemplate', 'changeEmailTemplate']) {
  sendEmail[kind] = template;
  for (const field of Object.keys(template)) fields.push(`notification.sendEmail.${kind}.${field}`);
}
try {
  await client.request({ url, method: 'PATCH', params: { updateMask: fields.join(',') }, data: { notification: { defaultLocale: 'de', sendEmail } } });
} catch (error) {
  // Gaxios errors can contain the complete request with the SMTP password.
  console.error('Firebase-E-Mail-Konfiguration fehlgeschlagen:', error.response?.status ?? 'network', String(error.response?.data?.error?.message ?? 'unavailable').replaceAll(key, '[redacted]').slice(0, 300));
  process.exit(1);
}
const { data: after } = await client.request({ url });
if (after.notification?.sendEmail?.method !== 'CUSTOM_SMTP' || after.notification.sendEmail.smtp?.host !== 'smtp.resend.com') throw new Error('SMTP-Konfiguration wurde nicht übernommen.');
const path = new URL('../../config/firebase-server-settings.json', import.meta.url);
const settings = JSON.parse(await readFile(path, 'utf8'));
settings.email = { method: 'CUSTOM_SMTP', smtpHost: 'smtp.resend.com', senderEmail: sender, locale: after.notification.defaultLocale };
await writeFile(path, JSON.stringify(settings, null, 2) + '\n');
console.log('Firebase Auth versendet Bestätigungen und Passwort-E-Mails über Resend:', sender);

}
main().catch(error => { console.error("Firebase-E-Mail-Einrichtung fehlgeschlagen:", error.response?.status ?? error.code ?? "configuration_error"); process.exit(1); });
