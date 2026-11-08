import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/shell/app_navigation.dart';
import 'package:theater_app/app/shell/app_section.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/games/games.dart';
import 'package:theater_app/features/sync/sync.dart';
import 'package:theater_app/main.dart';
import 'package:theater_app/shared/navigation.dart';

import 'app_controller_test.dart' show TestServer, signIn;
import 'shell_navigation_test.dart'
    show finish, pumpDemo, setWidth, shellContext;

/// A signed-in admin whose profile carries the server's `runnerEntry`.
class _EntryServer extends TestServer {
  _EntryServer({required this.entry});
  final bool entry;
  @override
  JsonMap get user => {...super.user, 'runnerEntry': entry};
}

Future<AppController> _pumpSignedIn(
  WidgetTester tester, {
  required bool entry,
}) async {
  final c = _EntryServer(entry: entry).controller();
  await signIn(c);
  await tester.pumpWidget(
    TheaterApp(controller: c, enableDeviceServices: false),
  );
  await tester.pumpAndSettle();
  return c;
}

List<String> _railLabels(WidgetTester tester) => [
  for (final d
      in tester
          .widget<NavigationRail>(find.byType(NavigationRail))
          .destinations)
    (d.label as Text).data!,
];

int? _railSelected(WidgetTester tester) =>
    tester.widget<NavigationRail>(find.byType(NavigationRail)).selectedIndex;

Finder _inRail(String label) => find.descendant(
  of: find.byType(AppNavigationRail),
  matching: find.text(label),
);

void main() {
  setUpAll(() => initializeDateFormatting('de'));

  test('the profile keeps the server\'s runnerEntry', () {
    final user = AppUser.fromJson({
      'userId': 'u',
      'role': 'member',
      'runnerEntry': true,
    });
    expect(user.runnerEntry, isTrue);
    expect(AppUser.fromJson(user.toJson()).runnerEntry, isTrue);
    // Older servers do not send it.
    expect(AppUser.fromJson({'userId': 'u'}).runnerEntry, isFalse);
  });

  testWidgets('wide screens list the game after Ich, before Admin', (
    tester,
  ) async {
    setWidth(tester, 1440);
    final c = await _pumpSignedIn(tester, entry: true);
    expect(gameEntryShown(c), isTrue);
    expect(_railLabels(tester), [
      'Heute',
      'Termine',
      'Skript',
      'Post',
      'Ich',
      'Bühnenlauf',
      'Admin',
    ]);
    // The sections keep their index: Admin is still section 5.
    await tester.tap(_inRail('Admin'));
    await tester.pumpAndSettle();
    expect(
      AppNavigationScope.maybeOf(shellContext(tester))!.value,
      AppSection.admin.index,
    );
    expect(_railSelected(tester), 6);
    await tester.tap(_inRail('Ich'));
    await tester.pumpAndSettle();
    expect(
      AppNavigationScope.maybeOf(shellContext(tester))!.value,
      AppSection.me.index,
    );
    expect(_railSelected(tester), 4);
    // Wide screens have the rail: no extra tile in Mein Bereich.
    expect(find.byKey(const ValueKey('game-entry')), findsNothing);
    await finish(tester, c);
  });

  testWidgets('the rail entry opens the game and marks it while shown', (
    tester,
  ) async {
    setWidth(tester, 1440);
    final c = await _pumpSignedIn(tester, entry: true);
    await tester.tap(_inRail('Bühnenlauf'));
    await tester.pumpAndSettle();
    expect(find.byType(StageRunnerScreen), findsOneWidget);
    expect(find.byType(AppNavigationRail), findsOneWidget);
    expect(_railSelected(tester), 5);
    // Another tap keeps the game as it is.
    await tester.tap(_inRail('Bühnenlauf'));
    await tester.pumpAndSettle();
    expect(find.byType(StageRunnerScreen), findsOneWidget);
    // A section closes the game like any page.
    await tester.tap(_inRail('Post'));
    await tester.pumpAndSettle();
    expect(find.byType(StageRunnerScreen), findsNothing);
    expect(
      AppNavigationScope.maybeOf(shellContext(tester))!.value,
      AppSection.messages.index,
    );
    expect(_railSelected(tester), 3);

    // From another page the entry goes back to the start, then to the game.
    openPage(shellContext(tester), SyncScreen(controller: c));
    await tester.pumpAndSettle();
    expect(_railSelected(tester), 3);
    await tester.tap(_inRail('Bühnenlauf'));
    await tester.pumpAndSettle();
    expect(find.byType(SyncScreen), findsNothing);
    expect(find.byType(StageRunnerScreen), findsOneWidget);
    await finish(tester, c);
  });

  testWidgets('pages the game opens belong to it and lead back to it', (
    tester,
  ) async {
    setWidth(tester, 1440);
    final c = await _pumpSignedIn(tester, entry: true);
    await tester.tap(_inRail('Bühnenlauf'));
    await tester.pumpAndSettle();
    final game = tester.state(find.byType(StageRunnerScreen));
    // A page above the game (like the Garderobe or the Wochenprobe).
    openPage(
      tester.element(find.byType(StageRunnerScreen)),
      SyncScreen(controller: c),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SyncScreen), findsOneWidget);
    expect(_railSelected(tester), 5, reason: 'still the game');
    // The entry goes back to the game as it was, not to a new one.
    await tester.tap(_inRail('Bühnenlauf'));
    await tester.pumpAndSettle();
    expect(find.byType(SyncScreen), findsNothing);
    expect(tester.state(find.byType(StageRunnerScreen)), same(game));
    expect(_railSelected(tester), 5);

    // A page the game was opened from is not the game's once it is back.
    await tester.tap(_inRail('Post'));
    await tester.pumpAndSettle();
    openPage(shellContext(tester), SyncScreen(controller: c));
    await tester.pumpAndSettle();
    openStageRunner(tester.element(find.byType(SyncScreen)), c);
    await tester.pumpAndSettle();
    expect(_railSelected(tester), 5);
    Navigator.of(tester.element(find.byType(StageRunnerScreen))).pop();
    await tester.pumpAndSettle();
    expect(find.byType(StageRunnerScreen), findsNothing);
    expect(find.byType(SyncScreen), findsOneWidget);
    expect(_railSelected(tester), 3);
    await finish(tester, c);
  });

  testWidgets('without enough runs the rail has the sections only', (
    tester,
  ) async {
    setWidth(tester, 1440);
    final c = await _pumpSignedIn(tester, entry: false);
    expect(gameEntryShown(c), isFalse);
    expect(_railLabels(tester), [
      'Heute',
      'Termine',
      'Skript',
      'Post',
      'Ich',
      'Admin',
    ]);
    await tester.tap(_inRail('Admin'));
    await tester.pumpAndSettle();
    expect(_railSelected(tester), 5);
    await finish(tester, c);
  });

  testWidgets('the demo never shows the entry', (tester) async {
    setWidth(tester, 1440);
    final c = await pumpDemo(tester);
    expect(gameEntryShown(c), isFalse);
    expect(_inRail('Bühnenlauf'), findsNothing);
    await finish(tester, c);
  });

  testWidgets('phones keep five tabs and show the game atop Mein Bereich', (
    tester,
  ) async {
    setWidth(tester, 390);
    final c = await _pumpSignedIn(tester, entry: true);
    expect(find.byType(NavigationRail), findsNothing);
    expect(find.byType(NavigationDestination), findsNWidgets(5));
    expect(find.text('Bühnenlauf'), findsNothing);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Ich'),
      ),
    );
    await tester.pumpAndSettle();
    final entry = find.byKey(const ValueKey('game-entry'));
    expect(entry, findsOneWidget);
    // At the top: above the profile card.
    expect(
      tester.getTopLeft(entry).dy,
      lessThan(tester.getTopLeft(find.text('Profil bearbeiten')).dy),
    );
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(StageRunnerScreen), findsOneWidget);
    await finish(tester, c);
  });

  testWidgets('phones below the threshold have no entry in Mein Bereich', (
    tester,
  ) async {
    setWidth(tester, 390);
    final c = await _pumpSignedIn(tester, entry: false);
    await tester.tap(
      find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Ich'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('game-entry')), findsNothing);
    expect(find.text('Bühnenlauf'), findsNothing);
    await finish(tester, c);
  });
}
