import { access, readFile, writeFile, readdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { relative, join, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

// The same rule as hashedWebFile in server/src/http.mjs: only these names are served as immutable.
// All other files must bypass the HTTP cache when a new worker installs.
const contentAddressed = /^(?:main\.[a-f0-9]{16}\.dart\.(?:js|mjs|wasm)|(?:flutter_bootstrap\.[a-f0-9]{16}|pwa\.[a-f0-9]{16})\.js|(?:icons\/)?[\w-]+\.[a-f0-9]{16}\.png|web-(?:renderer|assets)\/[a-f0-9]{16}\/.+)$/;

export async function writePwaWorker(root, entrypoints, assetPaths = {assetBase:'',canvasKitBaseUrl:'canvaskit/'}) {
  const manifest = JSON.parse(await readFile(new URL('manifest.json', root), 'utf8'));
  // The Dart entrypoints belong to their renderer; the worker precaches the one the browser starts with.
  const {main, wasm, wasmRuntime, ...shell} = entrypoints;
  const paths = new Set(['index.html', 'privacy.html', 'manifest.json', ...Object.values(shell), ...manifest.icons.map(icon => icon.src)]);
  const directory = assetPaths.assetBase + 'assets/';
  // The hidden game loads its pictures and sounds on demand; they need no offline copy.
  const onDemand = directory + 'assets/games/';
  for (const file of await readdir(new URL(directory, root), {recursive: true, withFileTypes: true})) {
    const path = relative(fileURLToPath(root), join(file.parentPath, file.name)).split(sep).join('/');
    if (file.isFile() && !path.startsWith(onDemand)) paths.add(path);
  }
  // The variants flutter.js picks from. skwasm_heavy (no Wasm-capable browser needs it) and wimp stay out.
  const engine = assetPaths.canvasKitBaseUrl;
  const candidates = {
    canvaskit: [main, engine + 'canvaskit.js', engine + 'canvaskit.wasm'],
    chromium: [main, engine + 'chromium/canvaskit.js', engine + 'chromium/canvaskit.wasm'],
    skwasm: wasm ? [wasmRuntime, wasm, engine + 'skwasm.js', engine + 'skwasm.wasm'] : [],
  };
  const renderers = {};
  for (const [name, files] of Object.entries(candidates)) {
    const present = [];
    for (const path of files) if (path && await access(new URL(path, root)).then(() => true, () => false)) present.push(path);
    if (present.some(path => path.endsWith('.wasm'))) renderers[name] = present;
  }
  let index = await readFile(new URL('index.html', root), 'utf8');
  index = index.replace(/(name="theater-pwa-version" content=")[^"]+/, '$1development');
  const template = await readFile(new URL('../web/theater-service-worker.js', import.meta.url), 'utf8');
  const digest = createHash('sha256').update(template);
  const assets = [...paths].sort();
  for (const path of [...assets, ...Object.values(renderers).flat()]) {
    const bytes = path === 'index.html' ? Buffer.from(index) : await readFile(new URL(path, root));
    digest.update(path).update(bytes);
  }
  // The same pinned public Firebase SDK that FlutterFire uses is needed to
  // initialize the existing local session when the app starts offline.
  const messaging = await readFile(new URL('firebase-messaging-sw.js', root), 'utf8');
  const firebaseVersion = messaging.match(/firebasejs\/(\d+\.\d+\.\d+)\//)?.[1];
  if (!firebaseVersion) throw new Error('The public Firebase SDK version is missing.');
  for (const service of ['app', 'auth', 'messaging']) assets.push(`https://www.gstatic.com/firebasejs/${firebaseVersion}/firebase-${service}.js`);
  digest.update(JSON.stringify({assets, renderers}));
  const version = digest.digest('hex').slice(0, 20);
  index = index.replace(/(name="theater-pwa-version" content=")development/, '$1' + version);
  // Pinned Firebase SDK URLs carry their version and never change either.
  const fresh = [...new Set([...assets, ...Object.values(renderers).flat()])].filter(path => !path.startsWith('https:') && !contentAddressed.test(path)).map(path => '/' + path);
  const worker = template.replace("{version: 'development', assets: []}", JSON.stringify({version, assets: assets.map(path => path.startsWith('https:') ? path : '/' + path), fresh, renderers: Object.fromEntries(Object.entries(renderers).map(([name, files]) => [name, files.map(path => '/' + path)]))}));
  await writeFile(new URL('index.html', root), index);
  await writeFile(new URL('theater-service-worker.js', root), worker);
  return {version, assets: assets.length, renderers: Object.keys(renderers), worker: 'theater-service-worker.js'};
}
