import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/features/events/events.dart';
import 'package:theater_app/features/settings/settings.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

const _first =
    'https://app.example.invalid/api/calendar/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.ics';
const _second =
    'https://app.example.invalid/api/calendar/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB.ics';

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  group('feed links', () {
    test('webcal and Google links point to the same address', () {
      final feed = CalendarFeed.fromJson({
        'url': _first,
        'createdAt': '2026-10-19T12:00:00.000Z',
      });
      expect(feed.url.toString(), _first);
      expect(feed.createdAt, DateTime.utc(2026, 10, 19, 12));
      expect(feed.download.toString(), '$_first?download=1');
      expect(
        feed.webcal.toString(),
        'webcal://app.example.invalid/api/calendar/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.ics',
      );
      expect(feed.google.host, 'calendar.google.com');
      expect(feed.google.path, '/calendar/r');
      expect(feed.google.queryParameters['cid'], feed.webcal.toString());
      expect(
        feed.google.toString(),
        startsWith(
          'https://calendar.google.com/calendar/r?cid=webcal%3A%2F%2Fapp.example.invalid%2F',
        ),
      );
    });

    test('a missing or unusable address is an error', () {
      for (final url in ['', 'javascript:alert(1)', 'ftp://x/y.ics', '/x']) {
        expect(
          () => CalendarFeed.fromJson({'url': url}),
          throwsA(isA<ApiException>()),
          reason: url,
        );
      }
    });
  });

  group('settings', () {
    late List<Uri> opened;
    late bool accept;
    final originalOpener = calendarOpener;
    setUp(() {
      opened = [];
      accept = true;
      calendarOpener = (uri) async {
        opened.add(uri);
        return accept;
      };
    });
    tearDown(() => calendarOpener = originalOpener);

    Future<(AppController, List<String>)> open(
      WidgetTester tester, {
      bool supported = true,
      int status = 200,
      bool schedule = false,
      Size size = const Size(900, 1800),
      double textScale = 1,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final requests = <String>[];
      var url = _first;
      final server = TestServer();
      server.data['capabilities'] = {
        'features': [if (supported) 'calendarFeed'],
      };
      server.override = (http.Request request) {
        if (!request.url.path.contains('/calendar-feed')) return null;
        requests.add('${request.method} ${request.url.path}');
        if (status != 200) {
          return Future.value(
            jsonResponse({
              'error':
                  'Das Kalender-Abo ist auf diesem Server nicht eingerichtet.',
              'code': 'calendar_unavailable',
            }, status),
          );
        }
        if (request.url.path.contains('/reset')) url = _second;
        return Future.value(
          jsonResponse({'url': url, 'createdAt': '2026-10-19T12:00:00.000Z'}),
        );
      };
      final controller = server.controller();
      await signIn(controller);
      final devices = DeviceServices(
        controller,
        onTarget: (_) {},
        onForegroundMessage: (_) {},
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: schedule
              ? ScheduleScreen(controller: controller)
              : SettingsScreen(controller: controller, devices: devices),
        ),
      );
      await tester.pumpAndSettle();
      return (controller, requests);
    }

    Future<void> finish(WidgetTester tester, AppController controller) async {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    }

    testWidgets('the entry only shows when the server offers the feed', (
      tester,
    ) async {
      final (controller, requests) = await open(tester, supported: false);
      expect(find.text('Kalender abonnieren'), findsNothing);
      expect(requests, isEmpty);
      await finish(tester, controller);
    });

    testWidgets('adds the feed to Google, a webcal app or the clipboard', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final (controller, requests) = await open(tester);
      await tester.tap(find.text('Kalender abonnieren'));
      await tester.pumpAndSettle();
      expect(requests, ['GET /api/mobile/v1/calendar-feed/']);
      expect(find.textContaining('automatisch in deinem Kalender'), findsOne);
      expect(find.textContaining('abgesagt hast'), findsOne);
      expect(find.textContaining('Gib den Link nicht weiter'), findsOne);

      await tester.tap(find.text('In Google Kalender hinzufügen'));
      await tester.pumpAndSettle();
      expect(opened.single.host, 'calendar.google.com');
      expect(
        opened.single.queryParameters['cid'],
        _first.replaceFirst('https', 'webcal'),
      );

      opened.clear();
      await tester.tap(find.text('Abo hinzufügen'));
      await tester.pumpAndSettle();
      expect(opened.single.toString(), _first.replaceFirst('https', 'webcal'));

      await tester.tap(find.text('Link kopieren'));
      await tester.pumpAndSettle();
      expect(copied, _first);
      expect(find.text('Link kopiert'), findsOneWidget);

      // Nothing takes the address: the member learns how to go on.
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
          .clearSnackBars();
      accept = false;
      await tester.tap(find.text('Abo hinzufügen'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Keine Kalender-App'), findsOneWidget);

      opened.clear();
      accept = true;
      await tester.ensureVisible(find.text('Als Datei herunterladen'));
      await tester.tap(find.text('Als Datei herunterladen'));
      await tester.pumpAndSettle();
      expect(opened.single.toString(), '$_first?download=1');
      expect(find.textContaining('einmalige Kopie'), findsOneWidget);
      await finish(tester, controller);
    });

    testWidgets('a new link replaces the old one only after confirming', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final (controller, requests) = await open(tester);
      await tester.tap(find.text('Kalender abonnieren'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Link neu erzeugen'));
      await tester.tap(find.text('Link neu erzeugen'));
      await tester.pumpAndSettle();
      expect(find.textContaining('hört sofort auf zu funktionieren'), findsOne);
      await tester.tap(find.text('Abbrechen'));
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));

      await tester.tap(find.text('Link neu erzeugen'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Neu erzeugen'));
      await tester.pumpAndSettle();
      expect(requests.last, 'POST /api/mobile/v1/calendar-feed/reset/');
      expect(find.textContaining('Neuer Link erzeugt'), findsOneWidget);
      await tester.ensureVisible(find.text('Link kopieren'));
      await tester.tap(find.text('Link kopieren'));
      await tester.pumpAndSettle();
      expect(copied, _second);
      expect(find.text(_second), findsOneWidget);
      expect(find.text(_first), findsNothing);
      opened.clear();
      await tester.ensureVisible(find.text('Als Datei herunterladen'));
      await tester.tap(find.text('Als Datei herunterladen'));
      await tester.pumpAndSettle();
      expect(opened.single.toString(), '$_second?download=1');
      await finish(tester, controller);
    });

    testWidgets('a server without a public address explains it', (
      tester,
    ) async {
      final (controller, requests) = await open(tester, status: 409);
      await tester.tap(find.text('Kalender abonnieren'));
      await tester.pumpAndSettle();
      expect(find.text('Kalender-Link nicht geladen'), findsOneWidget);
      expect(find.textContaining('nicht eingerichtet'), findsOneWidget);
      await tester.tap(find.text('Erneut laden'));
      await tester.pumpAndSettle();
      expect(requests, hasLength(2));
      await finish(tester, controller);
    });

    for (final size in [const Size(320, 740), const Size(1360, 1000)]) {
      testWidgets('subscribe from the schedule menu at ${size.width}px', (
        tester,
      ) async {
        final (controller, requests) = await open(
          tester,
          schedule: true,
          size: size,
        );
        expect(find.text('Kalender abonnieren'), findsNothing);
        expect(requests, isEmpty);
        await tester.tap(find.byTooltip('Weitere Optionen'));
        await tester.pumpAndSettle();
        expect(find.text('Kalender abonnieren'), findsOneWidget);
        await tester.tap(find.text('Kalender abonnieren'));
        await tester.pumpAndSettle();
        expect(find.byType(CalendarFeedScreen), findsOneWidget);
        expect(requests, ['GET /api/mobile/v1/calendar-feed/']);
        await tester.ensureVisible(find.text('Abo hinzufügen'));
        await tester.tap(find.text('Abo hinzufügen'));
        await tester.pumpAndSettle();
        expect(
          opened.single.toString(),
          _first.replaceFirst('https', 'webcal'),
        );
        expect(tester.takeException(), isNull);
        await finish(tester, controller);
      });
    }

    testWidgets('schedule hides subscriptions for an older server', (
      tester,
    ) async {
      final (controller, requests) = await open(
        tester,
        schedule: true,
        supported: false,
      );
      await tester.tap(find.byTooltip('Weitere Optionen'));
      await tester.pumpAndSettle();
      expect(find.text('Kalender abonnieren'), findsNothing);
      expect(requests, isEmpty);
      await finish(tester, controller);
    });

    testWidgets(
      'instructions, link and download fit a narrow screen with large text',
      (tester) async {
        final (controller, _) = await open(
          tester,
          schedule: true,
          size: const Size(320, 740),
          textScale: 1.6,
        );
        await tester.tap(find.byTooltip('Weitere Optionen'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Kalender abonnieren'));
        await tester.pumpAndSettle();
        for (final title in [
          'iPhone, iPad und Mac',
          'Android und Google Kalender',
          'Outlook',
          'Thunderbird und andere Kalender',
        ]) {
          await tester.scrollUntilVisible(
            find.text(title),
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text(title));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.text(title));
          await tester.pumpAndSettle();
          await tester.tap(find.text(title));
          await tester.pumpAndSettle();
        }
        await tester.scrollUntilVisible(
          find.text('Link kopieren'),
          -250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(find.text(_first), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Als Datei herunterladen'),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Als Datei herunterladen'));
        expect(opened.single.toString(), '$_first?download=1');
        expect(tester.takeException(), isNull);
        await finish(tester, controller);
      },
    );
  });
}
