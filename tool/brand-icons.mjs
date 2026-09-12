// Resize the official, unchanged logo onto platform-safe white icon canvases.
import { createRequire } from 'node:module';
import { readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { createHash } from 'node:crypto';
const root = resolve(import.meta.dirname, '..');
const sharp = createRequire(resolve(root, 'server/package.json'))('sharp');
const logo = await readFile(resolve(root, 'assets/brand/kolpingtheater-ramsen.png'));
if (createHash('sha256').update(logo).digest('hex') !== 'c22912bb9397371f959f23fd9caf75880be49ec2e639b1b2c81508c0a9626fab') throw Error('Official logo differs from verified source');
async function icon(path, size, fraction = .84, transparent = false) {
  const image = await sharp(logo).resize(Math.round(size * fraction), Math.round(size * fraction), { fit: 'contain', background: '#ffffff' }).png().toBuffer();
  const dest = resolve(root, path); await mkdir(dirname(dest), { recursive: true });
  await sharp({ create: { width: size, height: size, channels: 4, background: transparent ? '#ffffff00' : '#ffffff' } }).composite([{ input: image, gravity: 'centre' }]).png().toFile(dest);
}
for (const [density, size] of Object.entries({ mdpi: 48, hdpi: 72, xhdpi: 96, xxhdpi: 144, xxxhdpi: 192 })) await icon(`android/app/src/main/res/mipmap-${density}/ic_launcher.png`, size);
await rm(resolve(root, 'android/app/src/main/res/drawable/ic_launcher_foreground.xml'), { force: true });
await icon('android/app/src/main/res/drawable-nodpi/ic_launcher_foreground.png', 432, .53, true);
for (const path of ['android/app/src/main/res/values/colors.xml', 'android/app/src/main/res/values-night/colors.xml']) {
  try { const s = await readFile(resolve(root, path), 'utf8'); await writeFile(resolve(root, path), s.replace(/(<color name="launcher_background">)[^<]+/, '$1#FFFFFF')); } catch (e) { if (e.code !== 'ENOENT') throw e; }
}
const adaptive = resolve(root, 'android/app/src/main/res/mipmap-anydpi-v33/ic_launcher.xml');
await writeFile(adaptive, (await readFile(adaptive, 'utf8')).replace(/\s*<monochrome[^>]+\/>/, ''));
for (const size of [192, 512]) { await icon(`web/icons/Icon-${size}.png`, size); await icon(`web/icons/Icon-maskable-${size}.png`, size, .65); }
await icon('web/favicon.png', 64);
const ios = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
for (const i of JSON.parse(await readFile(resolve(root, ios, 'Contents.json'), 'utf8')).images) if (i.filename) await icon(`${ios}/${i.filename}`, Math.round(parseFloat(i.size) * parseFloat(i.scale)));
console.log('Official Kolpingtheater logo prepared for web, Android and iOS.');
