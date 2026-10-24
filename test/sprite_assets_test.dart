import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:theater_app/features/games/ui/stage_runner_art.dart';
import 'package:theater_app/features/games/ui/stage_runner_look.dart';

import 'app_controller_test.dart' show TestServer, signIn;

/// The chunks of a WebP file by their tag, and the canvas size.
({Map<String, int> chunks, int width, int height}) _webp(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
  expect(tag(0), 'RIFF');
  expect(tag(8), 'WEBP');
  expect(data.getUint32(4, Endian.little) + 8, bytes.length);
  final chunks = <String, int>{};
  var width = 0, height = 0;
  for (var at = 12; at + 8 <= bytes.length;) {
    final size = data.getUint32(at + 4, Endian.little), body = at + 8;
    switch (tag(at)) {
      case 'VP8X':
        width = 1 + (data.getUint32(body + 4, Endian.little) & 0xFFFFFF);
        height = 1 + (data.getUint32(body + 7, Endian.little) & 0xFFFFFF);
      case 'VP8 ' when width == 0:
        width = data.getUint16(body + 6, Endian.little) & 0x3FFF;
        height = data.getUint16(body + 8, Endian.little) & 0x3FFF;
      case 'VP8L' when width == 0:
        final bits = data.getUint32(body + 1, Endian.little);
        width = 1 + (bits & 0x3FFF);
        height = 1 + ((bits >> 14) & 0x3FFF);
    }
    chunks[tag(at)] = size;
    at = body + size + (size & 1);
  }
  return (chunks: chunks, width: width, height: height);
}

void main() {
  // The game's own pictures, optimised with tool/optimize-sprites.py. The
  // budgets leave room for new art of the same kind, not for an unoptimised
  // file (lossless or quality 100 is two to three times as large).
  group('bundled pictures of the stage runner', () {
    final cases = {
      'assets/games/stage_runner/atlas.webp': (1124, 577, true, 200 << 10),
      'assets/games/stage_runner/backdrop.webp': (1024, 603, false, 64 << 10),
    };
    for (final MapEntry(key: path, value: (w, h, alpha, budget))
        in cases.entries) {
      test('$path: size, no metadata, within its budget', () {
        final bytes = File(path).readAsBytesSync();
        final file = _webp(bytes);
        expect((file.width, file.height), (w, h));
        expect(file.chunks.containsKey('ALPH'), alpha);
        for (final meta in ['EXIF', 'ICCP', 'XMP ']) {
          expect(file.chunks, isNot(contains(meta)), reason: meta);
        }
        expect(bytes.length, lessThanOrEqualTo(budget));
      });
    }

    test('every sprite lies inside the atlas', () {
      for (final sprite in RunnerSprite.values) {
        expect(
          ui.Rect.fromLTWH(0, 0, 1124, 577).intersect(sprite.rect),
          sprite.rect,
          reason: sprite.name,
        );
      }
    });
  });

  group('portraits are decoded only as large as shown', () {
    test('the size follows the screen', () {
      expect(WardrobePictures.portraitPixels(1), 200);
      expect(WardrobePictures.portraitPixels(2), 400);
      // Phones from 2.56 on get the whole 512² portrait.
      expect(WardrobePictures.portraitPixels(2.75), greaterThan(512));
    });

    test('a large picture is scaled down, a small one never up', () async {
      WardrobePictures.clear();
      addTearDown(WardrobePictures.clear);
      final picture = await createTestImage(width: 512, height: 256);
      final png = (await picture.toByteData(format: ui.ImageByteFormat.png))!;
      final server = TestServer();
      server.data['capabilities'] = {
        'features': ['stageRunner', 'runnerUnlocks'],
      };
      server.override = (request) {
        if (!request.url.path.contains('/games/runner/skins/')) return null;
        return Future.value(
          http.Response.bytes(
            png.buffer.asUint8List(),
            200,
            headers: {'content-type': 'image/png'},
          ),
        );
      };
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      final small = (await WardrobePictures.load(
        controller,
        '/games/runner/skins/a-portrait.webp',
        maxPixels: 200,
      ))!;
      expect((small.width, small.height), (200, 100));
      expect(WardrobePictures.bytes, 200 * 100 * 4);
      final whole = (await WardrobePictures.load(
        controller,
        '/games/runner/skins/b-portrait.webp',
        maxPixels: 600,
      ))!;
      expect((whole.width, whole.height), (512, 256));
      final plain = (await WardrobePictures.load(
        controller,
        '/games/runner/skins/c.webp',
      ))!;
      expect((plain.width, plain.height), (512, 256));
    });
  });
}
