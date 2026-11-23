import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/deep_links.dart';
import 'package:theater_app/app/shell/app_navigation.dart';
import 'package:theater_app/app/shell/app_section.dart';
import 'package:theater_app/app/shell/app_shell.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/forms/ui/form_response_screen.dart';
import 'package:theater_app/features/messages/domain/message_selectors.dart';
import 'package:theater_app/features/messages/ui/messages_screen.dart';
import 'package:theater_app/features/polls/ui/poll_detail_screen.dart';
import 'package:theater_app/features/polls/ui/polls_screen.dart';
import 'package:theater_app/features/rehearsal/ui/attendance_screen.dart';
import 'package:theater_app/features/scripts/data/script_pdf_exporter.dart';
import 'package:theater_app/features/scripts/ui/widgets/cue_card.dart';
import 'package:theater_app/features/today/domain/today_digest.dart';
import 'package:theater_app/features/today/ui/today_screen.dart';

import 'app_controller_test.dart' show TestServer, fixedNow, jsonResponse, signIn;

JsonMap _messageWithForm(
  String id,
  String title, {
  required String formTitle,
  bool read = true,
  bool formClosed = false,
  String submittedAt = '',
  bool addressedToMe = true,
}) => {
  'id': id,
  'title': title,
  'body': 'Bitte rechtzeitig ausfüllen.',
  'authorName': 'Vorstand',
  'createdAt': fixedNow
      .subtract(const Duration(hours: 2))
      .toUtc()
      .toIso8601String(),
  'read': read,
  'addressedToMe': addressedToMe,
  'formClosed': formClosed,
  if (submittedAt.isNotEmpty) 'myFormSubmittedAt': submittedAt,
  'form': {
    'title': formTitle,
    'fields': [
      {'id': 'f1', 'label': 'Name', 'type': 'text', 'required': true},
    ],
  },
};

JsonMap _plainMessage(String id, String title, {bool read = false}) => {
  'id': id,
  'title': title,
  'body': 'Kurze Info.',
  'authorName': 'Regie',
  'createdAt': fixedNow
      .subtract(const Duration(hours: 1))
      .toUtc()
      .toIso8601String(),
  'read': read,
  'addressedToMe': true,
};

TestServer _memberServer() {
  final server = TestServer();
  server.override = (request) {
    final path = request.url.path.replaceFirst(RegExp(r'/$'), '');
    if (!path.endsWith('/snapshot') || server.offline) return null;
    return Future.value(
      jsonResponse({
        ...server.data,
        'user': {...server.user, 'role': 'member', 'personId': 1},
      }),
    );
  };
  return server;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('de'));

  group('polls deep-link segment', () {
    testWidgets(
      'deep link to a poll selects the polls segment so back lands on PollsScreen',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 900);
        addTearDown(tester.view.reset);

        final server = TestServer();
        server.data['polls'] = [
          {
            'id': 'poll-dl',
            'title': 'Probetermin wählen',
            'addressedToMe': true,
            'options': [
              {'id': 'a', 'label': 'Montag', 'votes': 1},
              {'id': 'b', 'label': 'Dienstag', 'votes': 2},
            ],
          },
        ];
        final controller = server.controller();
        await signIn(controller);

        final selection = ValueNotifier<int>(AppSection.today.index);
        addTearDown(selection.dispose);
        final navigator = GlobalKey<NavigatorState>();
        final messenger = GlobalKey<ScaffoldMessengerState>();
        final router = DeepLinkRouter(
          controller: controller,
          navigator: navigator,
          messenger: messenger,
          isMounted: () => navigator.currentState?.mounted ?? false,
        );

        await tester.pumpWidget(
          AppNavigationScope(
            selection: selection,
            controller: controller,
            child: MaterialApp(
              navigatorKey: navigator,
              scaffoldMessengerKey: messenger,
              theme: StageTheme.build(Brightness.light),
              home: AppShell(
                controller: controller,
                devices: DeviceServices(
                  controller,
                  onTarget: (_) {},
                  onForegroundMessage: (_) {},
                ),
                promptForPush: false,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(communicationPollsSegment(controller).value, isFalse);

        router.handle(const AppTarget('polls', 'poll-dl'));
        await tester.pumpAndSettle();

        expect(selection.value, AppSection.messages.index);
        expect(communicationPollsSegment(controller).value, isTrue);
        expect(find.byType(PollDetailScreen), findsOneWidget);

        await tester.pageBack();
        await tester.pumpAndSettle();

        expect(find.byType(PollDetailScreen), findsNothing);
        expect(find.byType(PollsScreen), findsOneWidget);
        expect(find.byType(MessagesScreen), findsNothing);
        expect(tester.takeException(), isNull);

        // Switching back via a message deep-link resets the segment to messages.
        server.data['messages'] = [_plainMessage('msg-dl', 'Wichtige Info')];
        await controller.refresh();
        router.handle(const AppTarget('messages', 'msg-dl'));
        await tester.pumpAndSettle();
        expect(communicationPollsSegment(controller).value, isFalse);

        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );
  });

  group('auto-mic EIN/AUS and microphone channel indicators', () {
    Widget wrapCue(ScriptCue cue, {Brightness brightness = Brightness.light}) =>
        MaterialApp(
          theme: StageTheme.build(brightness),
          home: Scaffold(
            body: CueCard(
              cue: cue,
              own: false,
              active: false,
              bookmarked: false,
              fontScale: 1,
              dark: brightness == Brightness.dark,
              query: '',
              onTap: () {},
              onBookmark: () {},
              onActions: () {},
              onNote: () {},
              onComments: () {},
            ),
          ),
        );

    testWidgets(
      'CueCard shows EIN/AUS chips and microphone channel in light and dark modes',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          const micOn = ScriptCue(
            id: 'c-on',
            sceneId: 's1',
            ordinal: 1,
            kind: 'microphone',
            text: 'LENA (1), OSKAR (2)',
            isAutoMic: true,
            micCueType: 'EIN',
          );
          const micOff = ScriptCue(
            id: 'c-off',
            sceneId: 's1',
            ordinal: 2,
            kind: 'microphone',
            text: 'LENA (1)',
            isAutoMic: true,
            micCueType: 'AUS',
          );
          const dialogue = ScriptCue(
            id: 'c-dlg',
            sceneId: 's1',
            ordinal: 3,
            kind: 'dialogue',
            role: 'LENA',
            microphone: '1',
            text: 'Das Licht geht an.',
          );

          for (final brightness in [Brightness.light, Brightness.dark]) {
            await tester.pumpWidget(wrapCue(micOn, brightness: brightness));
            expect(find.text('MIKROFON'), findsOneWidget);
            expect(find.text('EIN'), findsOneWidget);
            expect(find.text('AUTO'), findsOneWidget);
            expect(find.byIcon(Icons.mic_rounded), findsOneWidget);
            expect(
              find.bySemanticsLabel(RegExp('Mikrofon einschalten')),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);

            await tester.pumpWidget(wrapCue(micOff, brightness: brightness));
            expect(find.text('AUS'), findsOneWidget);
            expect(find.text('AUTO'), findsOneWidget);
            expect(find.byIcon(Icons.mic_off_rounded), findsOneWidget);
            expect(
              find.bySemanticsLabel(RegExp('Mikrofon ausschalten')),
              findsOneWidget,
            );
            expect(tester.takeException(), isNull);
          }

          // Dialogue cue with microphone channel at narrow width + 2x text scale.
          await tester.binding.setSurfaceSize(const Size(320, 400));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 400),
                textScaler: TextScaler.linear(2),
              ),
              child: wrapCue(dialogue),
            ),
          );
          expect(find.text('LENA'), findsOneWidget);
          expect(find.text('Mikro 1'), findsOneWidget);
          expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          semantics.dispose();
        }
      },
    );

    test('scriptPdfCueHeader includes EIN/AUS, AUTO, and microphone channel', () {
      expect(
        scriptPdfCueHeader(
          const ScriptCue(
            id: '1',
            sceneId: 's1',
            ordinal: 1,
            kind: 'microphone',
            text: 'LENA (1)',
            isAutoMic: true,
            micCueType: 'EIN',
          ),
        ),
        'Mikrofon · EIN · AUTO',
      );
      expect(
        scriptPdfCueHeader(
          const ScriptCue(
            id: '2',
            sceneId: 's1',
            ordinal: 2,
            kind: 'microphone',
            text: 'LENA (1)',
            isAutoMic: true,
            micCueType: 'AUS',
          ),
        ),
        'Mikrofon · AUS · AUTO',
      );
      expect(
        scriptPdfCueHeader(
          const ScriptCue(
            id: '3',
            sceneId: 's1',
            ordinal: 3,
            kind: 'dialogue',
            role: 'LENA',
            microphone: '2',
            text: 'Hallo',
          ),
        ),
        'LENA · Mikro 2',
      );
      expect(
        scriptPdfCueHeader(
          const ScriptCue(
            id: '4',
            sceneId: 's1',
            ordinal: 4,
            kind: 'dialogue',
            role: 'OSKAR',
            microphone: 'Mikro 4',
            text: 'Hi',
          ),
        ),
        'OSKAR · Mikro 4',
      );
      expect(
        scriptPdfCueHeader(
          const ScriptCue(
            id: '5',
            sceneId: 's1',
            ordinal: 5,
            kind: 'direction',
            text: 'Licht aus.',
          ),
        ),
        'Regie',
      );
    });
  });

  group('open forms in selectors, Today, Post badge, and MessagesScreen', () {
    test(
      'openForms selects only unsubmitted, open, addressed forms and avoids badge double-counting',
      () async {
        final server = _memberServer();
        server.data['polls'] = <dynamic>[];
        server.data['messages'] = [
          _messageWithForm(
            'f-read',
            'Kostümliste',
            formTitle: 'Größen angeben',
            read: true,
          ),
          _messageWithForm(
            'f-unread',
            'Helferdienst',
            formTitle: 'Schichtwunsch',
            read: false,
          ),
          _messageWithForm(
            'f-done',
            'Einverständnis',
            formTitle: 'Einverständnis',
            read: true,
            submittedAt: '2026-09-10T10:00:00Z',
          ),
          _messageWithForm(
            'f-closed',
            'Abgelaufen',
            formTitle: 'Alt',
            read: true,
            formClosed: true,
          ),
          _messageWithForm(
            'f-other',
            'Nur Technik',
            formTitle: 'Technik-Check',
            read: true,
            addressedToMe: false,
          ),
          _plainMessage('m-unread', 'Probenhinweis', read: false),
        ];
        final controller = server.controller();
        addTearDown(controller.dispose);
        await signIn(controller);

        expect(openForms(controller).map((m) => m['id']), [
          'f-read',
          'f-unread',
        ]);
        expect(openFormCount(controller), 2);

        final digest = TodayDigest.from(controller);
        expect(digest.openForms.map((m) => m['id']), ['f-read', 'f-unread']);
        expect(digest.hasPending, isTrue);

        // Post badge: 2 unread (f-unread, m-unread) + 1 read-only open form
        // (f-read) = 3, NOT 4 (no double-counting of f-unread).
        final post = appNavigationDestinations(controller)[AppSection.messages.index];
        final badge = (post.icon as Semantics).child as ExcludeSemantics;
        final label = ((badge.child as Badge).label as Text).data;
        expect(label, '3');
        expect(
          post.tooltip,
          'Mitteilungen · 2 ungelesen · 2 Formulare offen',
        );

        // When all messages are read, the open forms alone still drive hasPending & badge.
        server.data['messages'] = [
          _messageWithForm(
            'f-read',
            'Kostümliste',
            formTitle: 'Größen angeben',
            read: true,
          ),
        ];
        server.data['events'] = <dynamic>[];
        server.data['slotPools'] = <dynamic>[];
        await controller.refresh();
        final digestOnlyForm = TodayDigest.from(controller);
        expect(digestOnlyForm.unread, isEmpty);
        expect(digestOnlyForm.openForms.map((m) => m['id']), ['f-read']);
        expect(digestOnlyForm.hasPending, isTrue);

        final postOnlyForm =
            appNavigationDestinations(controller)[AppSection.messages.index];
        final labelOnlyForm =
            ((((postOnlyForm.icon as Semantics).child as ExcludeSemantics).child
                        as Badge)
                    .label
                as Text)
                .data;
        expect(labelOnlyForm, '1');
        expect(postOnlyForm.tooltip, 'Mitteilungen · 1 Formular offen');
      },
    );

    testWidgets('TodayScreen lists open forms and opens FormResponseScreen directly', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1200);
      addTearDown(tester.view.reset);

      final server = _memberServer();
      server.data['events'] = <dynamic>[];
      server.data['polls'] = <dynamic>[];
      server.data['slotPools'] = <dynamic>[];
      server.data['messages'] = [
        _messageWithForm(
          'f1',
          'Kostümabfrage',
          formTitle: 'Konfektionsgrößen',
          read: true,
        ),
      ];
      final controller = server.controller();
      await signIn(controller);

      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: Scaffold(
            body: TodayScreen(
              controller: controller,
              onPlan: () {},
              onScripts: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Offene Formulare'), findsOneWidget);
      final tile = find.byKey(const ValueKey('today-form-f1'));
      expect(tile, findsOneWidget);
      expect(find.text('Konfektionsgrößen'), findsOneWidget);

      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.byType(FormResponseScreen), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });

    testWidgets('MessagesScreen filters open forms cleanly at 320px width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 900);
      addTearDown(tester.view.reset);

      final server = _memberServer();
      server.data['messages'] = [
        _messageWithForm(
          'f1',
          'Kostümabfrage',
          formTitle: 'Größen',
          read: true,
        ),
        _plainMessage('m1', 'Probenstart', read: false),
      ];
      final controller = server.controller();
      await signIn(controller);

      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.light),
          home: Scaffold(
            body: MessagesScreen(controller: controller, embedded: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Kostümabfrage'), findsOneWidget);
      expect(find.text('Probenstart'), findsOneWidget);

      await tester.tap(find.text('Formulare · 1'));
      await tester.pumpAndSettle();
      expect(find.text('Kostümabfrage'), findsOneWidget);
      expect(find.text('Probenstart'), findsNothing);
      expect(tester.takeException(), isNull);

      // Once submitted, the open-forms filter shows its empty state.
      server.data['messages'] = [
        _messageWithForm(
          'f1',
          'Kostümabfrage',
          formTitle: 'Größen',
          read: true,
          submittedAt: '2026-09-12T10:00:00Z',
        ),
        _plainMessage('m1', 'Probenstart', read: true),
      ];
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(find.text('Keine offenen Formulare'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    });
  });

  group('attendance check-in bar, status filters, and role search', () {
    testWidgets(
      'sticky save bar stays visible, status chips filter, and search matches roles',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 620));
        addTearDown(() => tester.binding.setSurfaceSize(null));

        final server = TestServer();
        server.data['events'] = [
          {
            'id': 'rehearsal',
            'title': 'Technikprobe',
            'startsAt': '2026-09-13T17:00:00Z',
            'endsAt': '2026-09-13T19:00:00Z',
          },
        ];
        server.data['checkinsByEvent'] = {
          'rehearsal': {'2': true, '3': false},
        };
        final controller = server.controller();
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

        // Sticky save bar is visible right away without scrolling to the bottom.
        final saveBar = find.byKey(const ValueKey('attendance-save-bar'));
        expect(saveBar, findsOneWidget);
        expect(tester.getBottomLeft(saveBar).dy, lessThanOrEqualTo(620));
        expect(
          find.descendant(
            of: saveBar,
            matching: find.widgetWithText(FilledButton, 'Änderungen speichern'),
          ),
          findsOneWidget,
        );

        // Expand viewport to inspect filtered member cards below the filter chips.
        await tester.binding.setSurfaceSize(const Size(390, 1400));
        await tester.pumpAndSettle();

        // Status filter chips.
        await tester.tap(find.text('Nicht erfasst (3)'));
        await tester.pumpAndSettle();
        expect(find.text('Alex Bühnenfreund'), findsOneWidget);
        expect(find.text('Robin Spielmann'), findsNothing);
        expect(find.text('Toni Lichtblick'), findsNothing);

        await tester.tap(find.text('Da (1)'));
        await tester.pumpAndSettle();
        expect(find.text('Robin Spielmann'), findsOneWidget);
        expect(find.text('Alex Bühnenfreund'), findsNothing);

        await tester.tap(find.text('Fehlt (1)'));
        await tester.pumpAndSettle();
        expect(find.text('Toni Lichtblick'), findsOneWidget);
        expect(find.text('Robin Spielmann'), findsNothing);

        await tester.tap(find.text('Alle (5)'));
        await tester.pumpAndSettle();

        // Search by person role (not part of the member's display name).
        final roleMember = controller.members.firstWhere(
          (m) => m.roleIds.isNotEmpty,
        );
        final roleQuery = controller.roleNames(roleMember.roleIds).split(',').first.trim();
        expect(roleQuery, isNotEmpty);

        await tester.enterText(find.byType(TextField), roleQuery);
        await tester.pumpAndSettle();
        expect(find.text(roleMember.name), findsOneWidget);

        // Clear search button resets the query.
        await tester.tap(find.byTooltip('Suche leeren'));
        await tester.pumpAndSettle();
        expect(find.text('Alex Bühnenfreund'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tester.pumpWidget(const SizedBox());
        controller.dispose();
      },
    );
  });
}
