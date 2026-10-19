import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/events/events.dart';

import 'app_controller_test.dart' show TestServer, fixedNow, signIn;

TheaterEvent _at(String id, String place, {int day = 1}) => TheaterEvent(
  id: id,
  title: 'Termin $id',
  place: place,
  startsAt: DateTime(2026, 9, day, 19),
);

String _iso(Duration offset) => fixedNow.add(offset).toUtc().toIso8601String();

JsonMap _event(String id, String place, {int days = 3}) => {
  'id': id,
  'title': 'Probe $id',
  'startsAt': _iso(Duration(days: days)),
  'endsAt': _iso(Duration(days: days, hours: 2)),
  'place': place,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  group('known places', () {
    test('are unique, most used first, then most recent', () {
      final places = knownPlaces([
        _at('1', 'Kolpingheim', day: 1),
        _at('2', 'Stadthalle', day: 5),
        _at('3', 'kolpingheim ', day: 2),
        _at('4', 'Fotostudio Weber', day: 9),
        _at('5', '  ', day: 9),
        _at('6', 'Stadthalle', day: 3),
        _at('7', 'Kolpingheim', day: 4),
      ]);
      expect(places, ['Kolpingheim', 'Stadthalle', 'Fotostudio Weber']);
    });

    test('keep the spelling used most recently', () {
      final places = knownPlaces([
        _at('1', 'stadthalle', day: 1),
        _at('2', 'Stadthalle Ramsen', day: 2),
        _at('3', 'Stadthalle', day: 8),
      ]);
      expect(places, ['Stadthalle', 'Stadthalle Ramsen']);
    });

    test('suggest matches at the start first and skip exact matches', () {
      const known = ['Kolpingheim', 'Alte Halle', 'Hallenbad', 'Stadthalle'];
      expect(placeSuggestions(known, 'hall'), [
        'Hallenbad',
        'Alte Halle',
        'Stadthalle',
      ]);
      expect(placeSuggestions(known, 'kolpingheim'), isEmpty);
      expect(placeSuggestions(known, ''), known);
      expect(placeSuggestions(known, '', limit: 2), hasLength(2));
    });

    test('map search uses geo links on Android and the web elsewhere', () {
      final android = mapSearchUris('Kolpingheim, Ramsen', android: true);
      expect(android.first.toString(), 'geo:0,0?q=Kolpingheim%2C%20Ramsen');
      expect(android.last.host, 'www.google.com');
      expect(android.last.queryParameters, {
        'api': '1',
        'query': 'Kolpingheim, Ramsen',
      });
      final web = mapSearchUris(' Stadthalle ', android: false);
      expect(web, hasLength(1));
      expect(web.single.queryParameters['query'], 'Stadthalle');
    });
  });

  group('event detail', () {
    late List<Uri> opened;
    late bool accept;
    setUp(() {
      opened = [];
      accept = true;
      placeOpener = (uri) async {
        opened.add(uri);
        return accept && uri.scheme != 'geo';
      };
    });
    tearDown(() => placeOpener = (_) async => false);

    Future<AppController> open(WidgetTester tester, String place) async {
      await tester.binding.setSurfaceSize(const Size(500, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final server = TestServer()..data['events'] = [_event('a', place)];
      final controller = server.controller();
      await signIn(controller);
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: EventDetailScreen(controller: controller, eventId: 'a'),
        ),
      );
      await tester.pumpAndSettle();
      return controller;
    }

    Future<void> finish(WidgetTester tester, AppController controller) async {
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    }

    testWidgets('a tap on the place searches it on a map', (tester) async {
      final controller = await open(tester, 'Stadthalle Ramsen');
      await tester.tap(find.text('Stadthalle Ramsen'));
      await tester.pumpAndSettle();
      expect(opened.last.host, 'www.google.com');
      expect(opened.last.queryParameters['query'], 'Stadthalle Ramsen');
      await finish(tester, controller);
    });

    testWidgets('Android tries the maps app before the web', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final controller = await open(tester, 'Stadthalle');
      await tester.tap(find.text('Stadthalle'));
      await tester.pumpAndSettle();
      expect(opened.map((u) => u.scheme), ['geo', 'https']);
      debugDefaultTargetPlatformOverride = null;
      await finish(tester, controller);
    });

    testWidgets('other platforms open the web map directly', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final controller = await open(tester, 'Stadthalle');
      await tester.tap(find.text('Stadthalle'));
      await tester.pumpAndSettle();
      expect(opened.map((u) => u.scheme), ['https']);
      debugDefaultTargetPlatformOverride = null;
      await finish(tester, controller);
    });

    testWidgets('says so when no map opens', (tester) async {
      accept = false;
      final controller = await open(tester, 'Stadthalle');
      await tester.tap(find.text('Stadthalle'));
      await tester.pumpAndSettle();
      expect(
        find.text('Die Karte konnte nicht geöffnet werden.'),
        findsOneWidget,
      );
      await finish(tester, controller);
    });

    testWidgets('the address can be copied', (tester) async {
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
      final controller = await open(tester, 'Stadthalle Ramsen');
      await tester.longPress(find.text('Stadthalle Ramsen'));
      await tester.pumpAndSettle();
      expect(copied, 'Stadthalle Ramsen');
      expect(find.text('Adresse kopiert'), findsOneWidget);
      expect(opened, isEmpty);

      copied = null;
      await tester.tap(find.byTooltip('Adresse kopieren'));
      await tester.pumpAndSettle();
      expect(copied, 'Stadthalle Ramsen');
      await finish(tester, controller);
    });

    testWidgets('an unknown place is plain text', (tester) async {
      final controller = await open(tester, '');
      expect(find.text('Ort wird noch bekannt gegeben'), findsOneWidget);
      expect(find.byTooltip('Adresse kopieren'), findsNothing);
      await tester.tap(find.text('Ort wird noch bekannt gegeben'));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      await finish(tester, controller);
    });
  });

  testWidgets('the editor suggests places of earlier events', (tester) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer()
      ..data['events'] = [
        _event('a', 'Stadthalle Ramsen', days: 2),
        _event('b', 'Stadthalle Ramsen', days: 4),
        _event('c', 'Alte Stadtmühle', days: 6),
        _event('d', 'Kolpingheim', days: 8),
      ];
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: EventEditorScreen(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('event-place-field'));
    await tester.ensureVisible(field);
    await tester.tap(field);
    await tester.enterText(field, 'stadt');
    await tester.pumpAndSettle();
    final options = find.descendant(
      of: find.byType(ListTile),
      matching: find.textContaining('Stadt'),
    );
    expect(tester.widgetList<Text>(options).map((t) => t.data), [
      'Stadthalle Ramsen',
      'Alte Stadtmühle',
    ]);
    await tester.tap(find.widgetWithText(ListTile, 'Alte Stadtmühle'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller!.text, 'Alte Stadtmühle');
    expect(find.widgetWithText(ListTile, 'Stadthalle Ramsen'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
