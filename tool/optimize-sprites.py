#!/usr/bin/env python3
"""Shrink the stage runner's pictures (WebP) without visible loss; never redraw or resize them.

  python3 tool/optimize-sprites.py            # dry run: what each file would become
  python3 tool/optimize-sprites.py --write    # overwrite the files that get smaller
  python3 tool/optimize-sprites.py --check    # exit 1 if a file is new or changed since it was optimized,
                                              # or a thumbnail no longer belongs to its source
  python3 tool/optimize-sprites.py --write server/src/wardrobe/images/obstacles-neu.webp

Needs cwebp/dwebp from libwebp (`brew install webp`) and Python with numpy and Pillow.

The generated cut-outs carry matting noise in their alpha channel: inside the figures a large
share of the pixels is 247..254 instead of 255, around them a faint veil of 1..4. Nobody can see
it, but it makes up most of the alpha channel's bytes. So the alpha is first snapped at both ends
(<= ALPHA_SNAP to 0, >= 255 - ALPHA_SNAP to 255: at most 1.6 % opacity, at most 4 of 255 levels on
any background); everything in between, i.e. every soft edge, stays exactly as it is.

Per file, the smallest of these wins (the file is left alone if none is smaller):
- `strip`: the same bitstreams without EXIF, ICC or XMP (and without an alpha channel that is
  opaque everywhere); pixel for pixel the same picture.
- `alpha`: the same lossy colour bitstream, bit for bit, with the snapped alpha channel packed
  losslessly with the best filter. Gate: SSIM and PSNR as below (no tile check: the change is at
  most ALPHA_SNAP levels everywhere, and SSIM on flat 32x32 tiles turns invisible ±1 into "loss").
- `lossy`: cwebp -m 6 from the snapped picture at the lowest quality that passes the gate, alpha
  lossless. Re-encoding an already lossy file rarely wins; it is for new, high-quality files.
- `lossless`: cwebp -lossless -z 9 of the snapped picture, if that is smaller (flat drawings).

Gate, against the file as it was, on the pixels visible in either: SSIM of the premultiplied RGB
(the picture over black) >= MIN_SSIM, for `lossy` also no 32x32 tile below MIN_TILE_SSIM, and a PSNR
>= MIN_PSNR over black and over white. Width, height and transparent borders stay as they are, so
atlas rects, harness points and hitboxes keep matching.

A lossy re-encode compared with a file that was itself re-encoded would lose a little each time,
so tool/optimize-sprites.json remembers the hash of every optimized file: those are skipped.

Unlike the rest, the small pictures of the wardrobe's cards are made here, from the committed
pictures, and never edited by hand (`--write` makes what is missing or out of date; a thumbnail is
only ever made from the optimized source, so it comes after the optimizing):
- `character-x-thumb.webp` from each `character-x-portrait.webp`, THUMB_SIZE² for the cards;
- `backdrop-x-portrait.webp` from each `backdrop-x.webp`, the middle of the stage, THUMB_SIZE².
Their manifest entries name the `source` and its hash (`sourceSha256`), so a re-exported portrait
whose thumbnail was forgotten fails `--check` (and server/test/runner-thumbs.test.mjs).
"""
import argparse
import hashlib
import io
import json
import os
import struct
import subprocess
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image

root = Path(__file__).resolve().parents[1]
IMAGES = root / 'server/src/wardrobe/images'
DIRS = ('assets/games/stage_runner', 'server/src/wardrobe/images')
MANIFEST = root / 'tool/optimize-sprites.json'
MIN_SSIM, MIN_TILE_SSIM, MIN_PSNR = 0.995, 0.98, 40.0
ALPHA_SNAP = 4
QUALITIES = (70, 74, 78, 81, 84, 86, 88, 90, 92, 94, 96)
# 384 covers the cards of about 130 pt on phones of a pixel ratio of 3; 320 is visibly softer there.
THUMB_SIZE, THUMB_QUALITY = 384, 80
LOSSY = ('-m', '6', '-alpha_q', '100', '-alpha_filter', 'best', '-alpha_method', '1', '-metadata', 'none')


# --- RIFF container -------------------------------------------------------------------------------

def chunks(data):
    if data[:4] != b'RIFF' or data[8:12] != b'WEBP':
        raise ValueError('not a WebP file')
    out, i = [], 12
    while i + 8 <= len(data):
        tag, size = data[i:i + 4], struct.unpack('<I', data[i + 4:i + 8])[0]
        out.append((tag.decode('latin1'), data[i + 8:i + 8 + size]))
        i += 8 + size + (size & 1)
    return out


def riff(parts):
    body = b''.join(tag.encode('latin1') + struct.pack('<I', len(p)) + p + (b'\0' if len(p) & 1 else b'') for tag, p in parts)
    return b'RIFF' + struct.pack('<I', 4 + len(body)) + b'WEBP' + body


def vp8x(width, height, alpha):
    return ('VP8X', bytes([0x10 if alpha else 0, 0, 0, 0]) + (width - 1).to_bytes(3, 'little') + (height - 1).to_bytes(3, 'little'))


def info(data):
    """Size, alpha, lossy, metadata chunks and the VP8 base quantizer of a WebP file."""
    parts = dict(chunks(data))
    meta = [t for t in ('EXIF', 'ICCP', 'XMP ') if t in parts]
    with Image.open(io.BytesIO(data)) as im:
        width, height = im.size
    base_q = None
    if 'VP8 ' in parts:
        # The base quantizer index (0 best … 127), from the frame header.
        base_q = _vp8_base_q(parts['VP8 '])
    return {'width': width, 'height': height, 'alpha': 'ALPH' in parts or ('VP8L' in parts and bool(parts['VP8L'][4] & 0x10)),
            'lossy': 'VP8 ' in parts, 'metadata': meta, 'baseQ': base_q}


def _vp8_base_q(vp8):
    """Reads the y_ac_qi of segment 0 from the first partition (RFC 6386 9.3, 9.6)."""
    bits = _BoolDecoder(vp8[10:])
    bits.read(1), bits.read(1)  # colour space, clamping
    if bits.read(1):  # segmentation
        update_map, update_data = bits.read(1), bits.read(1)
        if update_data:
            bits.read(1)  # absolute
            for bits_per_value in (7, 7, 7, 7, 6, 6, 6, 6):  # quantizers, filter levels
                if bits.read(1):
                    bits.signed(bits_per_value)
        if update_map:
            for _ in range(3):
                if bits.read(1):
                    bits.read(8)
    bits.read(1), bits.read(6), bits.read(3)  # filter type, level, sharpness
    if bits.read(1) and bits.read(1):  # lf deltas
        for _ in range(8):
            if bits.read(1):
                bits.signed(6)
    bits.read(2)  # partitions
    return bits.read(7)  # y_ac_qi, as webpinfo's "Base Q"


class _BoolDecoder:
    def __init__(self, data):
        self.data, self.pos, self.value, self.range, self.bits = data, 2, (data[0] << 8) | data[1], 255, 0

    def bit(self, prob=128):
        split = 1 + (((self.range - 1) * prob) >> 8)
        big = split << 8
        if self.value >= big:
            self.range -= split
            self.value -= big
            out = 1
        else:
            self.range = split
            out = 0
        while self.range < 128:
            self.value <<= 1
            self.range <<= 1
            self.bits += 1
            if self.bits == 8:
                self.bits = 0
                self.value |= self.data[self.pos] if self.pos < len(self.data) else 0
                self.pos += 1
        return out

    def read(self, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | self.bit()
        return v

    def signed(self, n):
        v = self.read(n)
        return -v if self.read(1) else v


# --- pictures and quality -------------------------------------------------------------------------

def decode(data):
    with Image.open(io.BytesIO(data)) as im:
        return np.asarray(im.convert('RGBA'))


def snap(rgba, t=ALPHA_SNAP):
    """[rgba] with its alpha snapped to 0 and 255 within [t] of them."""
    out = rgba.copy()
    a = out[..., 3]
    a[a <= t] = 0
    a[a >= 255 - t] = 255
    return out


def over(rgba, background):
    """The picture over a plain [background] (0 black, i.e. premultiplied, or 255 white)."""
    a = rgba[..., 3:].astype(np.float32) / 255
    return rgba[..., :3].astype(np.float32) * a + background * (1 - a)


def _blur(x):
    # Gaussian, sigma 1.5, 11 taps (as in the SSIM paper), separable, edges repeated.
    k = np.exp(-0.5 * (np.arange(-5, 6) / 1.5) ** 2)
    k /= k.sum()
    for axis in (0, 1):
        pad = [(0, 0)] * x.ndim
        pad[axis] = (5, 5)
        p = np.pad(x, pad, mode='edge')
        n = x.shape[axis]
        x = sum(w * np.take(p, range(i, i + n), axis=axis) for i, w in enumerate(k))
    return x


def quality(before, after):
    """SSIM of the premultiplied RGB (mean and worst 32x32 tile) and the worse PSNR over black and
    white, on the pixels visible in either picture."""
    mask = (before[..., 3] > 0) | (after[..., 3] > 0)
    if not mask.any():
        return {'ssim': 1.0, 'tile': 1.0, 'psnr': 99.0}
    a, b = over(before, 0), over(after, 0)
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    ma, mb = _blur(a), _blur(b)
    va, vb, cov = _blur(a * a) - ma * ma, _blur(b * b) - mb * mb, _blur(a * b) - ma * mb
    ssim = (((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))).mean(axis=2)
    h, w = mask.shape
    tiles = []
    for y in range(0, h, 32):
        for x in range(0, w, 32):
            m = mask[y:y + 32, x:x + 32]
            if m.mean() >= 0.3:
                tiles.append(ssim[y:y + 32, x:x + 32][m].mean())
    mse = max(float(((over(before, bg) - over(after, bg)) ** 2)[mask].mean()) for bg in (0, 255))
    return {'ssim': float(ssim[mask].mean()), 'tile': float(min(tiles, default=1.0)),
            'psnr': 99.0 if mse == 0 else float(10 * np.log10(255 ** 2 / mse))}


def passes(q, tiles=True):
    return q['ssim'] >= MIN_SSIM and q['psnr'] >= MIN_PSNR and (not tiles or q['tile'] >= MIN_TILE_SSIM)


def cwebp(png, *args):
    with tempfile.NamedTemporaryFile(suffix='.webp') as out:
        subprocess.run(['cwebp', '-quiet', *args, str(png), '-o', out.name], check=True)
        return Path(out.name).read_bytes()


def save_png(rgba, path):
    opaque = bool((rgba[..., 3] == 255).all())
    Image.fromarray(rgba[..., :3].copy() if opaque else rgba).save(path, compress_level=1)


# --- candidates -----------------------------------------------------------------------------------

SAME = {'ssim': 1.0, 'tile': 1.0, 'psnr': 99.0}


def optimize(path):
    data = path.read_bytes()
    pixels = decode(data)
    height, width = pixels.shape[:2]
    parts = dict(chunks(data))
    color = parts.get('VP8 ')
    found = {}

    def same(out, target):
        # The same picture on the visible pixels (alpha 0 hides any colour).
        after = decode(out)
        return np.array_equal(after[..., 3], target[..., 3]) and np.array_equal(over(after, 0), over(target, 0))

    def with_alpha(alpha):
        return riff([vp8x(width, height, True), ('ALPH', alpha), ('VP8 ', color)]) if alpha else riff([('VP8 ', color)])

    if color is not None:
        out = with_alpha(None if (pixels[..., 3] == 255).all() else parts.get('ALPH'))
        if same(out, pixels):
            found['strip'] = (out, SAME)
    elif 'VP8L' in parts:
        found['strip'] = (riff([('VP8L', parts['VP8L'])]), SAME)
    with tempfile.TemporaryDirectory() as tmp:
        png = Path(tmp) / 'in.png'
        snapped = snap(pixels)
        if color is not None and not np.array_equal(snapped, pixels):
            # Smaller snaps first only if the full one fails the gate.
            for t in sorted({ALPHA_SNAP, 2, 1}, reverse=True):
                target = snap(pixels, t)
                opaque = bool((target[..., 3] == 255).all())
                if not opaque:
                    save_png(target, png)
                out = with_alpha(None if opaque else dict(chunks(cwebp(png, '-q', '50', *LOSSY)))['ALPH'])
                q = quality(pixels, decode(out))
                if same(out, target) and passes(q, tiles=False):
                    found[f'alpha {t}'] = (out, q)
                    break
        save_png(snapped, png)
        # Lowest passing quality, by bisection (size and quality both grow with -q).
        lo, hi, best = 0, len(QUALITIES) - 1, None
        while lo <= hi:
            mid = (lo + hi) // 2
            out = cwebp(png, '-q', str(QUALITIES[mid]), *LOSSY)
            after = decode(out)
            q = quality(pixels, after)
            if np.array_equal(after[..., 3], snapped[..., 3]) and passes(q):
                best, hi = (QUALITIES[mid], out, q), mid - 1
            else:
                lo = mid + 1
        if best:
            found[f'lossy q{best[0]}'] = (best[1], best[2])
        lossless = cwebp(png, '-lossless', '-z', '9', '-alpha_filter', 'best', '-metadata', 'none')
        if len(lossless) < len(data) and same(lossless, snapped):
            q = quality(pixels, decode(lossless))
            if passes(q, tiles=False):
                found['lossless'] = (lossless, q)
    name, (out, q) = min(found.items(), key=lambda kv: len(kv[1][0]), default=(None, (data, None)))
    if len(out) >= len(data):
        name, out, q = None, data, None
    return {'path': str(path.relative_to(root)), 'before': len(data), 'after': len(out), 'method': name,
            'quality': q, 'width': width, 'height': height, 'info': info(data)}, out


def sha(data):
    return hashlib.sha256(data).hexdigest()


# --- generated pictures ---------------------------------------------------------------------------

def generated(names):
    """Name of each generated picture -> the name of the picture it is made from, of the files
    [names] (the wardrobe's folder)."""
    out = {}
    for name in names:
        if name.startswith('backdrop-'):
            if not name.endswith('-portrait.webp'):
                out[f'{name[:-len(".webp")]}-portrait.webp'] = name
        elif name.endswith('-portrait.webp'):
            out[f'{name[:-len("-portrait.webp")]}-thumb.webp'] = name
    return out


def small_picture(path):
    """The source at [path] as a square of THUMB_SIZE: a portrait as it is, a backdrop its middle."""
    with Image.open(path) as im:
        rgba = im.convert('RGBA')
    width, height = rgba.size
    side = min(width, height)
    left, top = (width - side) // 2, (height - side) // 2
    # Pillow scales RGBA premultiplied: no fringe from the colours under the transparent pixels.
    square = rgba.crop((left, top, left + side, top + side)).resize((THUMB_SIZE, THUMB_SIZE), Image.Resampling.LANCZOS)
    with tempfile.TemporaryDirectory() as tmp:
        png = Path(tmp) / 'in.png'
        save_png(snap(np.asarray(square)), png)
        return cwebp(png, '-q', str(THUMB_QUALITY), *LOSSY)


def outdated(manifest, folder=None):
    """What is wrong with the generated pictures: (name, source or None, reason), by [manifest]."""
    folder = folder or IMAGES
    names = sorted(p.name for p in folder.glob('*.webp'))
    made = generated(names)
    key = lambda name: f'{folder.relative_to(root)}/{name}'
    out = []
    for name, source in sorted(made.items()):
        entry = manifest.get(key(name), {})
        if name not in names:
            out.append((name, source, 'missing'))
        elif entry.get('sourceSha256') != sha((folder / source).read_bytes()):
            out.append((name, source, f'older than {source}'))
        elif entry.get('sha256') != sha((folder / name).read_bytes()):
            out.append((name, source, 'changed by hand'))
    # Left behind by a picture that is gone.
    for name in names:
        if 'source' in manifest.get(key(name), {}) and name not in made:
            out.append((name, None, f"{manifest[key(name)]['source']} is gone"))
    return out


def make(job):
    name, source = job
    return name, source, small_picture(IMAGES / source)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('files', nargs='*', type=Path, help='WebP files (default: all of ' + ', '.join(DIRS) + ')')
    parser.add_argument('--write', action='store_true', help='overwrite files that get smaller and record them')
    parser.add_argument('--check', action='store_true', help='only list files not optimized yet or generated pictures out of date; exit 1 if any')
    parser.add_argument('--force', action='store_true', help='also re-encode files already optimized (loses a little each time)')
    parser.add_argument('--report', type=Path, help='write the per-file results as JSON here')
    args = parser.parse_args()
    files = [f.resolve() for f in args.files] or sorted(p for d in DIRS for p in (root / d).iterdir() if p.suffix in ('.webp', '.png'))
    manifest = json.loads(MANIFEST.read_text()) if MANIFEST.exists() else {}
    rel = lambda p: str(p.relative_to(root))
    for p in files:
        if p.suffix == '.png':
            print(f'{rel(p)}: PNG, please convert to WebP first (and point the catalog at it)', file=sys.stderr)
    # Generated pictures are encoded once, from their source: never optimized on top.
    made = {IMAGES / name for name in generated(p.name for p in IMAGES.glob('*.webp'))}
    made |= {root / k for k, v in manifest.items() if 'source' in v}
    files = [p for p in files if p.suffix == '.webp' and p not in made]
    todo = [p for p in files if args.force or manifest.get(rel(p), {}).get('sha256') != sha(p.read_bytes())]
    if args.check:
        for p in todo:
            print(f'not optimized: {rel(p)}')
        stale = outdated(manifest)
        for name, _, why in stale:
            print(f'generated picture out of date: {name} ({why}); run --write')
        return 1 if todo or stale else 0
    reports = []
    with ProcessPoolExecutor(max_workers=os.cpu_count()) as pool:
        for report, out in pool.map(optimize, todo):
            reports.append(report)
            q = report['quality']
            print(f"{report['path']}: {report['before']} -> {report['after']} B ({report['method'] or 'unchanged'}"
                  + (f", SSIM {q['ssim']:.4f}, tile {q['tile']:.4f}, PSNR {q['psnr']:.1f} dB" if q else '') + ')')
            if args.write:
                path = root / report['path']
                if out != path.read_bytes():
                    path.write_bytes(out)
                manifest[report['path']] = {'sha256': sha(out), 'before': report['before'], 'method': report['method'] or 'unchanged',
                                            **({'ssim': round(q['ssim'], 5)} if q else {})}
    if args.write:
        jobs = [(name, source) for name, source, _ in outdated(manifest) if source]
        with ProcessPoolExecutor(max_workers=os.cpu_count()) as pool:
            for name, source, out in pool.map(make, jobs):
                (IMAGES / name).write_bytes(out)
                manifest[f'{IMAGES.relative_to(root)}/{name}'] = {
                    'sha256': sha(out), 'source': f'{IMAGES.relative_to(root)}/{source}',
                    'sourceSha256': sha((IMAGES / source).read_bytes()), 'method': f'{THUMB_SIZE}px q{THUMB_QUALITY}'}
                print(f'{name}: {len(out)} B from {source}')
        for name, source, _ in outdated(manifest):
            if source is None:
                (IMAGES / name).unlink()
                print(f'{name}: removed')
        for key in [k for k in manifest if not (root / k).exists()]:
            del manifest[key]
        # One line per file, so a diff shows which pictures changed.
        lines = [f'  {json.dumps(k)}: {json.dumps(v)}' for k, v in sorted(manifest.items())]
        MANIFEST.write_text('{\n' + ',\n'.join(lines) + '\n}\n')
    if args.report:
        args.report.write_text(json.dumps(reports, indent=1))
    before, after = sum(r['before'] for r in reports), sum(r['after'] for r in reports)
    print(f'{len(reports)} files: {before} -> {after} B' + (f' ({100 * (before - after) / before:.1f} % less)' if before else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
