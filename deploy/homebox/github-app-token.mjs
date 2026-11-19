#!/usr/bin/env node
// Homebox only: use its existing Dokploy GitHub App to read the public TheaterApp CI artifact.
import { createSign, randomUUID } from 'node:crypto';
import { lstat, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';

const providerId = 'xKFwWqvC8iXO9kxl1FSPh';
const appId = 2661234;
const installationId = 104323981;
const repositoryId = 1367574965;
const tokenDir = join('/run/user', String(process.getuid()), 'theater-autodeploy');
const tokenPath = join(tokenDir, 'github-token');
const expiryPath = join(tokenDir, 'expires-at');
const renewBefore = 10 * 60 * 1000;

async function atomicWrite(path, content) {
  const tmp = join(dirname(path), randomUUID());
  try {
    await writeFile(tmp, content, { mode: 0o600, flag: 'wx' });
    await rename(tmp, path);
  } finally {
    await rm(tmp, { force: true });
  }
}

function appJwt(config) {
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const data = [encode({ alg: 'RS256', typ: 'JWT' }), encode({ iss: appId, iat: now - 30, exp: now + 300 })].join('.');
  const storedKey = config.githubPrivateKey;
  const key = storedKey.includes('-----BEGIN') ? storedKey : Buffer.from(storedKey, 'base64');
  return data + '.' + createSign('RSA-SHA256').update(data).sign(key, 'base64url');
}

async function json(url, headers, body) {
  const options = { headers, redirect: 'error', signal: AbortSignal.timeout(20_000) };
  if (body) Object.assign(options, { method: 'POST', body: JSON.stringify(body) });
  const res = await fetch(url, options);
  if (!res.ok) throw new Error('HTTP ' + res.status + ' bei ' + new URL(url).hostname);
  return res.json();
}

async function main() {
  const dir = await lstat(tokenDir);
  if (!dir.isDirectory() || dir.uid !== process.getuid() || (dir.mode & 0o077)) {
    throw new Error('Privates Runtime-Verzeichnis fehlt.');
  }
  try {
    const file = await lstat(tokenPath);
    const expiry = Date.parse((await readFile(expiryPath, 'utf8')).trim());
    if (file.isFile() && file.uid === dir.uid && !(file.mode & 0o077) && file.size && expiry > Date.now() + renewBefore) return;
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }

  const keyPath = process.env.DOKPLOY_API_KEY_FILE;
  const keyFile = await lstat(keyPath);
  if (!keyFile.isFile() || keyFile.uid !== process.getuid() || (keyFile.mode & 0o077)) {
    throw new Error('DOKPLOY_API_KEY_FILE muss eine private Datei sein.');
  }
  const key = (await readFile(keyPath, 'utf8')).trim();
  const config = await json('http://localhost:3000/api/github.one?githubId=' + providerId, { 'x-api-key': key });
  if (Number(config.githubAppId) !== appId || Number(config.githubInstallationId) !== installationId) {
    throw new Error('Die konfigurierte Dokploy-App oder Installation hat sich geändert.');
  }
  const headers = {
    'User-Agent': 'TheaterApp-Homebox', Accept: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28', 'Content-Type': 'application/json',
  };
  const api = 'https://api.github.com';
  const credential = await json(api + '/app/installations/' + installationId + '/access_tokens',
    { ...headers, Authorization: 'Bearer ' + appJwt(config) },
    { repository_ids: [repositoryId], permissions: { metadata: 'read' } });
  const { token, permissions, expires_at: expiresAt } = credential;
  if (typeof token !== 'string' || !token || /\s/.test(token) || permissions?.metadata !== 'read' ||
      Object.keys(permissions).length !== 1 || !(Date.parse(expiresAt) > Date.now() + renewBefore)) {
    throw new Error('Unerwartete Berechtigungen oder Laufzeit des Installationstokens.');
  }
  const repos = await json(api + '/installation/repositories?per_page=2', { ...headers, Authorization: 'Bearer ' + token });
  if (repos.total_count !== 1 || repos.repositories?.[0]?.id !== repositoryId) {
    throw new Error('Installationstoken ist nicht ausschließlich auf TheaterApp beschränkt.');
  }
  await atomicWrite(tokenPath, token + '\n');
  await atomicWrite(expiryPath, expiresAt + '\n');
  console.log('TheaterApp-Lesezugang bis ' + expiresAt + ' erneuert.');
}

main().catch(error => { console.error('GitHub-App-Anmeldung fehlgeschlagen: ' + error.message); process.exitCode = 1; });
