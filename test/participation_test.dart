import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/ui/accounts_admin.dart';
import 'package:theater_app/ui/more.dart';
import 'package:theater_app/ui/participation.dart';
import 'package:theater_app/ui/theme.dart';

import 'account_roster_test.dart' show fixture;
import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

const counts = {
  'events': 6,
  'answerable': 5,
  'answered': 4,
  'recorded': 4,
  'attended': 3,
  'missedAfterCommitment': 1,
  'missedUnannounced': 0,
};

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('participation lines stay neutral and skip empty facts', () {
    expect(
      participationLine(counts),
      'Rückmeldung 4 von 5 · dabei 3 von 4 · 1× trotz Zusage gefehlt',
    );
    expect(participationLine({'events': 2}), '2 Termine, noch nichts erfasst');
  });

  test('reminder lead times read naturally', () {
    expect(reminderLeadTimeLabel(null), 'Aus');
    expect(reminderLeadTimeLabel(45), '45 Minuten vorher');
    expect(reminderLeadTimeLabel(60), '1 Stunde vorher');
    expect(reminderLeadTimeLabel(180), '3 Stunden vorher');
    expect(reminderLeadTimeLabel(2880), '2 Tage vorher');
    expect(reminderLeadTimeLabel(10080), '1 Woche vorher');
  });

  for (final ensemble in [false, true]) {
    testWidgets(
      ensemble
          ? 'admins see every active person alphabetically'
          : 'members see only their own participation',
      (tester) async {
        tester.view.physicalSize = const Size(900, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final semantics = tester.ensureSemantics();
        final server = TestServer();
        server.override = (request) =>
            request.url.path.contains('/participation')
            ? Future.value(
                jsonResponse({
                  'since': '2026-03-12T12:00:00.000Z',
                  'own': counts,
                  if (ensemble)
                    'people': [
                      {'personId': 1, 'name': 'Alex', 'events': 2},
                      {'personId': 2, 'name': 'Sam', ...counts},
                    ],
                }),
              )
            : null;
        final controller = server.controller();
        await signIn(controller);
        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.light),
            home: ParticipationScreen(
              controller: controller,
              ensemble: ensemble,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('seit 12. März 2026'), findsOneWidget);
        if (ensemble) {
          expect(find.text('ENSEMBLE GESAMT'), findsOneWidget);
          expect(find.text('Personen (2)'), findsOneWidget);
          expect(find.text('Alex'), findsOneWidget);
          expect(find.text(participationLine({...counts})), findsOneWidget);
        } else {
          expect(find.text('Meine Teilnahme'), findsOneWidget);
          expect(
            find.bySemanticsLabel('Rückmeldung gegeben: 4 von 5'),
            findsOneWidget,
          );
          expect(
            find.bySemanticsLabel('Dabei gewesen: 3 von 4'),
            findsOneWidget,
          );
          expect(find.text('Trotz Zusage gefehlt'), findsOneWidget);
          expect(find.textContaining('keine Rangliste'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        semantics.dispose();
        controller.dispose();
      },
    );
  }

  testWidgets('admins delete an account only after confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer();
    final deletions = <http.Request>[];
    server.override = (request) {
      if (request.method == 'DELETE' &&
          request.url.path.contains('/admin/accounts/')) {
        deletions.add(request);
        return Future.value(jsonResponse({'ok': true}));
      }
      return request.url.path.contains('/admin/accounts')
          ? Future.value(jsonResponse(fixture()))
          : null;
    };
    final controller = server.controller();
    await signIn(controller);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: AccountsAdminScreen(
          controller: controller,
          initialView: 'accounts',
          initialFilter: 'suspended',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Zugang verwalten'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Konto löschen'));
    await tester.pumpAndSettle();
    expect(find.text('Konto löschen?'), findsOneWidget);
    await tester.tap(find.text('Abbrechen'));
    await tester.pumpAndSettle();
    expect(deletions, isEmpty);
    await tester.tap(find.byTooltip('Zugang verwalten'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Konto löschen'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Löschen'));
    await tester.pumpAndSettle();
    expect(deletions.single.url.path, endsWith('/admin/accounts/kim/'));
    expect(jsonDecode(deletions.single.body), {'version': 2});
    expect(find.text('Konto gelöscht.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });

  test(
    'a personal reminder lead time is saved with the other reminders',
    () async {
      final server = TestServer(), controller = server.controller();
      await signIn(controller);
      await controller.saveCustomReminder(45);
      final saved = jsonMap(server.actionBodies.last['value']);
      expect(saved, {
        'dayBefore': false,
        'twoHours': true,
        'changes': true,
        'emailEnabled': false,
        'customMinutes': 45,
      });
      // The test server does not persist settings like the real one does.
      server.data['reminders'] = saved;
      await controller.refresh();
      expect(controller.customReminderMinutes, 45);
      await controller.saveReminders({
        ...controller.reminders,
        'dayBefore': true,
      });
      expect(jsonMap(server.actionBodies.last['value'])['customMinutes'], 45);
      controller.dispose();
    },
  );

  testWidgets('participation stays readable with large text in dark mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = TestServer();
    server.override = (request) => request.url.path.contains('/participation')
        ? Future.value(
            jsonResponse({
              'since': '2026-03-12T12:00:00.000Z',
              'own': counts,
              'people': [
                {'personId': 2, 'name': 'Sam', ...counts},
              ],
            }),
          )
        : null;
    final controller = server.controller();
    await signIn(controller);
    for (final ensemble in [false, true]) {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            textScaler: TextScaler.linear(2),
          ),
          child: MaterialApp(
            theme: StageTheme.build(Brightness.dark),
            home: ParticipationScreen(
              controller: controller,
              ensemble: ensemble,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
