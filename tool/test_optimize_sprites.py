#!/usr/bin/env python3
"""Tests for the generated pictures of tool/optimize-sprites.py."""
import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path

from PIL import Image

spec = importlib.util.spec_from_file_location('optimize_sprites', Path(__file__).with_name('optimize-sprites.py'))
sprites = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sprites)


class Generated(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(setattr, sprites, 'root', sprites.root)
        sprites.root = Path(self.tmp.name)
        self.folder = sprites.root / 'images'
        self.folder.mkdir()

    def write(self, name, data):
        (self.folder / name).write_bytes(data)

    def entry(self, made, source):
        return {'sha256': sprites.sha((self.folder / made).read_bytes()), 'source': f'images/{source}',
                'sourceSha256': sprites.sha((self.folder / source).read_bytes())}

    def outdated(self, manifest):
        return [(name, why) for name, _, why in sprites.outdated(manifest, self.folder)]

    def test_names(self):
        self.assertEqual(sprites.generated([
            'character-a-portrait.webp', 'character-a.webp', 'character-a-thumb.webp',
            'backdrop-b.webp', 'backdrop-b-portrait.webp', 'crate-c.webp',
        ]), {'character-a-thumb.webp': 'character-a-portrait.webp', 'backdrop-b-portrait.webp': 'backdrop-b.webp'})

    def test_a_portrait_changed_after_its_thumbnail_is_found(self):
        self.write('character-a-portrait.webp', b'one')
        self.assertEqual(self.outdated({}), [('character-a-thumb.webp', 'missing')])
        self.write('character-a-thumb.webp', b'small')
        manifest = {'images/character-a-thumb.webp': self.entry('character-a-thumb.webp', 'character-a-portrait.webp')}
        self.assertEqual(self.outdated(manifest), [])
        self.write('character-a-portrait.webp', b'two')
        self.assertEqual(self.outdated(manifest), [('character-a-thumb.webp', 'older than character-a-portrait.webp')])

    def test_a_thumbnail_touched_by_hand_is_found(self):
        self.write('character-a-portrait.webp', b'one')
        self.write('character-a-thumb.webp', b'small')
        manifest = {'images/character-a-thumb.webp': self.entry('character-a-thumb.webp', 'character-a-portrait.webp')}
        self.write('character-a-thumb.webp', b'other')
        self.assertEqual(self.outdated(manifest), [('character-a-thumb.webp', 'changed by hand')])

    def test_a_thumbnail_without_its_portrait_is_found(self):
        self.write('character-a-thumb.webp', b'small')
        manifest = {'images/character-a-thumb.webp': {'source': 'images/character-a-portrait.webp'}}
        self.assertEqual(self.outdated(manifest), [('character-a-thumb.webp', 'images/character-a-portrait.webp is gone')])

    @unittest.skipUnless(shutil.which('cwebp'), 'needs cwebp')
    def test_small_pictures_are_squares_of_the_middle(self):
        # Black, with a white middle: only the middle stays.
        stage = Image.new('RGB', (1024, 603))
        stage.paste((255, 255, 255), (211, 0, 813, 603))
        stage.save(self.folder / 'stage.png')
        data = sprites.small_picture(self.folder / 'stage.png')
        self.write('small.webp', data)
        with Image.open(self.folder / 'small.webp') as small:
            self.assertEqual(small.size, (sprites.THUMB_SIZE, sprites.THUMB_SIZE))
            self.assertGreater(min(small.convert('L').getpixel((x, 192)) for x in (4, 192, 379)), 200)


if __name__ == '__main__':
    unittest.main()
