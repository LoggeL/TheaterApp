import { cp, mkdir, readdir, readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { relative, join, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

async function fingerprintDirectory(root, source, destination, nested = '') {
  const directory = new URL(source + '/', root);
  const files = (await readdir(directory, {recursive:true,withFileTypes:true}))
    .filter(file => file.isFile())
    .map(file => relative(fileURLToPath(directory), join(file.parentPath,file.name)).split(sep).join('/'))
    .sort();
  const digest = createHash('sha256');
  for (const file of files) digest.update(file).update(await readFile(new URL(file,directory)));
  const base = `${destination}/${digest.digest('hex').slice(0,16)}/`;
  await mkdir(new URL(base,root),{recursive:true});
  await cp(directory,new URL(base + nested,root),{recursive:true});
  return base;
}

export async function versionWebAssetPaths(root) {
  return {
    assetBase: await fingerprintDirectory(root,'assets','web-assets','assets/'),
    canvasKitBaseUrl: await fingerprintDirectory(root,'canvaskit','web-renderer'),
  };
}
