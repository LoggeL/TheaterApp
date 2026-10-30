// Content-addressed entrypoints and icons survive reverse proxies overriding cache headers.
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { writePwaWorker } from './pwa-assets.mjs';
import { versionWebAssetPaths } from './web-asset-paths.mjs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
// An optional directory argument versions a build outside build/web.
const root = process.argv[2] ? pathToFileURL(resolve(process.argv[2]) + '/') : new URL('../build/web/', import.meta.url);
const hash = s => createHash('sha256').update(s).digest('hex').slice(0, 16);
async function versionIcon(path) {
  const canonical = path.replace(/\.[a-f0-9]{16}(?=\.png$)/, '');
  const bytes = await readFile(new URL(canonical, root));
  const name = canonical.replace(/\.png$/, `.${hash(bytes)}.png`);
  await writeFile(new URL(name, root), bytes);
  return name;
}
const main = await readFile(new URL('main.dart.js', root));
// A stale Flutter plugin registrant can silently ship the native channel on web.
if (!main.includes(Buffer.from('__image_picker_web-file-input'))) {
  throw new Error('Web image picker is missing. Run flutter clean and rebuild web before deploying.');
}
const mainName = `main.${hash(main)}.dart.js`;
// A --wasm build adds the dart2wasm module and its JS runtime; dart2js stays the fallback.
// Only the loader config tells whether this build has it; stale files of an older build don't count.
let bootstrap = await readFile(new URL('flutter_bootstrap.js', root), 'utf8');
const wasmBuild = bootstrap.includes('"mainWasmPath":"main.dart.wasm"');
const wasm = wasmBuild ? await readFile(new URL('main.dart.wasm', root)) : null;
const wasmRuntime = wasmBuild ? await readFile(new URL('main.dart.mjs', root)) : null;
const wasmName = wasm && `main.${hash(wasm)}.dart.wasm`, wasmRuntimeName = wasmRuntime && `main.${hash(wasmRuntime)}.dart.mjs`;
const assetPaths = await versionWebAssetPaths(root);
bootstrap = bootstrap.replaceAll('main.dart.js', mainName);
if (wasm) {
  bootstrap = bootstrap.replaceAll('"main.dart.wasm"', `"${wasmName}"`).replaceAll('"main.dart.mjs"', `"${wasmRuntimeName}"`);
  if (!bootstrap.includes(wasmName) || !bootstrap.includes(wasmRuntimeName)) throw new Error('The Flutter loader is missing the versioned Wasm entrypoint.');
}
bootstrap = bootstrap
  .replace(/assetBase:\s*'[^']*'/, `assetBase: '${assetPaths.assetBase}'`)
  .replace(/canvasKitBaseUrl:\s*'[^']*'/, `canvasKitBaseUrl: '${assetPaths.canvasKitBaseUrl}'`);
if (!bootstrap.includes(assetPaths.assetBase) || !bootstrap.includes(assetPaths.canvasKitBaseUrl)) throw new Error('The Flutter loader is missing versioned asset paths.');
const bootName = `flutter_bootstrap.${hash(bootstrap)}.js`;
const pwa = await readFile(new URL('pwa.js', root));
const pwaName = `pwa.${hash(pwa)}.js`;
const favicon = await versionIcon('favicon.png');
const touchIcon = await versionIcon('icons/apple-touch-icon.png');
const manifest = JSON.parse(await readFile(new URL('manifest.json', root), 'utf8'));
for (const icon of manifest.icons) icon.src = await versionIcon(icon.src);
const manifestJson = JSON.stringify(manifest, null, 2) + '\n';
const manifestName = `manifest.${hash(manifestJson)}.json`;
let index = await readFile(new URL('index.html', root), 'utf8');
index = index
  .replace(/src="flutter_bootstrap(?:\.[a-f0-9]{16})?\.js"/, `src="${bootName}"`)
  .replace(/src="pwa(?:\.[a-f0-9]{16})?\.js"/, `src="${pwaName}"`)
  .replace(/href="favicon(?:\.[a-f0-9]{16})?\.png"/, `href="${favicon}"`)
  .replace(/href="icons\/apple-touch-icon(?:\.[a-f0-9]{16})?\.png"/, `href="${touchIcon}"`)
  .replace(/href="manifest(?:\.[a-f0-9]{16})?\.json"/, `href="${manifestName}"`);
// Cloudflare's Rocket Loader would otherwise rewrite the start scripts and add a round trip before Dart starts.
if ([...index.matchAll(/<script\b[^>]*>/g)].some(([tag]) => !tag.includes('data-cfasync="false"'))) throw new Error('Every script in index.html needs data-cfasync="false".');
await writeFile(new URL(mainName, root), main);
if (wasm) { await writeFile(new URL(wasmName, root), wasm); await writeFile(new URL(wasmRuntimeName, root), wasmRuntime); }
await writeFile(new URL(bootName, root), bootstrap);
await writeFile(new URL(pwaName, root), pwa);
// Keep the original manifest current for already installed web apps as well.
await writeFile(new URL('manifest.json', root), manifestJson);
await writeFile(new URL(manifestName, root), manifestJson);
await writeFile(new URL('index.html', root), index);
const entrypoints = { main: mainName, ...(wasm ? { wasm: wasmName, wasmRuntime: wasmRuntimeName } : {}), bootstrap: bootName, favicon, touchIcon, manifest: manifestName, pwa: pwaName };
const pwaBuild = await writePwaWorker(root, entrypoints, assetPaths);
await writeFile(new URL('release-assets.json', root), JSON.stringify({ ...entrypoints, ...assetPaths, serviceWorker: pwaBuild.worker, pwaVersion: pwaBuild.version }) + '\n');
console.log(`Versioned web entrypoint: ${mainName}${wasm ? ` + ${wasmName}` : ''}; favicon: ${favicon}`);
console.log(`PWA app shell: ${pwaBuild.version}; ${pwaBuild.assets} public assets`);
