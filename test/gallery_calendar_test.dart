import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/ui/calendar.dart';
import 'package:theater_app/ui/events.dart';
import 'package:theater_app/ui/galleries.dart';
import 'package:theater_app/ui/profile.dart';
import 'package:theater_app/ui/theme.dart';
import 'app_controller_test.dart' show TestServer, signIn, jsonResponse;

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  test(
    'calendar uses Monday-first civil days across leap months and year boundaries',
    () {
      final feb = calendarDays(DateTime(2028, 2));
      expect(feb.length, 42);
      expect(feb.first.weekday, DateTime.monday);
      expect(feb.where((d) => d.month == 2).length, 29);
      final jan = calendarDays(DateTime(2027, 1));
      expect(jan.first, DateTime(2026, 12, 28));
    },
  );
  test(
    'multi-day rehearsals appear on every occupied day, end midnight is exclusive',
    () {
      final e = TheaterEvent(
        id: 'night',
        title: 'Night',
        startsAt: DateTime(2026, 10, 24, 20),
        endsAt: DateTime(2026, 10, 26),
      );
      expect(eventOnDay(e, DateTime(2026, 10, 24)), true);
      expect(eventOnDay(e, DateTime(2026, 10, 25)), true);
      expect(eventOnDay(e, DateTime(2026, 10, 26)), false);
    },
  );
  test(
    'JSON and binary API retain pagination query without placing bearer tokens in URLs',
    () async {
      final requests = <http.Request>[];
      final api = ApiClient(
        client: MockClient((r) async {
          requests.add(r);
          return r.url.path.contains('/assets/')
              ? http.Response.bytes(
                  [1, 2, 3],
                  200,
                  headers: {'content-type': 'image/jpeg'},
                )
              : jsonResponse({});
        }),
      );
      await api.request(
        'https://example.com',
        'GET',
        '/galleries/g?offset=60&limit=60',
        token: 'private-token',
      );
      final image = await api.binary(
        'https://example.com',
        '/galleries/g/assets/a?size=preview',
        token: 'private-token',
      );
      expect(requests.first.url.path, '/api/mobile/v1/galleries/g/');
      expect(requests.first.url.queryParameters['offset'], '60');
      expect(requests.last.url.queryParameters, {'size': 'preview'});
      expect(requests.last.headers['Authorization'], 'Bearer private-token');
      expect(image.mime, 'image/jpeg');
      expect(
        requests.every(
          (r) =>
              !r.followRedirects && !r.url.toString().contains('private-token'),
        ),
        true,
      );
      api.close();
    },
  );
  test('late image fetch cannot populate a new account session', () async {
    final server = TestServer(),
        gate = Completer<http.Response>(),
        requested = Completer<void>();
    server.override = (r) {
      if (r.url.path.contains('/media/')) {
        requested.complete();
        return gate.future;
      }
      return null;
    };
    final c = server.controller();
    await signIn(c);
    final pending = c.mediaBytes('/media/old');
    final rejected = expectLater(pending, throwsA(isA<ApiException>()));
    await requested.future;
    await c.logout();
    gate.complete(
      http.Response.bytes([1], 200, headers: {'content-type': 'image/webp'}),
    );
    await rejected;
    c.dispose();
  });
  for (final width in [320.0, 1100.0]) {
    testWidgets(
      'calendar and profile remain usable at $width px in dark theme',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = TestServer().controller();
        await signIn(c);
        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.dark),
            home: Scaffold(body: ScheduleScreen(controller: c)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Kalender'));
        await tester.pumpAndSettle();
        expect(find.byType(RehearsalCalendar), findsOneWidget);
        expect(find.byTooltip('Datum auswählen'), findsNothing);
        await tester.tap(find.byTooltip('Vorheriger Monat'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.dark),
            home: ProfileScreen(controller: c),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Bild auswählen'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  }
  testWidgets(
    'gallery pagination opens and advances lightbox without exposing forbidden downloads',
    (tester) async {
      final server = TestServer();
      final offsets = <String>[];
      final transparent = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
      );
      server.override = (r) {
        if (r.url.path.contains('/assets/')) {
          return Future.value(
            http.Response.bytes(
              transparent,
              200,
              headers: {'content-type': 'image/png'},
            ),
          );
        }
        if (r.url.path.endsWith('/galleries/g/')) {
          final offset = int.parse(r.url.queryParameters['offset']!);
          offsets.add('$offset');
          return Future.value(
            jsonResponse({
              'gallery': {'id': 'g', 'title': 'Probenbilder'},
              'assets': List.generate(
                offset == 0 ? 60 : 1,
                (i) => {
                  'id': '${offset + i}',
                  'path': '/galleries/g/assets/${offset + i}',
                  'previewPath':
                      '/galleries/g/assets/${offset + i}?size=preview',
                  'type': 'IMAGE',
                  'canDownload': false,
                },
              ),
              'nextOffset': offset == 0 ? 60 : null,
              'total': 61,
            }),
          );
        }
        return null;
      };
      final c = server.controller();
      await signIn(c);
      await tester.pumpWidget(
        MaterialApp(
          home: GalleryScreen(
            controller: c,
            gallery: const {'id': 'g', 'title': 'Probenbilder'},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('61 Aufnahmen'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Aufnahme 1 öffnen'));
      await tester.pumpAndSettle();
      expect(find.text('1 / 61'), findsOneWidget);
      expect(find.byTooltip('Original herunterladen'), findsNothing);
      await tester.tap(find.byTooltip('Nächstes Bild'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 61'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -8000));
      await tester.pumpAndSettle();
      expect(offsets, contains('60'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    },
  );
}
