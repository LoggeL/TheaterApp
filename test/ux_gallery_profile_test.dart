import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:theater_app/core/models.dart';
import 'package:theater_app/ui/galleries.dart';
import 'package:theater_app/ui/profile.dart';

import 'app_controller_test.dart' show TestServer, signIn, jsonResponse;

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
);

JsonMap _asset(int index) => {
  'id': '$index',
  'path': '/galleries/g/assets/$index',
  'previewPath': '/galleries/g/assets/$index?size=preview',
  'type': 'IMAGE',
};

http.Response _image() =>
    http.Response.bytes(_png, 200, headers: {'content-type': 'image/png'});

void main() {
  testWidgets(
    'opening image 60 loads after build and retries the failed page without moving',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 3500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final server = TestServer();
      final offsets = <int>[];
      final missingPage = Completer<http.Response>();
      server.override = (request) {
        if (request.url.path.contains('/assets/')) {
          return Future.value(_image());
        }
        if (request.url.path.endsWith('/galleries/g/')) {
          final offset = int.parse(request.url.queryParameters['offset']!);
          offsets.add(offset);
          if (offset == 60 && offsets.where((n) => n == 60).length == 1) {
            return missingPage.future;
          }
          return Future.value(
            jsonResponse({
              'gallery': {'id': 'g', 'title': 'Testalbum'},
              'assets': offset == 0 ? List.generate(60, _asset) : [_asset(60)],
              'nextOffset': offset == 0 ? 60 : null,
              'total': 61,
            }),
          );
        }
        return null;
      };
      final controller = server.controller();
      await signIn(controller);
      await tester.pumpWidget(
        MaterialApp(
          home: GalleryScreen(
            controller: controller,
            gallery: const {'id': 'g', 'title': 'Testalbum'},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Aufnahme 60 öffnen'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.text('60 / 61'), findsOneWidget);
      expect(find.text('Weitere Bilder werden geladen …'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton && widget.tooltip == 'Nächstes Bild',
              ),
            )
            .onPressed,
        isNull,
      );
      missingPage.complete(
        jsonResponse({'error': 'Fotodienst nicht erreichbar'}, 503),
      );
      await tester.pumpAndSettle();
      expect(find.text('Fotodienst nicht erreichbar'), findsOneWidget);
      expect(find.text('60 / 61'), findsOneWidget);
      tester.widget<PageView>(find.byType(PageView)).controller!.jumpToPage(45);
      await tester.pumpAndSettle();
      expect(find.text('46 / 61'), findsOneWidget);
      expect(offsets, [0, 60]);
      await tester.tap(find.text('Erneut versuchen'));
      await tester.pumpAndSettle();
      expect(offsets, [0, 60, 60]);
      expect(find.text('Fotodienst nicht erreichbar'), findsNothing);
      expect(find.text('46 / 61'), findsOneWidget);
      tester.widget<PageView>(find.byType(PageView)).controller!.jumpToPage(59);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Nächstes Bild'));
      await tester.pumpAndSettle();
      expect(find.text('61 / 61'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'profile conflict retains the selected image and requires an explicit reload',
    (tester) async {
      final picked = Directory.systemTemp.createTempSync('theater-profile-');
      final file = File('${picked.path}/draft.png')..writeAsBytesSync(_png);
      const pickerChannel = MethodChannel('plugins.flutter.io/image_picker');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        pickerChannel,
        (call) async => call.method == 'pickImage' ? file.path : null,
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          pickerChannel,
          null,
        );
        picked.deleteSync(recursive: true);
      });
      final server = TestServer();
      var version = 0, uploads = 0;
      String? avatar;
      final saves = <JsonMap>[];
      server.override = (request) {
        final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
        if (path.endsWith('/snapshot')) {
          return Future.value(
            jsonResponse({
              ...server.data,
              'user': {
                ...server.user,
                'profileVersion': version,
                'avatarId': avatar,
              },
            }),
          );
        }
        if (path.endsWith('/media') && request.method == 'POST') {
          uploads++;
          return Future.value(jsonResponse({'id': 'draft-upload'}));
        }
        if (path.endsWith('/profile')) {
          final body = jsonMap(jsonDecode(request.body));
          saves.add(body);
          if (body['profileVersion'] != version) {
            return Future.value(
              jsonResponse({'error': 'Profil geändert. Bitte neu laden.'}, 409),
            );
          }
          avatar = body['avatarId'] as String?;
          version++;
          return Future.value(jsonResponse({'ok': true}));
        }
        if (path.contains('/media/')) return Future.value(_image());
        return null;
      };
      final controller = server.controller();
      await signIn(controller);
      await tester.pumpWidget(
        MaterialApp(home: ProfileScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Bild auswählen'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      final draft = tester.widget<Image>(find.byType(Image)).image;
      version = 1;
      avatar = 'other-device';
      await controller.refresh();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
      await tester.pumpAndSettle();
      expect(saves.single['profileVersion'], 0);
      expect(saves.single['avatarId'], 'draft-upload');
      expect(avatar, 'other-device');
      expect(
        find.textContaining('Bildentwurf bleibt erhalten'),
        findsOneWidget,
      );
      expect(tester.widget<Image>(find.byType(Image)).image, draft);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Speichern'),
            )
            .onPressed,
        isNull,
      );
      version = 2;
      avatar = 'latest-device';
      await tester.tap(find.text('Aktuellen Stand laden'));
      await tester.pumpAndSettle();
      expect(saves, hasLength(1));
      expect(avatar, 'latest-device');
      expect(tester.widget<Image>(find.byType(Image)).image, draft);
      await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
      await tester.pumpAndSettle();
      expect(saves.last['profileVersion'], 2);
      expect(saves.last['avatarId'], 'draft-upload');
      expect(uploads, 1);
      expect(avatar, 'draft-upload');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );

  testWidgets(
    'failed profile reload stays blocked and successful retry keeps a removal draft',
    (tester) async {
      final server = TestServer();
      var version = 0;
      String? avatar = 'original';
      var offline = false;
      final saves = <JsonMap>[];
      server.override = (request) {
        final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
        if (path.endsWith('/snapshot')) {
          return Future.value(
            offline
                ? jsonResponse({'error': 'Verbindung unterbrochen'}, 503)
                : jsonResponse({
                    ...server.data,
                    'user': {
                      ...server.user,
                      'profileVersion': version,
                      'avatarId': avatar,
                    },
                  }),
          );
        }
        if (path.endsWith('/profile')) {
          final body = jsonMap(jsonDecode(request.body));
          saves.add(body);
          if (body['profileVersion'] != version) {
            return Future.value(
              jsonResponse({'error': 'Profil geändert. Bitte neu laden.'}, 409),
            );
          }
          avatar = body['avatarId'] as String?;
          version++;
          return Future.value(jsonResponse({'ok': true}));
        }
        if (path.contains('/media/')) return Future.value(_image());
        return null;
      };
      final controller = server.controller();
      await signIn(controller);
      await tester.pumpWidget(
        MaterialApp(home: ProfileScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Entfernen'));
      await tester.pumpAndSettle();
      version = 1;
      avatar = 'other-device';
      await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
      await tester.pumpAndSettle();
      offline = true;
      await tester.tap(find.text('Aktuellen Stand laden'));
      await tester.pumpAndSettle();
      expect(find.text('Verbindung unterbrochen'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Speichern'),
            )
            .onPressed,
        isNull,
      );
      expect(saves, hasLength(1));
      offline = false;
      await tester.tap(find.text('Aktuellen Stand laden'));
      await tester.pumpAndSettle();
      expect(find.text('Entfernen'), findsNothing);
      expect(avatar, 'other-device');
      await tester.tap(find.widgetWithText(FilledButton, 'Speichern'));
      await tester.pumpAndSettle();
      expect(saves.last['profileVersion'], 1);
      expect(saves.last['avatarId'], isNull);
      expect(avatar, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    },
  );
}
