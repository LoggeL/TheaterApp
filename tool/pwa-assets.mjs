import { readFile, writeFile, readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { relative, join, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

export async function writePwaWorker(root, entrypoints, assetPaths = {assetBase:'',canvasKitBaseUrl:'canvaskit/'}) {
  const manifest = JSON.parse(await readFile(new URL('manifest.json', root), 'utf8'));
  const paths = new Set(['index.html', 'privacy.html', 'manifest.json', ...Object.values(entrypoints), ...manifest.icons.map(icon => icon.src)]);
  for (const dir of ['assets', 'canvaskit']) {
    const directory = dir === 'assets' ? assetPaths.assetBase + 'assets/' : assetPaths.canvasKitBaseUrl;
    for (const file of await readdir(new URL(directory, root), {recursive: true, withFileTypes: true})) {
      if (!file.isFile()) continue;
      const path = relative(fileURLToPath(root), join(file.parentPath, file.name)).split(sep).join('/');
      if (dir === 'assets' || /(?:^|\/)canvaskit\.(?:js|wasm)$/.test(path)) paths.add(path);
    }
  }
  let index = await readFile(new URL('index.html', root), 'utf8');
  index = index.replace(/(name="theater-pwa-version" content=")[^"]+/, '$1development');
  const template = await readFile(new URL('../web/theater-service-worker.js', import.meta.url), 'utf8');
  const digest = createHash('sha256').update(template);
  const assets = [...paths].sort();
  for (const path of assets) {
    const bytes = path === 'index.html' ? Buffer.from(index) : await readFile(new URL(path, root));
    digest.update(path).update(bytes);
  }
  // The same pinned public Firebase SDK that FlutterFire uses is needed to
  // initialize the existing local session when the app starts offline.
  const messaging = await readFile(new URL('firebase-messaging-sw.js', root), 'utf8');
  const firebaseVersion = messaging.match(/firebasejs\/(\d+\.\d+\.\d+)\//)?.[1];
  if (!firebaseVersion) throw new Error('The public Firebase SDK version is missing.');
  for (const service of ['app', 'auth', 'messaging']) assets.push(`https://www.gstatic.com/firebasejs/${firebaseVersion}/firebase-${service}.js`);
  digest.update(JSON.stringify(assets));
  const version = digest.digest('hex').slice(0, 20);
  index = index.replace(/(name="theater-pwa-version" content=")development/, '$1' + version);
  const worker = template.replace("{version: 'development', assets: []}", JSON.stringify({version, assets: assets.map(path => path.startsWith('https:') ? path : '/' + path)}));
  await writeFile(new URL('index.html', root), index);
  await writeFile(new URL('theater-service-worker.js', root), worker);
  return {version, assets: assets.length, worker: 'theater-service-worker.js'};
}
