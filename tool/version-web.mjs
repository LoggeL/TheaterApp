// Content-addressed entrypoints survive reverse proxies overriding cache headers.
import { readFile,writeFile,rename,access } from 'node:fs/promises';
import { createHash } from 'node:crypto';
const root=new URL('../build/web/',import.meta.url);
const hash=s=>createHash('sha256').update(s).digest('hex').slice(0,16);
const main=await readFile(new URL('main.dart.js',root));
const mainName=`main.${hash(main)}.dart.js`;
let bootstrap=await readFile(new URL('flutter_bootstrap.js',root),'utf8');
bootstrap=bootstrap.replaceAll('main.dart.js',mainName);
const bootName=`flutter_bootstrap.${hash(bootstrap)}.js`;
let index=await readFile(new URL('index.html',root),'utf8');
index=index.replace('src="flutter_bootstrap.js"',`src="${bootName}"`);
await writeFile(new URL(mainName,root),main);
await writeFile(new URL(bootName,root),bootstrap);
await writeFile(new URL('index.html',root),index);
await writeFile(new URL('release-assets.json',root),JSON.stringify({main:mainName,bootstrap:bootName})+'\n');
console.log(`Versioned web entrypoint: ${mainName}`);
