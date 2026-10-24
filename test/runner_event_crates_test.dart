import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/games/data/wardrobe_api.dart';
import 'package:theater_app/features/games/ui/crate_opening.dart';
import 'package:theater_app/features/games/ui/event_crates_card.dart';
import 'package:theater_app/features/games/ui/stage_runner_sound.dart';
import 'package:theater_app/features/games/ui/wardrobe_screen.dart';
import 'package:theater_app/features/rehearsal/rehearsal.dart';
import 'package:theater_app/features/today/today.dart';

import 'app_controller_test.dart'
    show TestServer, fixedNow, jsonResponse, signIn;

// Termin-Kiste: a private crate for the own commitment to an event.

class _Sound implements RunnerSound {
  final _enabled = ValueNotifier(true);
  @override
  ValueListenable<bool> get enabled => _enabled;
  @override
  void setEnabled(bool on) => _enabled.value = on;
  @override
  void prepare() {}
  @override
  void play(RunnerSfx sfx) {}
  @override
  void startMusic() {}
  @override
  void stopMusic() {}
  @override
  void dispose() => _enabled.dispose();
}

const _features = [
  'stageRunner',
  'runnerUnlocks',
  'runnerDupes',
  'runnerEventCrates',
];

JsonMap _item(String id, String kind, String name, {bool isDefault = false}) =>
    {
      'id': id,
      'kind': kind,
      'name': name,
      'rarity': 'hell',
      'rarities': ['hell'],
      if (isDefault) 'default': true,
    };

final _start = DateTime.utc(2026, 10, 31, 16);

/// A wardrobe as the server sends it, with [events] Termin-Kisten waiting.
JsonMap _wardrobeJson({List<JsonMap>? events}) {
  final crates =
      events ??
      [
        {
          'eventId': 'probe',
          'title': 'Probe Akt 2',
          'startsAt': _start.toIso8601String(),
        },
      ];
  return {
    'progress': {
      'meters': 100,
      'earned': 0,
      'opened': 0,
      'crates': 0,
      'previousAt': 0,
      'nextAt': 2000,
      'poolSize': 2,
      'dupes': true,
      'eventCrates': crates.length,
    },
    'catalog': {
      'kinds': ['character', 'backdrop', 'obstacles', 'fx'],
      'rarities': [
        {'id': 'hell', 'name': 'Hellblau', 'color': '#5E98D9', 'weight': 45},
      ],
      'items': [
        _item('c0', 'character', 'Engel Logge', isDefault: true),
        _item('b0', 'backdrop', 'Bühnenwand', isDefault: true),
        _item('o0', 'obstacles', 'Requisitenlager', isDefault: true),
        _item('f0', 'fx', 'Ohne Effekt', isDefault: true),
        _item('maren', 'character', 'Maren'),
        _item('anton', 'character', 'Anton'),
      ],
    },
    'owned': ['c0', 'b0', 'o0', 'f0'],
    'selected': {
      'character': 'c0',
      'backdrop': 'b0',
      'obstacles': 'o0',
      'fx': 'f0',
    },
    'eventCrates': crates,
  };
}

String _path(http.Request request) =>
    request.url.path.replaceFirst(RegExp(r'/$'), '');

Future<(AppController, TestServer)> _signedIn(
  Future<http.Response>? Function(http.Request) handle, {
  List<String> features = _features,
}) async {
  final server = TestServer();
  server.data['capabilities'] = {'features': features};
  server.override = handle;
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  return (controller, server);
}

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  group('data', () {
    test('the wardrobe lists the Termin-Kisten and counts them as waiting', () {
      final w = Wardrobe.fromJson(_wardrobeJson());
      expect(w.eventCrates.single.eventId, 'probe');
      expect(w.eventCrates.single.title, 'Probe Akt 2');
      expect(w.eventCrates.single.startsAt, _start.toLocal());
      expect(w.progress.eventCrates, 1);
      expect(w.progress.waiting, 1);
      expect(crateWaiting(w), isTrue);
      expect(
        eventCrateTitle(w.eventCrates.single),
        'Termin-Kiste · Probe Akt 2 · Sa. 31. Oktober',
      );
      expect(eventCrateTitle(null), 'Termin-Kiste');
      // Older servers send nothing of it.
      final old = Wardrobe.fromJson(
        _wardrobeJson(events: [])..remove('eventCrates'),
      );
      expect(old.eventCrates, isEmpty);
      expect(crateWaiting(old), isFalse);
    });

    test('an opening from a Termin-Kiste names its event', () {
      final outcome = CrateOutcome.fromJson({
        'type': 'new',
        'crate': 'event',
        'event': {'eventId': 'probe', 'title': 'Probe Akt 2'},
      });
      expect(outcome.event?.title, 'Probe Akt 2');
      expect(CrateOutcome.fromJson({'crate': 'costume'}).event, isNull);
    });
  });

  group('feature', () {
    testWidgets('only servers announcing runnerEventCrates offer them', (
      tester,
    ) async {
      final (on, _) = await _signedIn((_) => null);
      expect(eventCratesAvailable(on), isTrue);
      final (off, _) = await _signedIn(
        (_) => null,
        features: const ['stageRunner', 'runnerUnlocks', 'runnerDupes'],
      );
      expect(eventCratesAvailable(off), isFalse);
      const granted = ActionResult(ActionOutcome.synced, {
        'eventCrate': {'pending': true, 'player': true},
      });
      expect(
        on.eventCrateNotice(granted),
        'Danke für deine Zusage! Nach dem Termin wartet eine Termin-Kiste auf dich.',
      );
      expect(off.eventCrateNotice(granted), isNull);
      // Not for people who never found the hidden game, nor without a crate.
      expect(
        on.eventCrateNotice(
          const ActionResult(ActionOutcome.synced, {
            'eventCrate': {'pending': true, 'player': false},
          }),
        ),
        isNull,
      );
      expect(
        on.eventCrateNotice(
          const ActionResult(ActionOutcome.synced, {
            'eventCrate': {'granted': true, 'player': true},
          }),
        ),
        isNull,
      );
      expect(
        on.eventCrateNotice(const ActionResult(ActionOutcome.queued)),
        isNull,
      );
    });
  });

  group('commitment', () {
    for (final player in [true, false]) {
      testWidgets(
        player
            ? 'a commitment that brings a Termin-Kiste says thanks'
            : 'people who do not play just see the saved commitment',
        (tester) async {
          tester.view.physicalSize = const Size(390, 1400);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final start = fixedNow.add(const Duration(days: 2));
          late TestServer server;
          final (controller, s) = await _signedIn((request) {
            if (!_path(request).endsWith('/actions')) return null;
            final body = jsonMap(jsonDecode(request.body));
            server.actionBodies.add(body);
            (server.data['attendanceByEvent'] as Map)[body['eventId']] =
                body['status'];
            return Future.value(
              jsonResponse({
                'ok': true,
                'response': {'status': body['status']},
                'eventCrate': {'pending': true, 'player': player},
              }),
            );
          });
          server = s;
          server.data['events'] = [
            {
              'id': 'next',
              'title': 'Szenenprobe',
              'startsAt': start.toUtc().toIso8601String(),
              'endsAt': start
                  .add(const Duration(hours: 2))
                  .toUtc()
                  .toIso8601String(),
              'place': 'Kolpingheim',
            },
          ];
          server.data['attendanceByEvent'] = {};
          await controller.refresh();
          await tester.pumpWidget(
            MaterialApp(
              theme: StageTheme.build(Brightness.light),
              home: Scaffold(
                body: ListenableBuilder(
                  listenable: controller,
                  builder: (_, _) => TodayScreen(
                    controller: controller,
                    onPlan: () {},
                    onScripts: () {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Bin dabei'));
          await tester.pumpAndSettle();
          expect(server.actionBodies.last['status'], 'yes');
          expect(
            find.text(
              'Danke für deine Zusage! Nach dem Termin wartet eine Termin-Kiste auf dich.',
            ),
            player ? findsOneWidget : findsNothing,
          );
          expect(
            find.text('Zusage gespeichert'),
            player ? findsNothing : findsOneWidget,
          );
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  });

  group('wardrobe', () {
    testWidgets('a Termin-Kiste shows its event and opens with the unboxing', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final opened = <JsonMap>[];
      final (controller, _) = await _signedIn((request) {
        final path = _path(request);
        if (path.endsWith('/games/runner/wardrobe')) {
          return Future.value(
            jsonResponse(
              _wardrobeJson(
                events: [
                  {
                    'eventId': 'probe',
                    'title': 'Probe Akt 2',
                    'startsAt': _start.toIso8601String(),
                  },
                  {
                    'eventId': 'auffuehrung',
                    'title': 'Premiere',
                    'startsAt': _start
                        .add(const Duration(days: 7))
                        .toIso8601String(),
                  },
                ],
              ),
            ),
          );
        }
        if (path.endsWith('/games/runner/crates')) {
          opened.add(jsonMap(jsonDecode(request.body)));
          final after = _wardrobeJson(
            events: [
              {'eventId': 'probe', 'title': 'Probe Akt 2'},
            ],
          )..['owned'] = ['c0', 'b0', 'o0', 'f0', 'maren'];
          return Future.value(
            jsonResponse({
              'item': _item('maren', 'character', 'Maren'),
              'reel': List.filled(56, 'maren'),
              'winnerIndex': 48,
              'outcome': {
                'type': 'new',
                'crate': 'event',
                'event': {'eventId': 'auffuehrung', 'title': 'Premiere'},
              },
              'wardrobe': after,
            }),
          );
        }
        return path.contains('/games/runner/')
            ? Future.value(jsonResponse({}))
            : null;
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: WardrobeScreen(controller: controller, sound: _Sound()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('2 Termin-Kisten bereit'), findsOneWidget);
      expect(find.text('Probe Akt 2 · Sa. 31. Oktober'), findsOneWidget);
      expect(find.text('Premiere · Sa. 7. November'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('event-crate-auffuehrung')),
          matching: find.text('Öffnen'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(opened.single, {
        'dupes': true,
        'crate': 'event',
        'eventId': 'auffuehrung',
      });
      expect(find.text('Termin-Kiste · Premiere'), findsOneWidget);
      // Skip to the result: one more is left.
      await tester.tapAt(const Offset(400, 200));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Nächste Kiste (1)'), findsOneWidget);
      // The next one is the earliest left, without a chosen event.
      await tester.tap(find.text('Nächste Kiste (1)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(opened.last, {'dupes': true, 'crate': 'event'});
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('without the feature the wardrobe shows no Termin-Kisten', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (controller, _) = await _signedIn(
        (request) => _path(request).contains('/games/runner/')
            ? Future.value(jsonResponse(_wardrobeJson()))
            : null,
        features: const ['stageRunner', 'runnerUnlocks', 'runnerDupes'],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: WardrobeScreen(controller: controller, sound: _Sound()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const ValueKey('runner-event-crates')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('the opening page names a chosen Termin-Kiste at once', (
      tester,
    ) async {
      final (controller, _) = await _signedIn((_) => null);
      final w = Wardrobe.fromJson(_wardrobeJson());
      await tester.pumpWidget(
        MaterialApp(
          home: CrateOpeningPage(
            controller: controller,
            wardrobe: w,
            sound: _Sound(),
            event: true,
            eventCrate: w.eventCrates.single,
            open: () => Future.delayed(
              const Duration(seconds: 1),
              () => throw const FormatException('egal'),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Die Termin-Kiste geht auf …'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('attendance', () {
    test('the reminder to record the attendance opens its check-in', () {
      final link = AppTarget.fromWebUri(
        Uri.parse(
          'https://app.example.invalid/?target=${Uri.encodeComponent('theaterapp://app/events/probe?intent=checkin')}',
        ),
      );
      expect(
        [link?.kind, link?.id, link?.intent],
        ['events', 'probe', 'checkin'],
      );
      expect(
        AppTarget.fromData({'eventId': 'probe', 'intent': 'checkin'})?.intent,
        'checkin',
      );
      expect(
        AppTarget.fromData({'eventId': 'probe', 'intent': 'x'})?.intent,
        isNull,
      );
    });

    testWidgets('the check-in marks attendance adopted from the commitments', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final server = TestServer();
      server.data['capabilities'] = {'features': _features};
      server.data['events'] = [
        {
          'id': 'rehearsal',
          'title': 'Szenenprobe',
          'startsAt': '2026-09-10T17:00:00Z',
          'endsAt': '2026-09-10T19:00:00Z',
        },
      ];
      server.data['memberAttendanceByEvent'] = {
        'rehearsal': {'1': 'yes', '2': 'yes'},
      };
      server.data['checkinsByEvent'] = {
        'rehearsal': {'1': true, '2': true},
      };
      server.data['autoCheckinsByEvent'] = {
        'rehearsal': [2],
      };
      server.data['checkinVersions'] = {'rehearsal:1': 1, 'rehearsal:2': 1};
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: AttendanceEditorScreen(
            controller: controller,
            event: controller.events.single,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('attendance-auto')), findsOneWidget);
      final robin = find.ancestor(
        of: find.text('Robin Spielmann'),
        matching: find.byType(Card),
      );
      expect(
        find.descendant(
          of: robin,
          matching: find.textContaining('automatisch übernommen'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('automatisch übernommen'), findsOneWidget);
      // Corrected by hand: no longer adopted.
      await tester.tap(
        find.descendant(
          of: find.descendant(
            of: robin,
            matching: find.byType(SegmentedButton<bool>),
          ),
          matching: find.text('Fehlt'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('automatisch übernommen'), findsNothing);
      server.offline = true;
      await tester.tap(
        find.widgetWithText(FilledButton, 'Änderungen speichern'),
      );
      await tester.pumpAndSettle();
      expect(server.actionBodies.last['action'], 'checkin.save');
      // Waiting in the outbox, the correction already counts as recorded.
      expect(controller.autoCheckins('rehearsal'), isEmpty);
      expect(find.byKey(const ValueKey('attendance-auto')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
