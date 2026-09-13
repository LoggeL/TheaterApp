// Content-addressed entrypoints and icons survive reverse proxies overriding cache headers.
import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
const root = new URL('../build/web/', import.meta.url);
const hash = s => createHash('sha256').update(s).digest('hex').slice(0, 16);
async function versionIcon(path) {
  const canonical = path.replace(/\.[a-f0-9]{16}(?=\.png$)/, '');
  const bytes = await readFile(new URL(canonical, root));
  const name = canonical.replace(/\.png$/, `.${hash(bytes)}.png`);
  await writeFile(new URL(name, root), bytes);
  return name;
}
const main = await readFile(new URL('main.dart.js', root));
const mainName = `main.${hash(main)}.dart.js`;
let bootstrap = await readFile(new URL('flutter_bootstrap.js', root), 'utf8');
bootstrap = bootstrap.replaceAll('main.dart.js', mainName);
const bootName = `flutter_bootstrap.${hash(bootstrap)}.js`;
const favicon = await versionIcon('favicon.png');
const touchIcon = await versionIcon('icons/Icon-192.png');
const manifest = JSON.parse(await readFile(new URL('manifest.json', root), 'utf8'));
for (const icon of manifest.icons) icon.src = await versionIcon(icon.src);
const manifestJson = JSON.stringify(manifest, null, 2) + '\n';
const manifestName = `manifest.${hash(manifestJson)}.json`;
let index = await readFile(new URL('index.html', root), 'utf8');
index = index
  .replace(/src="flutter_bootstrap(?:\.[a-f0-9]{16})?\.js"/, `src="${bootName}"`)
  .replace(/href="favicon(?:\.[a-f0-9]{16})?\.png"/, `href="${favicon}"`)
  .replace(/href="icons\/Icon-192(?:\.[a-f0-9]{16})?\.png"/, `href="${touchIcon}"`)
  .replace(/href="manifest(?:\.[a-f0-9]{16})?\.json"/, `href="${manifestName}"`);
await writeFile(new URL(mainName, root), main);
await writeFile(new URL(bootName, root), bootstrap);
// Keep the original manifest current for already installed web apps as well.
await writeFile(new URL('manifest.json', root), manifestJson);
await writeFile(new URL(manifestName, root), manifestJson);
await writeFile(new URL('index.html', root), index);
await writeFile(new URL('release-assets.json', root), JSON.stringify({ main: mainName, bootstrap: bootName, favicon, touchIcon, manifest: manifestName }) + '\n');
console.log(`Versioned web entrypoint: ${mainName}; favicon: ${favicon}`);
