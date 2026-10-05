import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/device_services.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/main.dart';
import 'package:theater_app/ui/auth.dart';
import 'package:theater_app/ui/firebase_auth.dart';
import 'package:theater_app/ui/theme.dart';

import 'firebase_access_test.dart' show FakeIdentity;

class _VerificationIdentity extends FakeIdentity {
  _VerificationIdentity() {
    emailVerified = false;
  }

  bool verifiedAtProvider = false;
  int reloads = 0;
  Completer<void>? reloadGate;
  Object? reloadError;

  @override
  Future<void> reload() async {
    reloads++;
    await reloadGate?.future;
    if (reloadError != null) throw reloadError!;
    emailVerified = verifiedAtProvider;
  }
}

AppController _controller([FakeIdentity? identity]) => AppController(
  identity: identity,
  localStore: MemoryLocalStore(),
  credentialStore: MemoryCredentialStore(),
  apiClient: ApiClient(
    client: MockClient((request) async {
      return http.Response(
        jsonEncode({
          'user': {
            'userId': identity?.uid,
            'displayName': 'Test Person',
            'email': identity?.email,
            'status': 'pending',
            'role': 'member',
            'identityReady': identity?.emailVerified ?? false,
            'emailVerified': identity?.emailVerified ?? false,
            'needsRegistrationName': false,
          },
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  ),
);

Future<void> _login(AppController controller) => controller.login(
  email: 'person@example.invalid',
  password: 'A long test password',
  baseUrl: 'https://theater.example.invalid',
);

void _narrowLargeText(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 740);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void _leaveApp(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void _returnToApp(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

Widget _largeTextApp(Widget screen) => MaterialApp(
  theme: StageTheme.build(Brightness.light),
  home: MediaQuery(
    data: const MediaQueryData(
      size: Size(320, 740),
      textScaler: TextScaler.linear(2),
    ),
    child: screen,
  ),
);

Future<void> _checkWholeForm(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
  final scrollable = find.byType(Scrollable).first;
  for (var page = 0; page < 8; page++) {
    await tester.drag(scrollable, const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }
}

void main() {
  test('invalid optional web parameters and deep-link UTF-8 are ignored', () {
    for (final url in [
      'https://theater.example.invalid/?other=%FF',
      'https://theater.example.invalid/?target=%FF',
      'https://theater.example.invalid/?target=%C3%28',
      'https://theater.example.invalid/?target=theaterapp%3A%2F%2Fapp%2Fevents%2F%25FF',
    ]) {
      expect(AppTarget.fromWebUri(Uri.parse(url)), isNull, reason: url);
    }
    for (final link in [
      'theaterapp://app/events/%FF',
      'theaterapp://app/events/%C3%28',
    ]) {
      expect(AppTarget.fromUri(Uri.parse(link)), isNull, reason: link);
      expect(AppTarget.fromData({'deepLink': link}), isNull, reason: link);
    }
    final valid = AppTarget.fromWebUri(
      Uri.parse(
        'https://theater.example.invalid/?target=theaterapp%3A%2F%2Fapp%2Fevents%2Fprobe-%25C3%25A4',
      ),
    );
    expect(valid?.kind, 'events');
    expect(valid?.id, 'probe-ä');
    expect(
      AppTarget.fromWebUri(
        Uri.parse('https://theater.example.invalid/?target=https://evil.test'),
      ),
      isNull,
    );
  });

  testWidgets('Firebase login and registration fit 320px at 200 percent text', (
    tester,
  ) async {
    _narrowLargeText(tester);
    final controller = _controller(FakeIdentity());
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _largeTextApp(FirebaseWelcomeScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    await _checkWholeForm(tester);
    await tester.scrollUntilVisible(
      find.text('Noch kein Konto? Registrieren'),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Noch kein Konto? Registrieren'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 5000));
    await tester.pumpAndSettle();
    expect(find.text('Konto erstellen'), findsWidgets);
    await _checkWholeForm(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('legacy welcome illustration grows with large text', (
    tester,
  ) async {
    _narrowLargeText(tester);
    final controller = _controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _largeTextApp(WelcomeScreen(controller: controller)),
    );
    await tester.pumpAndSettle();
    final title = tester.getRect(find.text('Kolpingtheater\nRamsen'));
    final hero = tester.getRect(find.byType(Stack).first);
    expect(hero.contains(title.topLeft), isTrue);
    expect(hero.contains(title.bottomRight), isTrue);
    await _checkWholeForm(tester);
    await tester.scrollUntilVisible(
      find.text('Mit Theaterkonto anmelden'),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Mit Theaterkonto anmelden'));
    await tester.pumpAndSettle();
    await _checkWholeForm(tester);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('returning from email reloads verification automatically', (
    tester,
  ) async {
    final identity = _VerificationIdentity();
    final controller = _controller(identity);
    addTearDown(controller.dispose);
    await controller.init();
    await _login(controller);
    await tester.pumpWidget(
      TheaterApp(controller: controller, enableDeviceServices: false),
    );
    await tester.pumpAndSettle();
    expect(find.text('E-Mail bestätigen'), findsOneWidget);
    final reloads = identity.reloads;
    _leaveApp(tester);
    identity.verifiedAtProvider = true;
    _returnToApp(tester);
    await tester.pumpAndSettle();
    expect(identity.reloads, reloads + 1);
    expect(controller.user!.identityReady, isTrue);
    expect(find.text('Freigabe ausstehend'), findsOneWidget);
    expect(find.text('E-Mail bestätigt'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('verification polling coalesces timer and resume checks', (
    tester,
  ) async {
    final identity = _VerificationIdentity();
    final controller = _controller(identity);
    addTearDown(controller.dispose);
    await controller.init();
    await _login(controller);
    await tester.pumpWidget(
      TheaterApp(controller: controller, enableDeviceServices: false),
    );
    await tester.pumpAndSettle();
    final reloads = identity.reloads;
    identity.reloadGate = Completer<void>();
    await tester.pump(const Duration(seconds: 45));
    expect(identity.reloads, reloads + 1);
    _leaveApp(tester);
    _returnToApp(tester);
    await tester.pump();
    expect(identity.reloads, reloads + 1);
    identity.verifiedAtProvider = true;
    identity.reloadGate!.complete();
    await tester.pumpAndSettle();
    expect(controller.user!.identityReady, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('failed automatic verification retains the screen and retries', (
    tester,
  ) async {
    final identity = _VerificationIdentity();
    final controller = _controller(identity);
    addTearDown(controller.dispose);
    await controller.init();
    await _login(controller);
    await tester.pumpWidget(
      TheaterApp(controller: controller, enableDeviceServices: false),
    );
    await tester.pumpAndSettle();
    identity.reloadError = const ApiException('Offline');
    _leaveApp(tester);
    _returnToApp(tester);
    await tester.pumpAndSettle();
    expect(find.text('E-Mail bestätigen'), findsOneWidget);
    expect(controller.user!.identityReady, isFalse);
    expect(tester.takeException(), isNull);
    identity.reloadError = null;
    identity.verifiedAtProvider = true;
    await tester.pump(const Duration(seconds: 45));
    await tester.pumpAndSettle();
    expect(find.text('Freigabe ausstehend'), findsOneWidget);
    expect(controller.user!.identityReady, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('native Done continues to validate the login form', (
    tester,
  ) async {
    final controller = _controller(FakeIdentity());
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: FirebaseWelcomeScreen(controller: controller)),
    );
    await tester.tap(find.byType(TextFormField).last);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(
      find.text('Bitte eine gültige E-Mail-Adresse eingeben.'),
      findsOneWidget,
    );
    expect(find.text('Bitte dein Passwort eingeben.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
