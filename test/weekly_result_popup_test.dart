import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/shell/app_shell.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/features/games/ui/weekly_result_popup.dart';

import 'app_controller_test.dart'
    show TestServer, jsonResponse, signIn, fixedNow;

void main() {
  setUpAll(() => initializeDateFormatting('de'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'app-wide result waits for explicit dismissal and retries failed ack',
    (tester) async {
      final server = TestServer();
      server.data['capabilities'] = {
        'features': ['stageRunner', 'runnerWeekly', 'runnerWeeklyResults'],
      };
      var seen = 0, reads = 0;
      server.override = (request) {
        if (request.url.path
            .replaceFirst(RegExp(r'/$'), '')
            .endsWith('/weekly/results')) {
          reads++;
          return Future.value(
            jsonResponse({
              'results': seen > 1
                  ? []
                  : [
                      {
                        'week': '2026-W36',
                        'rank': 4,
                        'score': 640,
                        'gage': 0,
                        'crates': 1,
                      },
                    ],
              'nextCheckAt': '2026-09-13T22:00:00Z',
            }),
          );
        }
        if (request.url.path
            .replaceFirst(RegExp(r'/$'), '')
            .endsWith('/weekly/seen')) {
          seen++;
          expect(jsonDecode(request.body), {'week': '2026-W36'});
          return Future.value(
            jsonResponse(
              seen == 1 ? {'error': 'Offline'} : {'ok': true},
              seen == 1 ? 503 : 200,
            ),
          );
        }
        return null;
      };
      final c = server.controller();
      addTearDown(c.dispose);
      await signIn(c);
      expect(c.hasAccess, isTrue);
      expect(c.isDemo, isFalse);
      expect(c.supports('runnerWeeklyResults'), isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(
            controller: c,
            devices: DeviceServices(
              c,
              onTarget: (_) {},
              onForegroundMessage: (_) {},
            ),
            promptForPush: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Wochenprobe: Dein Ergebnis'), findsOneWidget);
      expect(find.textContaining('Platz 4'), findsOneWidget);
      expect(find.textContaining('640 Punkte'), findsOneWidget);
      expect(seen, 0);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(seen, 0);
      await tester.tap(find.text('Verstanden'));
      await tester.pumpAndSettle();
      expect(find.text('Wochenprobe: Dein Ergebnis'), findsOneWidget);
      expect(find.textContaining('Bitte erneut versuchen'), findsOneWidget);
      await tester.tap(find.text('Verstanden'));
      await tester.pumpAndSettle();
      expect(find.text('Wochenprobe: Dein Ergebnis'), findsNothing);
      await tester.pump(const Duration(minutes: 2));
      await tester.pumpAndSettle();
      expect(seen, 2);
      expect(reads, greaterThan(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'open app checks exactly at server boundary, older servers are not polled',
    (tester) async {
      final server = TestServer();
      var reads = 0;
      server.data['capabilities'] = {
        'features': ['runnerWeeklyResults'],
      };
      server.override = (request) {
        if (!request.url.path.contains('/weekly/results')) return null;
        reads++;
        return Future.value(
          jsonResponse({
            'results': reads == 1
                ? []
                : [
                    {
                      'week': '2026-W36',
                      'rank': 1,
                      'score': 900,
                      'gage': 100,
                      'crates': 1,
                    },
                  ],
            'nextCheckAt': fixedNow
                .add(const Duration(seconds: 10))
                .toUtc()
                .toIso8601String(),
          }),
        );
      };
      final c = server.controller();
      addTearDown(c.dispose);
      await signIn(c);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      Widget app() => MaterialApp(
        home: WeeklyResultHost(controller: c, child: const Scaffold()),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(reads, 1);
      await tester.pump(const Duration(seconds: 9));
      expect(reads, 1);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.textContaining('Platz 1'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      server.data['capabilities'] = {
        'features': ['runnerWeekly'],
      };
      await c.refresh();
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 2));
      expect(reads, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'startup, foreground and covered routes preserve backlog without stacking',
    (tester) async {
      final server = TestServer();
      server.data['capabilities'] = {
        'features': ['runnerWeeklyResults'],
      };
      final startup = Completer<void>();
      final navigator = GlobalKey<NavigatorState>();
      final acknowledged = <String>[];
      var reads = 0, offline = true;
      server.override = (request) {
        final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
        if (path.endsWith('/weekly/results')) {
          reads++;
          if (offline) {
            return Future.value(jsonResponse({'error': 'offline'}, 503));
          }
          return Future.value(
            jsonResponse({
              'results': [
                for (final week in ['2026-W34', '2026-W35'])
                  if (!acknowledged.contains(week))
                    {
                      'week': week,
                      'rank': 2,
                      'score': 700,
                      'gage': 50,
                      'crates': 1,
                      'trophy': 'silver',
                    },
              ],
            }),
          );
        }
        if (path.endsWith('/weekly/seen')) {
          acknowledged.add((jsonDecode(request.body) as Map)['week'] as String);
          return Future.value(jsonResponse({'ok': true}));
        }
        return null;
      };
      final c = server.controller();
      addTearDown(c.dispose);
      await signIn(c);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: WeeklyResultHost(
            controller: c,
            beforeCheck: () => startup.future,
            child: const Scaffold(body: Text('Heute')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(reads, 0);
      startup.complete();
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(acknowledged, isEmpty);
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Lauf')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      offline = false;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 3));
      expect(reads, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(reads, 1); // No dialog or fetch over a run.
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(find.text('Woche 2026-W34'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('weekly-result-popup')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(acknowledged, isEmpty);
      await tester.tap(find.text('Verstanden'));
      await tester.pumpAndSettle();
      expect(find.text('Woche 2026-W35'), findsOneWidget);
      expect(acknowledged, ['2026-W34']);
      await tester.tap(find.text('Verstanden'));
      await tester.pumpAndSettle();
      expect(acknowledged, ['2026-W34', '2026-W35']);
      expect(find.byKey(const ValueKey('weekly-result-popup')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
