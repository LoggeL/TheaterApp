import test from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';

// Budgets for the wardrobe's pictures (server/src/wardrobe/images), which tool/optimize-sprites.py
// keeps small: the size the app needs, no metadata, at most so many bytes per kind. The budgets
// leave room for new art of the same kind, not for an unoptimised file (lossless or quality 100 is
// two to three times as large). Atlases must match the game's atlas exactly: the app checks that
// (`dressArt`) and falls back to the default figure otherwise.
const dir = new URL('../src/wardrobe/images/', import.meta.url);
const atlas = { width: 1124, height: 577, alpha: true };
const kinds = [
  { name: 'portrait', test: /^character-.+-portrait\.webp$/, width: 512, height: 512, alpha: true, budget: 80 << 10 },
  // Made from the portraits and backdrops by tool/optimize-sprites.py, for the grid and the reel.
  { name: 'thumbnail', test: /^character-.+-thumb\.webp$/, width: 384, height: 384, alpha: true, budget: 40 << 10 },
  { name: 'backdrop portrait', test: /^backdrop-.+-portrait\.webp$/, width: 384, height: 384, alpha: false, budget: 32 << 10 },
  { name: 'character atlas', test: /^character-.+\.webp$/, ...atlas, budget: 180 << 10 },
  { name: 'obstacle set', test: /^obstacles-.+\.webp$/, ...atlas, budget: 120 << 10 },
  { name: 'collectible set', test: /^collectibles-.+\.webp$/, ...atlas, budget: 40 << 10 },
  { name: 'backdrop', test: /^backdrop-.+\.webp$/, width: 1024, height: 603, alpha: false, budget: 64 << 10 },
  // The crate choice (`runnerCrateTargets`): closed and open crate on the same canvas, the open one
  // with its lid above, and a small sprite of the particles they throw.
  { name: 'crate particles', test: /^crate-.+-fx\.webp$/, width: 96, height: 96, alpha: true, budget: 8 << 10 },
  { name: 'crate', test: /^crate-.+\.webp$/, width: 512, height: 512, alpha: true, budget: 72 << 10 },
];

/** The chunks of a WebP file by tag and its canvas size. */
function webpInfo(bytes) {
  assert.equal(bytes.toString('latin1', 0, 4), 'RIFF');
  assert.equal(bytes.toString('latin1', 8, 12), 'WEBP');
  assert.equal(bytes.readUInt32LE(4) + 8, bytes.length, 'RIFF size');
  const chunks = new Map();
  let width = 0, height = 0;
  for (let at = 12; at + 8 <= bytes.length;) {
    const tag = bytes.toString('latin1', at, at + 4), size = bytes.readUInt32LE(at + 4), body = at + 8;
    if (tag === 'VP8X') { width = 1 + bytes.readUIntLE(body + 4, 3); height = 1 + bytes.readUIntLE(body + 7, 3); }
    else if (tag === 'VP8 ' && !width) { width = bytes.readUInt16LE(body + 6) & 0x3fff; height = bytes.readUInt16LE(body + 8) & 0x3fff; }
    else if (tag === 'VP8L' && !width) { const bits = bytes.readUInt32LE(body + 1); width = 1 + (bits & 0x3fff); height = 1 + ((bits >>> 14) & 0x3fff); }
    chunks.set(tag, size);
    at = body + size + (size & 1);
  }
  return { chunks, width, height };
}

test('every wardrobe picture is a WebP of its kind: right size, no metadata, within budget', () => {
  const files = readdirSync(dir).filter(name => !name.startsWith('.'));
  assert.ok(files.length > 0);
  const over = [];
  for (const name of files) {
    const kind = kinds.find(k => k.test.test(name));
    assert.ok(kind, `${name}: no known kind of picture (and so no budget)`);
    const bytes = readFileSync(new URL(name, dir));
    const { chunks, width, height } = webpInfo(bytes);
    assert.deepEqual([width, height], [kind.width, kind.height], `${name}: size of a ${kind.name}`);
    assert.equal(chunks.has('ALPH') || chunks.has('VP8L'), kind.alpha || chunks.has('VP8L'), `${name}: alpha of a ${kind.name}`);
    for (const meta of ['EXIF', 'ICCP', 'XMP ']) assert.ok(!chunks.has(meta), `${name}: ${meta.trim()} metadata (run tool/optimize-sprites.py)`);
    assert.ok([...chunks.keys()].every(tag => ['VP8X', 'ALPH', 'VP8 ', 'VP8L'].includes(tag)), `${name}: unexpected chunks ${[...chunks.keys()]}`);
    if (bytes.length > kind.budget) over.push(`${name}: ${bytes.length} B > ${kind.budget} B for a ${kind.name}`);
  }
  assert.deepEqual(over, [], 'over budget: run python3 tool/optimize-sprites.py --write');
});
