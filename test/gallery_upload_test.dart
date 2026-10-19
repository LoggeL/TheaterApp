import 'dart:async';
import 'dart:convert';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/features/galleries/galleries.dart';

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

http.Response _busy({String? retryAfter, String code = 'busy'}) =>
    http.Response(
      jsonEncode({
        'error': 'Es werden gerade andere Bilder verarbeitet.',
        'code': code,
      }),
      429,
      headers: {'content-type': 'application/json', 'retry-after': ?retryAfter},
    );

List<XFile> _files(int count) => [
  for (var i = 0; i < count; i++) XFile.fromData(_png, name: 'bild-$i.png'),
];

Future<void> _open(
  WidgetTester tester,
  TestServer server, {
  Future<List<XFile>> Function()? pick,
  Future<void> Function(Duration)? wait,
}) async {
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  await tester.pumpWidget(
    MaterialApp(
      home: GalleryScreen(
        controller: controller,
        gallery: const {'id': 'g', 'title': 'Testalbum'},
        pickImages: pick,
        wait: wait,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('Retry-After is read in seconds only', () {
    expect(ApiClient.retryAfterOf('3'), const Duration(seconds: 3));
    expect(ApiClient.retryAfterOf(' 0 '), Duration.zero);
    expect(ApiClient.retryAfterOf('Wed, 21 Oct 2015 07:28:00 GMT'), isNull);
    expect(ApiClient.retryAfterOf(null), isNull);
  });

  testWidgets(
    'a busy server is waited out with Retry-After and backoff, the rest is kept',
    (tester) async {
      final server = TestServer();
      final answers = <http.Response Function()>[
        () => _busy(retryAfter: '3'),
        () => jsonResponse({'id': 'a'}),
        () => _busy(),
        () => _busy(),
        () => _busy(),
        () => _busy(),
        () => _busy(),
      ];
      var uploads = 0;
      final waits = <Duration>[];
      server.override = (request) {
        final path = request.url.path;
        if (path.endsWith('/media/') && request.method == 'POST') {
          final answer = uploads < answers.length
              ? answers[uploads]()
              : jsonResponse({'id': 'x'});
          uploads++;
          return Future.value(answer);
        }
        if (path.endsWith('/galleries/g/')) {
          return Future.value(
            jsonResponse({
              'gallery': {'id': 'g', 'title': 'Testalbum'},
              'assets': [],
              'nextOffset': null,
              'total': 0,
            }),
          );
        }
        return null;
      };
      await _open(
        tester,
        server,
        pick: () async => _files(3),
        wait: (pause) async => waits.add(pause),
      );
      await tester.tap(find.text('Bilder hinzufügen'));
      await tester.pumpAndSettle();
      // The first image needed a second try after 3 s (Retry-After); the
      // second gave up after five attempts with 1, 2, 4 and 8 s pauses.
      expect(waits, const [
        Duration(seconds: 3),
        Duration(seconds: 1),
        Duration(seconds: 2),
        Duration(seconds: 4),
        Duration(seconds: 8),
      ]);
      expect(uploads, 7);
      expect(
        find.textContaining('1 Bild hinzugefügt · 2 Bilder nicht hochgeladen'),
        findsOneWidget,
      );
      expect(find.text('2 Bilder wurden nicht hochgeladen.'), findsOneWidget);

      // The kept rest goes up now, with progress counted from the rest.
      final second = Completer<http.Response>();
      uploads = 0;
      server.override = (request) {
        final path = request.url.path;
        if (path.endsWith('/media/') && request.method == 'POST') {
          uploads++;
          return uploads == 2
              ? second.future
              : Future.value(jsonResponse({'id': 'x'}));
        }
        if (path.endsWith('/galleries/g/')) {
          return Future.value(
            jsonResponse({
              'gallery': {'id': 'g', 'title': 'Testalbum'},
              'assets': [_asset(0), _asset(1), _asset(2)],
              'nextOffset': null,
              'total': 3,
            }),
          );
        }
        return null;
      };
      await tester.tap(find.text('Rest erneut hochladen'));
      await tester.pump();
      await tester.pump();
      expect(find.text('1 von 2 …'), findsOneWidget);
      expect(find.text('Rest erneut hochladen'), findsNothing);
      second.complete(jsonResponse({'id': 'y'}));
      await tester.pumpAndSettle();
      expect(uploads, 2);
      expect(find.textContaining('2 Bilder hinzugefügt.'), findsOneWidget);
      expect(find.text('Rest erneut hochladen'), findsNothing);
      expect(find.text('Bilder hinzufügen'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the daily limit stops at once and a rejected file does not stop the rest',
    (tester) async {
      final server = TestServer();
      final statuses = [400, 200, 429];
      var uploads = 0;
      final waits = <Duration>[];
      server.override = (request) {
        final path = request.url.path;
        if (path.endsWith('/media/') && request.method == 'POST') {
          final status = statuses[uploads++];
          return Future.value(
            status == 429
                ? _busy(code: 'upload_limit')
                : status == 400
                ? jsonResponse({'error': 'Bitte JPEG, PNG oder WebP.'}, 400)
                : jsonResponse({'id': 'x'}),
          );
        }
        if (path.endsWith('/galleries/g/')) {
          return Future.value(
            jsonResponse({
              'gallery': {'id': 'g', 'title': 'Testalbum'},
              'assets': [],
              'nextOffset': null,
              'total': 0,
            }),
          );
        }
        return null;
      };
      await _open(
        tester,
        server,
        pick: () async => _files(4),
        wait: (pause) async => waits.add(pause),
      );
      await tester.tap(find.text('Bilder hinzufügen'));
      await tester.pumpAndSettle();
      expect(uploads, 3);
      expect(waits, isEmpty);
      expect(
        find.textContaining(
          '1 Bild hinzugefügt · 1 Bild abgelehnt · 2 Bilder nicht hochgeladen',
        ),
        findsOneWidget,
      );
      expect(find.text('2 Bilder wurden nicht hochgeladen.'), findsOneWidget);
      await tester.tap(find.text('Verwerfen'));
      await tester.pumpAndSettle();
      expect(find.text('Rest erneut hochladen'), findsNothing);
      expect(uploads, 3);
    },
  );

  testWidgets(
    'after a failed page scrolling stays quiet until the retry button is used',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = TestServer();
      final offsets = <int>[];
      var failing = true;
      server.override = (request) {
        if (request.url.path.contains('/assets/')) {
          return Future.value(
            http.Response.bytes(
              _png,
              200,
              headers: {'content-type': 'image/png'},
            ),
          );
        }
        if (request.url.path.endsWith('/galleries/g/')) {
          final offset = int.parse(request.url.queryParameters['offset']!);
          offsets.add(offset);
          if (offset == 60 && failing) {
            return Future.value(
              jsonResponse({'error': 'Fotodienst nicht erreichbar'}, 503),
            );
          }
          return Future.value(
            jsonResponse({
              'gallery': {'id': 'g', 'title': 'Testalbum'},
              'assets': offset == 0
                  ? List.generate(60, _asset)
                  : List.generate(10, (i) => _asset(60 + i)),
              'nextOffset': offset == 0 ? 60 : null,
              'total': 70,
            }),
          );
        }
        return null;
      };
      await _open(tester, server);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -8000));
      await tester.pumpAndSettle();
      expect(offsets, [0, 60]);
      expect(find.text('Fotodienst nicht erreichbar'), findsOneWidget);
      for (var i = 0; i < 4; i++) {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
        await tester.pumpAndSettle();
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -3000),
        );
        await tester.pumpAndSettle();
      }
      expect(offsets, [0, 60]);
      failing = false;
      await tester.tap(find.text('Erneut laden'));
      await tester.pumpAndSettle();
      expect(offsets, [0, 60, 60]);
      expect(find.text('Fotodienst nicht erreichbar'), findsNothing);
      expect(find.bySemanticsLabel('Aufnahme 70 öffnen'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
