import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:theater_app/app/session_gate.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/auth/auth.dart';

import 'firebase_access_test.dart' show FakeIdentity;

const _base = 'https://theater.example.invalid';
const _question = 'In welchem Ort ist das Kolpingtheater?';

class _Identity extends FakeIdentity {
  @override
  Future<void> social(String provider, {bool link = false}) async {
    uid = 'person@example.invalid';
    email = 'person@example.invalid';
  }
}

/// A server with the bot check: only "Ramsen" passes, like the server config.
class _Server {
  _Server({this.supportsBotCheck = true});
  final bool supportsBotCheck;
  final requests = <http.Request>[];
  var proofs = 0;
  DateTime expiresAt = DateTime.utc(2100);

  List<String> get paths =>
      requests.map((r) => '${r.method} ${r.url.path}').toList();
  List<JsonMap> bodies(String path) => [
    for (final r in requests)
      if (r.url.path == '/api/mobile/v1$path/' && r.body.isNotEmpty)
        jsonMap(jsonDecode(r.body)),
  ];

  late final client = MockClient((request) async {
    requests.add(request);
    http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
    final path = request.url.path;
    if (path == '/api/mobile/v1/bot-check/') {
      if (!supportsBotCheck) {
        return json({'error': 'Bitte zuerst anmelden.'}, 401);
      }
      if (request.method == 'GET') {
        return json({'question': _question, 'hint': 'Ein Wort genügt.'});
      }
      final answer = jsonMap(jsonDecode(request.body))['answer'];
      if (answer.toString().trim().toLowerCase() != 'ramsen') {
        return json({
          'error': 'Das passt leider nicht. Schau noch einmal genau hin.',
          'code': 'bot_check_wrong',
        }, 400);
      }
      return json({
        'proof': 'proof-${++proofs}',
        'expiresAt': expiresAt.toIso8601String(),
      });
    }
    return json({
      'user': {
        'userId': 'person@example.invalid',
        'displayName': 'Neue Person',
        'status': 'pending',
        'role': 'member',
        'identityReady': true,
        'emailVerified': true,
      },
    });
  });
}

Future<AppController> _controller(
  _Server server, {
  MemoryLocalStore? store,
  FakeIdentity? identity,
  DateTime Function()? clock,
}) async {
  final local = store ?? MemoryLocalStore();
  if (store == null) {
    await local.write('_device', 'settings', {'baseUrl': _base});
  }
  final c = AppController(
    identity: identity ?? FakeIdentity(),
    localStore: local,
    credentialStore: MemoryCredentialStore(),
    apiClient: ApiClient(client: server.client),
    clock: clock,
  );
  await c.init();
  return c;
}

/// The invisible honeypot of the bot trap on the current screen.
Finder _trap() => find.byKey(const ValueKey('bot-trap'), skipOffstage: false);

/// What a bot would do: type into the field people never see.
void _fillTrap(WidgetTester tester) =>
    tester.widget<TextField>(_trap()).controller!.text = 'https://spam.test';

EditableTextState _trapEditable(WidgetTester tester) =>
    tester.state<EditableTextState>(
      find.descendant(
        of: _trap(),
        matching: find.byType(EditableText, skipOffstage: false),
        skipOffstage: false,
      ),
    );

/// The honeypot is invisible, unfocusable, silent for screen readers and
/// outside autofill, so people, browsers and password managers never fill it.
void _expectInvisibleTrap(WidgetTester tester) {
  expect(_trap(), findsOneWidget);
  expect(find.byKey(const ValueKey('bot-trap')), findsNothing);
  expect(_trap().hitTestable(), findsNothing);
  final field = tester.widget<TextField>(_trap());
  expect(field.autofillHints, isNull);
  final editable = _trapEditable(tester);
  expect(editable.textInputConfiguration.autofillConfiguration.enabled, false);
  expect(editable.widget.focusNode.canRequestFocus, isFalse);
  expect(find.bySemanticsLabel('Webseite'), findsNothing);
}

Widget _gate(AppController c) => MaterialApp(
  theme: StageTheme.build(Brightness.light),
  home: SessionGate(
    controller: c,
    devices: DeviceServices(c, onTarget: (_) {}, onForegroundMessage: (_) {}),
    starting: false,
    startupError: null,
    onRetry: () {},
    promptForPush: false,
  ),
);

void main() {
  test('a device answers once; the proof reaches the new account', () async {
    final server = _Server();
    final store = MemoryLocalStore();
    await store.write('_device', 'settings', {'baseUrl': _base});
    final c = await _controller(server, store: store);
    expect(c.needsBotCheck, isTrue);
    expect((await c.loadBotCheckQuestion())!.question, _question);
    await expectLater(
      c.answerBotCheck('Berlin'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'bot_check_wrong'),
      ),
    );
    expect(c.needsBotCheck, isTrue);
    await c.answerBotCheck('  Ramsen ');
    expect(c.needsBotCheck, isFalse);
    await c.register(
      'Neue Person',
      'person@example.invalid',
      'A long password!',
    );
    expect(server.bodies('/auth/session'), [
      {'registrationName': 'Neue Person', 'botCheckProof': 'proof-1'},
    ]);
    c.dispose();

    // The same device is not asked again, also without a session.
    final again = await _controller(server, store: store);
    expect(again.needsBotCheck, isFalse);
    again.dispose();
  });

  test('an expired proof is renewed with the remembered answer', () async {
    final server = _Server()..expiresAt = DateTime.utc(2000);
    final c = await _controller(server, identity: _Identity());
    await c.answerBotCheck('ramsen');
    await c.loginWithProvider('google.com');
    expect(server.bodies('/bot-check'), [
      {'answer': 'ramsen'},
      {'answer': 'ramsen'},
    ]);
    expect(server.bodies('/auth/session'), [
      {'botCheckProof': 'proof-2'},
    ]);
    c.dispose();
  });

  test('signed-in members and older servers are never asked', () async {
    final server = _Server();
    final store = MemoryLocalStore();
    await store.write('_device', 'settings', {'baseUrl': _base});
    final member = await _controller(
      server,
      store: store,
      identity: FakeIdentity()..uid = 'member@example.invalid',
    );
    expect(member.needsBotCheck, isFalse);
    member.dispose();
    // Remembered for this device, e.g. after a later logout.
    final later = await _controller(server, store: store);
    expect(later.needsBotCheck, isFalse);
    later.dispose();

    final old = _Server(supportsBotCheck: false);
    final c = await _controller(old);
    expect(c.needsBotCheck, isTrue);
    expect(await c.loadBotCheckQuestion(), isNull);
    expect(c.needsBotCheck, isFalse);
    // Without an answer no proof is sent; the session call stays a GET.
    await c.login(
      email: 'person@example.invalid',
      password: 'A long password!',
      baseUrl: _base,
    );
    expect(old.paths.last, 'GET /api/mobile/v1/auth/session/');
    c.dispose();
  });

  test('the demo and builds without Firebase have no bot check', () async {
    final c = AppController(
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
    );
    await c.init();
    expect(c.needsBotCheck, isFalse);
    await c.startDemo();
    expect(c.needsBotCheck, isFalse);
    c.dispose();
  });

  testWidgets('the question comes first, Enter checks and wrong answers '
      'slow down without revealing the answer', (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final server = _Server();
    final c = await _controller(server);
    addTearDown(c.dispose);
    await tester.pumpWidget(_gate(c));
    await tester.pumpAndSettle();
    expect(find.byType(FirebaseWelcomeScreen), findsNothing);
    expect(
      find.text('Kurze Frage, damit wir wissen, dass du kein Bot bist.'),
      findsOneWidget,
    );
    expect(find.text(_question), findsOneWidget);
    expect(find.bySemanticsLabel(_question), findsOneWidget);
    // The picture is shown and stays out of the screen reader's way.
    final art = tester.widget<Image>(
      find.byKey(const ValueKey('bot-check-art')),
    );
    expect((art.image as AssetImage).assetName, BotCheckScreen.art);
    expect(art.excludeFromSemantics, isTrue);
    expect(
      tester.getSize(find.byKey(const ValueKey('bot-check-art'))).height,
      180,
    );
    final field = find.byKey(const ValueKey('bot-check-answer'));
    expect(tester.widget<TextField>(field).autofocus, isTrue);

    await tester.tap(find.text('Weiter'));
    await tester.pumpAndSettle();
    expect(find.text('Bitte gib eine Antwort ein.'), findsOneWidget);

    for (var i = 0; i < BotCheckScreen.freeAttempts; i++) {
      await tester.enterText(field, 'Mannheim');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump();
    }
    expect(server.bodies('/bot-check').length, BotCheckScreen.freeAttempts);
    expect(find.textContaining('Das passt leider nicht'), findsOneWidget);
    expect(find.textContaining('Ramsen'), findsNothing);
    expect(find.text('Noch 5 s warten'), findsOneWidget);
    expect(find.textContaining('Kurze Pause'), findsOneWidget);
    // While waiting, Enter does not send.
    await tester.enterText(field, 'Ramsen');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(server.bodies('/bot-check').length, BotCheckScreen.freeAttempts);

    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Weiter'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.byType(BotCheckScreen), findsNothing);
    expect(find.byType(FirebaseWelcomeScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the bot check screen reports its invisible bot trap', (
    tester,
  ) async {
    var now = DateTime.utc(2026, 10, 19, 10);
    final semantics = tester.ensureSemantics();
    final server = _Server();
    final c = await _controller(server, clock: () => now);
    addTearDown(c.dispose);
    await tester.pumpWidget(_gate(c));
    await tester.pumpAndSettle();
    _expectInvisibleTrap(tester);
    final field = find.byKey(const ValueKey('bot-check-answer'));
    // Tab never lands on the trap.
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(_trapEditable(tester).widget.focusNode.hasFocus, isFalse);
    }
    now = now.add(const Duration(milliseconds: 4200));
    await tester.enterText(field, 'Mannheim');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    // A wrong answer does not restart the timer, people may retype quickly.
    now = now.add(const Duration(milliseconds: 500));
    _fillTrap(tester);
    await tester.enterText(field, 'Ramsen');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(server.bodies('/bot-check'), [
      {
        'answer': 'Mannheim',
        'botTrap': {'filled': false, 'elapsedMs': 4200},
      },
      {
        'answer': 'Ramsen',
        'botTrap': {'filled': true, 'elapsedMs': 4700},
      },
    ]);
    // The answer counts as usual: the sign-in follows.
    expect(find.byType(FirebaseWelcomeScreen), findsOneWidget);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the registration form sends its bot trap with the first '
      'account request', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var now = DateTime.utc(2026, 10, 19, 10);
    final semantics = tester.ensureSemantics();
    final server = _Server();
    final c = await _controller(server, clock: () => now);
    addTearDown(c.dispose);
    await c.answerBotCheck('Ramsen');
    await tester.pumpWidget(_gate(c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Noch kein Konto? Registrieren'));
    await tester.pumpAndSettle();
    _expectInvisibleTrap(tester);
    // The trap is outside the form's autofill group.
    final group = tester.state<AutofillGroupState>(find.byType(AutofillGroup));
    expect(group.autofillClients.length, 3);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name zur Zuordnung'),
      'Neue Person',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'E-Mail'),
      'person@example.invalid',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Passwort'),
      'A long password!',
    );
    now = now.add(const Duration(seconds: 9));
    await tester.tap(find.widgetWithText(FilledButton, 'Konto erstellen'));
    await tester.pumpAndSettle();
    expect(server.bodies('/auth/session'), [
      {
        'registrationName': 'Neue Person',
        'botCheckProof': 'proof-1',
        'botTrap': {'filled': false, 'elapsedMs': 9000},
      },
    ]);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a filled trap on the sign-in form still signs in', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime.utc(2026, 10, 19, 10);
    final server = _Server(supportsBotCheck: false);
    final c = await _controller(server, clock: () => now);
    addTearDown(c.dispose);
    await tester.pumpWidget(_gate(c));
    await tester.pumpAndSettle();
    expect(find.byType(FirebaseWelcomeScreen), findsOneWidget);
    _fillTrap(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'E-Mail'),
      'person@example.invalid',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Passwort'),
      'A long password!',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Anmelden'));
    await tester.pumpAndSettle();
    expect(server.bodies('/auth/session'), [
      {
        'botTrap': {'filled': true, 'elapsedMs': 0},
      },
    ]);
    expect(c.user, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final (name, size, keyboard) in [
    ('landscape', const Size(740, 360), 0.0),
    ('an open keyboard', const Size(390, 800), 330.0),
  ]) {
    testWidgets('the picture gives way to the question on $name', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await _controller(_Server());
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: StageTheme.build(Brightness.dark),
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              viewInsets: EdgeInsets.only(bottom: keyboard),
              disableAnimations: true,
            ),
            child: BotCheckScreen(controller: c),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('bot-check-art')), findsNothing);
      // Question and answer field are visible above the keyboard.
      final field = find.byKey(const ValueKey('bot-check-answer'));
      for (final target in [find.text(_question), field]) {
        expect(target.hitTestable(), findsOneWidget);
        expect(
          tester.getRect(target).bottom,
          lessThanOrEqualTo(size.height - keyboard),
        );
      }
      await tester.enterText(field, 'Mannheim');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.textContaining('Das passt leider nicht'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  test('the picture shrinks before it gives way', () {
    expect(BotCheckScreen.artHeight(1200), 180);
    expect(BotCheckScreen.artHeight(700), closeTo(132, 0.01));
    expect(BotCheckScreen.artHeight(620), closeTo(84, 0.01));
    expect(BotCheckScreen.artHeight(600), 0);
    expect(BotCheckScreen.artHeight(360), 0);
  });

  testWidgets('the screen stays readable on a narrow phone with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = await _controller(_Server());
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: BotCheckScreen(controller: c),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Weiter'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Weiter'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
