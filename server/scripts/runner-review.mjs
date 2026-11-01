#!/usr/bin/env node
// Builds the local review page of the stage runner's wardrobe (docs/runner-review.html): every
// character with every role figure, its portrait, the run cycle and all poses cut from its sheet,
// the backdrops with their obstacle and collectible sheets, plus automatic checks of each sheet
// (size, poses touching their frame, stray pixels, wire points, foot line). Read-only on the
// catalog; the page loads the pictures by relative path, so it works from file:// without a server.
// Ratings live in the browser (localStorage) and are exported as a Markdown prompt.
//   cd server && npm run runner-review              (writes ../docs/runner-review.html)
//   node scripts/runner-review.mjs [--out <file.html>] [--serve [port]]
// The page works straight from file://; with --serve (npm run runner-review:serve) it is also
// served read-only from the repository on http://127.0.0.1:8787/, for browsers that block file://.
// Run it again whenever outfits, pictures or releases change; ratings stay in the browser, and a
// rated figure whose picture changed since is marked as such.
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import { runnerPoses } from '../src/runner-wardrobe.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const wardrobeDir = resolve(root, 'server/src/wardrobe');
const imageDir = resolve(wardrobeDir, 'images');
const gameDir = resolve(root, 'assets/games/stage_runner');
const template = resolve(here, 'runner-review.template.html');

const args = process.argv.slice(2);
const outArg = args.includes('--out') ? args[args.indexOf('--out') + 1] : null;
if (args.includes('--out') && !outArg) throw new Error('Usage: node scripts/runner-review.mjs [--out <file.html>]');
const out = resolve(outArg ? process.cwd() : root, outArg ?? 'docs/runner-review.html');
const serveAt = args.indexOf('--serve');
const port = serveAt >= 0 && /^\d+$/.test(args[serveAt + 1] ?? '') ? Number(args[serveAt + 1]) : 8787;

// The atlas layout of lib/features/games/ui/stage_runner_art.dart (enum RunnerSprite), x, y, w, h.
const sheet = { w: 1124, h: 577 };
const runnerFrames = {
  fly: [752, 386, 210, 130], dangle: [797, 4, 125, 165],
  runA: [4, 4, 172, 187], passA: [180, 4, 172, 187], runB: [621, 4, 172, 187], passB: [576, 386, 172, 187],
  cheer: [356, 4, 108, 195], crash: [152, 454, 207, 88],
};
const obstacleFrames = {
  crate: [4, 208, 150, 147], lamp: [158, 208, 92, 170], sandbag: [254, 208, 118, 140], flat: [961, 4, 159, 360],
  drum: [713, 208, 150, 150], truss: [152, 386, 420, 64], drop: [479, 4, 128, 176],
};
const pickupFrames = { rose: [376, 208, 89, 120], mask: [469, 208, 120, 87], star: [593, 208, 116, 120] };
// RunnerSprite.harness: where the flying wire meets the harness when the item names none.
const defaultHarness = { fly: [106, 42], dangle: [54, 28], cheer: [44, 68], runA: [83, 66], passA: [91, 66], runB: [91, 66], passB: [91, 66] };
for (const pose of runnerPoses) if (!runnerFrames[pose]) throw new Error(`Pose ${pose} of runner-wardrobe.mjs is missing in the review layout`);
// StageRunner / RunnerRules / RunnerSprite constants for a faithful preview.
const game = { stagePerPixel: 0.155 / 200, stridesPerUnit: 18, startSpeed: 0.55, maxSpeed: 2.4, runnerHeight: 0.11, floor: 0.86, ceiling: 0.07, runnerX: 0.4, viewWidth: 1.6 };

const alphaMin = 24, hardAlpha = 200;
const catalog = JSON.parse(readFileSync(resolve(wardrobeDir, 'catalog.json'), 'utf8'));
const releases = JSON.parse(readFileSync(resolve(wardrobeDir, 'releases.json'), 'utf8'));
const outDir = dirname(out);
const urlOf = path => relative(outDir, path).split(sep).join('/');

const fileCache = new Map();
/** Size, hash and alpha of a picture file, or null if it is missing. */
async function fileInfo(path) {
  if (fileCache.has(path)) return fileCache.get(path);
  let info = null;
  if (existsSync(path)) {
    const bytes = readFileSync(path);
    const meta = await sharp(bytes).metadata();
    info = { bytes, w: meta.width, h: meta.height, alpha: !!meta.hasAlpha, hash: createHash('sha256').update(bytes).digest('hex').slice(0, 12), kb: Math.round(bytes.length / 1024) };
  }
  fileCache.set(path, info);
  return info;
}

/** A picture reference for the page: its url (with the hash against stale caches), size and hash. */
async function picture(name, dir = imageDir) {
  if (!name) return null;
  const path = resolve(dir, name), info = await fileInfo(path);
  const shown = dir === imageDir ? `server/src/wardrobe/images/${name}` : urlOf(path).replace(/^(\.\.\/)+/, '');
  if (!info) return { file: name, path: shown, exists: false };
  const pic = { file: name, path: shown, url: `${urlOf(path)}?v=${info.hash}`, exists: true, w: info.w, h: info.h, alpha: info.alpha, hash: info.hash, kb: info.kb };
  // The file on disk, for the checks; not part of the page's data.
  return Object.defineProperty(pic, 'abs', { value: path, enumerable: false });
}

/**
 * Checks of a sheet in the atlas layout: per frame the content's box, how much of it touches each
 * edge of the frame (a hint at a cut-off pose), and the opaque pixels outside every frame
 * (`gap`, in the gaps between frames, grouped into boxes), plus content in the other layers'
 * frames (`foreign`, e.g. the default obstacles left in an old character sheet; never shown).
 */
async function analyse(path, frames, { otherFrames = {}, harness = null, skipStray = false } = {}) {
  const { data, info } = await sharp(readFileSync(path)).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  const W = info.width, H = info.height, A = (x, y) => data[(y * W + x) * 4 + 3];
  const inside = new Uint8Array(W * H);
  const result = { frames: {}, gap: { px: 0, boxes: [] }, foreign: 0, opaqueBackground: false };
  for (const [pose, [fx, fy, fw, fh]] of Object.entries(frames)) {
    const x0 = Math.max(0, fx), y0 = Math.max(0, fy), x1 = Math.min(W, fx + fw), y1 = Math.min(H, fy + fh);
    const edge = { top: 0, right: 0, bottom: 0, left: 0 }, hard = { top: 0, right: 0, bottom: 0, left: 0 };
    let px = 0, bx0 = Infinity, by0 = Infinity, bx1 = -1, by1 = -1;
    for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
      inside[y * W + x] = 1;
      const a = A(x, y);
      if (a <= alphaMin) continue;
      px++;
      if (x < bx0) bx0 = x; if (x > bx1) bx1 = x; if (y < by0) by0 = y; if (y > by1) by1 = y;
      const sides = [y === fy && 'top', y === fy + fh - 1 && 'bottom', x === fx && 'left', x === fx + fw - 1 && 'right'].filter(Boolean);
      for (const s of sides) { edge[s]++; if (a >= hardAlpha) hard[s]++; }
    }
    const frame = { px, edge, hard, clipped: x1 - x0 < fw || y1 - y0 < fh };
    if (px) frame.box = [bx0 - fx, by0 - fy, bx1 - bx0 + 1, by1 - by0 + 1];
    const at = harness?.[pose];
    if (at) {
      // Whether the wire point sits on the figure: any opaque pixel within 4 px of it.
      let on = false;
      for (let dy = -4; dy <= 4 && !on; dy++) for (let dx = -4; dx <= 4 && !on; dx++) {
        const x = fx + Math.round(at[0]) + dx, y = fy + Math.round(at[1]) + dy;
        if (x >= fx && y >= fy && x < fx + fw && y < fy + fh && x < W && y < H && A(x, y) > alphaMin) on = true;
      }
      frame.harnessOnFigure = on;
    }
    result.frames[pose] = frame;
  }
  for (const [fx, fy, fw, fh] of Object.values(otherFrames)) {
    for (let y = fy; y < Math.min(H, fy + fh); y++) for (let x = fx; x < Math.min(W, fx + fw); x++) {
      if (inside[y * W + x]) continue;
      inside[y * W + x] = 2;
      if (A(x, y) > alphaMin) result.foreign++;
    }
  }
  let opaque = 0;
  for (let i = 0; i < W * H; i++) if (data[i * 4 + 3] > alphaMin) opaque++;
  result.opaqueBackground = opaque / (W * H) > 0.9 || (A(0, 0) > alphaMin && A(W - 1, H - 1) > alphaMin);
  if (!skipStray) {
    // Stray pixels outside every frame, grouped on an 8 px grid into boxes.
    const cell = 8, cw = Math.ceil(W / cell), ch = Math.ceil(H / cell), cells = new Uint32Array(cw * ch);
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      if (inside[y * W + x] || A(x, y) <= alphaMin) continue;
      result.gap.px++;
      cells[Math.floor(y / cell) * cw + Math.floor(x / cell)]++;
    }
    const seen = new Uint8Array(cw * ch);
    for (let i = 0; i < cells.length; i++) {
      if (!cells[i] || seen[i]) continue;
      const stack = [i]; seen[i] = 1;
      let px = 0, cx0 = Infinity, cy0 = Infinity, cx1 = -1, cy1 = -1;
      while (stack.length) {
        const j = stack.pop(), cx = j % cw, cy = Math.floor(j / cw);
        px += cells[j];
        cx0 = Math.min(cx0, cx); cx1 = Math.max(cx1, cx); cy0 = Math.min(cy0, cy); cy1 = Math.max(cy1, cy);
        for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
          const nx = cx + dx, ny = cy + dy, k = ny * cw + nx;
          if (nx >= 0 && ny >= 0 && nx < cw && ny < ch && cells[k] && !seen[k]) { seen[k] = 1; stack.push(k); }
        }
      }
      const box = [cx0 * cell, cy0 * cell, (cx1 - cx0 + 1) * cell, (cy1 - cy0 + 1) * cell];
      // The nearest frame, to say where the stray pixels belong.
      let near = null, best = Infinity;
      for (const [pose, [fx, fy, fw, fh]] of Object.entries(frames)) {
        const dx = Math.max(fx - (box[0] + box[2]), box[0] - (fx + fw), 0), dy = Math.max(fy - (box[1] + box[3]), box[1] - (fy + fh), 0);
        if (Math.hypot(dx, dy) < best) { best = Math.hypot(dx, dy); near = pose; }
      }
      result.gap.boxes.push({ box, px, near });
    }
    result.gap.boxes.sort((a, b) => b.px - a.px);
    result.gap.boxes = result.gap.boxes.slice(0, 24);
  }
  return result;
}

const sideName = { top: 'oben', right: 'rechts', bottom: 'unten', left: 'links' };
const note = (level, text) => ({ level, text });

/** The notes of a sheet's checks, in German, as the page shows them. */
function sheetNotes(a, frames, { feet = false, bottomFree = [] } = {}) {
  const notes = [];
  if (a.opaqueBackground) notes.push(note('err', 'Kein transparenter Hintergrund (Sheet fast vollständig deckend)'));
  for (const [pose, f] of Object.entries(a.frames)) {
    if (f.px < 40) { notes.push(note('err', `${pose}: Pose leer`)); continue; }
    for (const side of ['top', 'left', 'right', 'bottom']) {
      if (side === 'bottom' && !bottomFree.includes(pose)) continue;
      const n = f.edge[side];
      if (n < 3) continue;
      notes.push(note(f.hard[side] >= 6 ? 'warn' : 'info', `${pose}: Inhalt berührt Rahmen ${sideName[side]} (${n} px${f.hard[side] ? `, ${f.hard[side]} deckend` : ''})`));
    }
    if (f.harnessOnFigure === false) notes.push(note('warn', `${pose}: Seilpunkt liegt nicht auf der Figur`));
  }
  if (a.gap.px >= 12) {
    const near = [...new Set(a.gap.boxes.filter(b => b.px >= 12).map(b => b.near))].join(', ');
    notes.push(note('warn', `Streupixel zwischen den Frames: ${a.gap.px} px in ${a.gap.boxes.length} Bereich(en)${near ? ` (bei ${near})` : ''}`));
  }
  if (feet) {
    const bottoms = ['runA', 'passA', 'runB', 'passB'].map(p => a.frames[p]?.box ? frames[p][3] - (a.frames[p].box[1] + a.frames[p].box[3]) : null).filter(v => v !== null);
    if (bottoms.length === 4) {
      const spread = Math.max(...bottoms) - Math.min(...bottoms);
      if (spread >= 3) notes.push(note('warn', `Fußlinie im Laufzyklus springt um ${spread} px (Abstand zum Frame-Boden ${bottoms.join('/')} px)`));
      else if (Math.min(...bottoms) >= 3) notes.push(note('info', `Füße schweben ${Math.min(...bottoms)} px über dem Frame-Boden`));
    }
  }
  if (a.foreign > 0) notes.push(note('info', 'Sheet enthält noch Grafiken des Standard-Atlas außerhalb der eigenen Frames (im Spiel unsichtbar)'));
  return notes;
}

/** The checks of a character sheet (or the default atlas). */
async function characterSheet(pic, harness, isDefault) {
  if (!pic?.exists) return null;
  const a = await analyse(pic.abs, runnerFrames, {
    otherFrames: { ...obstacleFrames, ...pickupFrames }, harness, skipStray: isDefault,
  });
  if (isDefault) a.foreign = 0;
  return a;
}

const rarityRank = new Map(catalog.rarities.map((r, i) => [r.id, i]));
const rarities = Object.fromEntries([
  ...catalog.rarities.map((r, i) => [r.id, { name: r.name, color: r.color, rank: i, ...(r.style ? { style: r.style } : {}) }]),
  ...(catalog.ensemble?.rarity ? [[catalog.ensemble.rarity.id, { name: catalog.ensemble.rarity.name, color: catalog.ensemble.rarity.color, rank: rarityRank.size }]] : []),
  ...(catalog.uniqueFigures?.rarity ? [[catalog.uniqueFigures.rarity.id, { name: catalog.uniqueFigures.rarity.name, color: catalog.uniqueFigures.rarity.color, rank: rarityRank.size + 1, style: catalog.uniqueFigures.rarity.style }]] : []),
]);
const ensembleRarity = catalog.ensemble?.rarity?.id;
const uniqueRarity = catalog.uniqueFigures?.rarity?.id;

const items = catalog.items;
const based = new Set(items.map(x => x.variantOf).filter(Boolean));
const defaultAtlas = await picture('atlas.webp', gameDir);
const defaultBackdrop = await picture('backdrop.webp', gameDir);
const referenced = new Set();

const characters = [];
for (const x of items.filter(i => i.kind === 'character')) {
  for (const key of ['image', 'portrait']) if (x[key]) referenced.add(x[key]);
  const own = await picture(x.image), portrait = await picture(x.portrait);
  const harness = { ...defaultHarness, ...(x.harness ?? {}) };
  const notes = [];
  // What the game draws: the own sheet if it is there in the right size, else the default atlas
  // (Engel Logge), tinted by `tint` (a placeholder tints the default art).
  let sheetPic = null, source = 'none';
  if (x.default) { sheetPic = defaultAtlas; source = 'default'; }
  else if (own?.exists) { sheetPic = own; source = 'own'; }
  else if (x.placeholder) { sheetPic = defaultAtlas; source = 'tinted-default'; }
  if (x.disabled) notes.push(note('info', own?.exists ? 'disabled: Bild vorhanden, Eintrag aber noch nicht freigegeben (Server blendet ihn aus)' : 'disabled: wartet auf sein Bild (Server blendet ihn aus)'));
  if (x.placeholder) notes.push(note('info', `Platzhalter: Standardfigur${x.tint ? ' mit Tönung' : ''}`));
  if (!x.default && !x.image && !x.placeholder) notes.push(note(x.disabled ? 'info' : 'err', 'Kein Bild eingetragen'));
  if (!x.default && x.image && !own?.exists) notes.push(note(x.disabled ? 'info' : 'err', `Bild fehlt: ${x.image}${x.disabled ? '' : ' (App zeigt Engel Logge)'}`));
  if (!x.default && x.portrait && !portrait?.exists) notes.push(note(x.disabled && !own?.exists ? 'info' : 'warn', `Porträt fehlt: ${x.portrait}`));
  if (!x.default && !x.portrait) notes.push(note('warn', 'Kein Porträt eingetragen'));
  if (own?.exists && (own.w !== sheet.w || own.h !== sheet.h)) notes.push(note('err', `Sheet hat ${own.w}×${own.h} statt ${sheet.w}×${sheet.h}: die App verwirft es und zeigt Engel Logge`));
  if (portrait?.exists && (portrait.w !== 512 || portrait.h !== 512)) notes.push(note('warn', `Porträt hat ${portrait.w}×${portrait.h} statt 512×512`));
  if (portrait?.exists && !portrait.alpha) notes.push(note('info', 'Porträt ohne Alphakanal'));
  let analysis = null;
  if (sheetPic?.exists) {
    analysis = await characterSheet(sheetPic, harness, source !== 'own');
    if (source === 'own') notes.push(...sheetNotes(analysis, runnerFrames, { feet: true, bottomFree: ['fly', 'dangle'] }));
  }
  characters.push({
    id: x.id, name: x.name, role: x.role, play: x.play, year: x.year,
    rarity: x.rarity ?? (x.reward ? ensembleRarity : null), importance: x.importance, personId: x.personId,
    variantOf: x.variantOf, base: based.has(x.id), default: !!x.default, disabled: !!x.disabled, placeholder: !!x.placeholder,
    tint: x.tint ?? null, unique: x.rarity === uniqueRarity, unlock: x.unlock ?? null,
    department: x.department ? [x.department].flat() : null, label: x.label, rarityReason: x.rarityReason,
    image: own, portrait, sheet: sheetPic, source, harness, customHarness: Object.keys(x.harness ?? {}), analysis, notes,
  });
}

// Character sheets in images/ that no catalog entry names (new art not entered yet).
for (const file of readdirSync(imageDir).filter(f => /^character-.+\.webp$/.test(f) && !f.endsWith('-portrait.webp')).sort()) {
  if (referenced.has(file)) continue;
  const own = await picture(file), portraitName = file.replace(/\.webp$/, '-portrait.webp');
  const portrait = existsSync(resolve(imageDir, portraitName)) ? await picture(portraitName) : null;
  const [, person, playSlug] = file.match(/^character-(.+?)(?:--(.+))?\.webp$/);
  const harness = { ...defaultHarness };
  const analysis = await characterSheet(own, harness, false);
  const notes = [note('warn', 'Bild liegt in images/, steht aber nicht im Katalog'), ...sheetNotes(analysis, runnerFrames, { feet: true, bottomFree: ['fly', 'dangle'] })];
  if (own.w !== sheet.w || own.h !== sheet.h) notes.push(note('err', `Sheet hat ${own.w}×${own.h} statt ${sheet.w}×${sheet.h}`));
  if (!portrait) notes.push(note('warn', `Porträt fehlt: ${portraitName}`));
  characters.push({
    id: `orphan:${file.replace(/\.webp$/, '')}`, orphan: true, name: person.replace(/^./, c => c.toUpperCase()), role: null, play: null, playSlug: playSlug ?? null,
    rarity: null, image: own, portrait, sheet: own, source: 'own', harness, customHarness: [], analysis, notes,
  });
}

// Backdrops with their obstacle and collectible sheets, and the obstacle sets.
const scenery = [];
for (const x of items.filter(i => i.kind === 'backdrop' || i.kind === 'obstacles')) {
  const notes = [];
  const isDefault = !!x.default;
  const backdrop = x.kind === 'backdrop' ? (isDefault ? defaultBackdrop : await picture(x.image)) : null;
  const obstaclesName = x.kind === 'backdrop' ? x.obstacles : x.image;
  const obstacles = isDefault ? defaultAtlas : await picture(obstaclesName);
  const collectibles = x.kind === 'backdrop' ? (isDefault ? defaultAtlas : await picture(x.collectibles)) : null;
  if (x.disabled) notes.push(note('info', 'disabled: wartet auf sein Bild (Server blendet ihn aus)'));
  if (x.placeholder) notes.push(note('info', `Platzhalter: Standard-Art${x.tint ? ' mit Tönung' : ''}`));
  if (x.kind === 'backdrop' && !isDefault && !x.placeholder) {
    if (!x.image) notes.push(note('err', 'Kein Hintergrundbild eingetragen'));
    else if (!backdrop?.exists) notes.push(note(x.disabled ? 'info' : 'err', `Bild fehlt: ${x.image}`));
    if (x.obstacles && !obstacles?.exists) notes.push(note('warn', `Hindernis-Sheet fehlt: ${x.obstacles}`));
    if (x.collectibles && !collectibles?.exists) notes.push(note('warn', `Sammel-Sheet fehlt: ${x.collectibles}`));
  }
  const analyses = {};
  if (obstacles?.exists) {
    if (!isDefault && (obstacles.w !== sheet.w || obstacles.h !== sheet.h)) notes.push(note('err', `Hindernis-Sheet hat ${obstacles.w}×${obstacles.h} statt ${sheet.w}×${sheet.h}`));
    analyses.obstacles = await analyse(obstacles.abs, obstacleFrames, { otherFrames: { ...runnerFrames, ...pickupFrames }, skipStray: isDefault });
    if (!isDefault && !x.placeholder) notes.push(...sheetNotes(analyses.obstacles, obstacleFrames, { bottomFree: ['truss', 'drop', 'lamp', 'sandbag'] }).map(n => ({ ...n, text: `Hindernisse · ${n.text}` })));
  }
  if (collectibles?.exists) {
    if (!isDefault && (collectibles.w !== sheet.w || collectibles.h !== sheet.h)) notes.push(note('err', `Sammel-Sheet hat ${collectibles.w}×${collectibles.h} statt ${sheet.w}×${sheet.h}`));
    analyses.collectibles = await analyse(collectibles.abs, pickupFrames, { otherFrames: { ...runnerFrames, ...obstacleFrames }, skipStray: isDefault });
    if (!isDefault) notes.push(...sheetNotes(analyses.collectibles, pickupFrames, { bottomFree: Object.keys(pickupFrames) }).map(n => ({ ...n, text: `Sammelobjekte · ${n.text}` })));
  }
  scenery.push({
    id: x.id, kind: x.kind, name: x.name, rarity: x.rarity ?? (x.reward ? ensembleRarity : null), default: isDefault, disabled: !!x.disabled,
    placeholder: !!x.placeholder, tint: x.tint ?? null, reward: !!x.reward, department: x.department ? [x.department].flat() : null,
    borderColor: x.borderColor ?? null, collectibleNames: x.collectibleNames ?? null, obstacleCrashLines: x.obstacleCrashLines ?? null, music: x.music ?? null,
    backdrop, obstacles, collectibles, analyses, notes,
  });
}

const data = {
  generatedAt: new Date().toISOString(), sheet, runnerFrames, obstacleFrames, pickupFrames, defaultHarness, game,
  poseOrder: ['runA', 'passA', 'runB', 'passB', 'fly', 'dangle', 'cheer', 'crash'], strides: ['runA', 'passA', 'runB', 'passB'],
  rarities, departments: Object.fromEntries((catalog.departments ?? []).map(d => [d.id, d.name])),
  releases: releases.map(r => ({ id: r.id, name: r.name, startsAt: r.startsAt, itemIds: r.itemIds ?? [], gatedItemIds: r.gatedItemIds ?? [], freeItemIds: r.freeItemIds ?? [] })),
  defaultBackdrop, characters, scenery,
};
const json = JSON.stringify(data).replace(/</g, '\\u003c').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');
const html = readFileSync(template, 'utf8').replace('/*__REVIEW_DATA__*/null', () => json);
writeFileSync(out, html);

const shown = characters.filter(c => c.sheet?.exists).length;
const plays = new Set(characters.map(c => c.play).filter(Boolean));
const flagged = characters.filter(c => c.notes.some(n => n.level !== 'info')).length;
console.log(`${relative(process.cwd(), out)}: ${characters.length} Figuren (${shown} mit Sheet, ${characters.filter(c => c.orphan).length} nicht im Katalog) aus ${plays.size} Stücken, ${scenery.length} Kulissen; ${flagged} Figuren mit Hinweisen.`);

if (serveAt >= 0) {
  // A small read-only static server over the repository, local only.
  const types = { '.html': 'text/html; charset=utf-8', '.webp': 'image/webp', '.png': 'image/png', '.jpg': 'image/jpeg', '.json': 'application/json', '.m4a': 'audio/mp4', '.mp3': 'audio/mpeg', '.css': 'text/css', '.js': 'text/javascript' };
  createServer((req, res) => {
    const path = resolve(root, '.' + decodeURIComponent(new URL(req.url, 'http://x').pathname));
    const type = types[path.slice(path.lastIndexOf('.'))];
    if (req.method !== 'GET' || !path.startsWith(root + sep) || !type || !existsSync(path)) { res.writeHead(404).end('Not found'); return; }
    res.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'no-cache' }).end(readFileSync(path));
  }).listen(port, '127.0.0.1', () => console.log(`http://127.0.0.1:${port}/${relative(root, out).split(sep).join('/')} (Strg+C beendet)`));
}
