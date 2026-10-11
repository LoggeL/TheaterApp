import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/data/local_store.dart';
import 'package:theater_app/features/auth/auth.dart';

import 'firebase_access_test.dart' show FakeIdentity;

class _RecordingIdentity extends FakeIdentity {
  Object? changeError;
  final resets = <String>[], unlinked = <String>[], added = <String>[];

  @override
  Future<void> changePassword(String oldPassword, String nextPassword) async {
    if (changeError != null) throw changeError!;
  }

  @override
  Future<void> resetPassword(String email) async => resets.add(email);

  @override
  Future<void> unlink(String provider) async {
    unlinked.add(provider);
    linkedProviders = linkedProviders.where((p) => p != provider).toList();
  }

  @override
  Future<void> addPassword(String password) async {
    added.add(password);
    linkedProviders = [...linkedProviders, 'password'];
  }
}

/// A controller signed in through [identity] with the given account state.
Future<AppController> _signedIn(
  _RecordingIdentity identity, {
  String status = 'approved',
  bool identityReady = true,
}) async {
  final controller = AppController(
    identity: identity,
    localStore: MemoryLocalStore(),
    credentialStore: MemoryCredentialStore(),
    apiClient: ApiClient(
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({
            'apiVersion': 1,
            'user': {
              'userId': identity.uid,
              'displayName': 'Test Person',
              'email': identity.email,
              'status': status,
              'role': 'member',
              'identityReady': identityReady,
              'emailVerified': identityReady,
              'needsRegistrationName': false,
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    ),
  );
  await controller.init();
  await controller.login(
    email: 'person@example.invalid',
    password: 'A long test password',
    baseUrl: 'https://theater.example.invalid',
  );
  return controller;
}

Future<void> _pump(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(600, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(theme: StageTheme.build(Brightness.light), home: screen),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('password change errors are explained without raw exceptions', () {
    expect(
      passwordChangeError(FirebaseAuthException(code: 'invalid-credential')),
      'Das aktuelle Passwort stimmt nicht.',
    );
    expect(
      passwordChangeError(FirebaseAuthException(code: 'wrong-password')),
      'Das aktuelle Passwort stimmt nicht.',
    );
    expect(
      passwordChangeError(FirebaseAuthException(code: 'requires-recent-login')),
      startsWith('Bitte melde dich neu an'),
    );
    expect(passwordChangeError(StateError('x')), isNot(contains('Bad state')));
  });

  testWidgets('the password form validates each field and maps errors', (
    tester,
  ) async {
    final identity = _RecordingIdentity()
      ..changeError = FirebaseAuthException(code: 'invalid-credential');
    final controller = await _signedIn(identity);
    addTearDown(controller.dispose);
    await _pump(tester, PasswordScreen(controller: controller));
    await tester.tap(find.text('Passwort speichern'));
    await tester.pump();
    expect(
      find.text('Bitte dein aktuelles Passwort eingeben.'),
      findsOneWidget,
    );
    expect(find.text('Mindestens 12 Zeichen.'), findsOneWidget);

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'altes Passwort');
    await tester.enterText(fields.at(1), 'ein neues langes Passwort');
    await tester.enterText(fields.at(2), 'ein anderes Passwort');
    await tester.tap(find.text('Passwort speichern'));
    await tester.pump();
    expect(find.text('Die Passwörter stimmen nicht überein.'), findsOneWidget);

    await tester.enterText(fields.at(2), 'ein neues langes Passwort');
    await tester.tap(find.text('Passwort speichern'));
    await tester.pumpAndSettle();
    expect(find.text('Das aktuelle Passwort stimmt nicht.'), findsOneWidget);
    expect(find.textContaining('FirebaseAuthException'), findsNothing);

    // The fields can be revealed.
    expect(find.byTooltip('Passwort anzeigen'), findsNWidgets(3));
    await tester.tap(find.byTooltip('Passwort anzeigen').first);
    await tester.pump();
    expect(find.byTooltip('Passwort verbergen'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the verify step offers a check and a resend, but no name form', (
    tester,
  ) async {
    final identity = _RecordingIdentity()..emailVerified = false;
    final controller = await _signedIn(
      identity,
      status: 'pending',
      identityReady: false,
    );
    addTearDown(controller.dispose);
    await _pump(tester, ApprovalPendingScreen(controller: controller));
    expect(find.text('E-Mail bestätigen'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.text('E-Mail erneut senden'), findsOneWidget);
    await tester.tap(find.text('Ich habe bestätigt – prüfen'));
    await tester.pumpAndSettle();
    expect(find.textContaining('noch nicht angekommen'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the waiting step reports when it last checked', (tester) async {
    final identity = _RecordingIdentity();
    final controller = await _signedIn(identity, status: 'pending');
    addTearDown(controller.dispose);
    await _pump(tester, ApprovalPendingScreen(controller: controller));
    expect(find.text('Freigabe ausstehend'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    await tester.tap(find.text('Status aktualisieren'));
    await tester.pumpAndSettle();
    expect(find.textContaining('zuletzt geprüft'), findsOneWidget);
    await tester.tap(find.text('Namen zur Zuordnung ändern'));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final (status, title) in [
    ('suspended', 'Zugang gesperrt'),
    ('rejected', 'Anfrage abgelehnt'),
  ]) {
    testWidgets('a $status account gets its own explanation', (tester) async {
      final identity = _RecordingIdentity();
      final controller = await _signedIn(identity, status: status);
      addTearDown(controller.dispose);
      await _pump(tester, ApprovalPendingScreen(controller: controller));
      expect(find.text(title), findsOneWidget);
      expect(find.byType(TextFormField), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('forgotten passwords are reset from a prefilled dialog', (
    tester,
  ) async {
    final identity = _RecordingIdentity();
    final controller = AppController(
      identity: identity,
      localStore: MemoryLocalStore(),
      credentialStore: MemoryCredentialStore(),
    );
    addTearDown(controller.dispose);
    await _pump(tester, FirebaseWelcomeScreen(controller: controller));
    await tester.enterText(
      find.byType(TextFormField).first,
      'person@example.invalid',
    );
    await tester.tap(find.text('Passwort vergessen?'));
    await tester.pumpAndSettle();
    expect(find.text('Passwort zurücksetzen'), findsOneWidget);
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextFormField),
    );
    expect(
      tester.widget<TextFormField>(dialogField).controller!.text,
      'person@example.invalid',
    );
    await tester.tap(find.text('Link senden'));
    await tester.pumpAndSettle();
    expect(identity.resets, ['person@example.invalid']);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('person@example.invalid'), findsWidgets);
    expect(find.byType(SnackBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unlinking asks first and names the remaining sign-in', (
    tester,
  ) async {
    final identity = _RecordingIdentity()
      ..linkedProviders = ['password', 'google.com'];
    final controller = await _signedIn(identity);
    addTearDown(controller.dispose);
    await _pump(tester, AccountProvidersScreen(controller: controller));
    await tester.tap(find.text('Entfernen'));
    await tester.pumpAndSettle();
    expect(find.text('Google entfernen?'), findsOneWidget);
    expect(
      find.text('Du meldest dich danach nur noch mit E-Mail & Passwort an.'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Entfernen'));
    await tester.pumpAndSettle();
    expect(identity.unlinked, ['google.com']);
    expect(find.text('Google wurde entfernt.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('adding a password validates length and repetition', (
    tester,
  ) async {
    final identity = _RecordingIdentity()..linkedProviders = ['google.com'];
    final controller = await _signedIn(identity);
    addTearDown(controller.dispose);
    await _pump(tester, AccountProvidersScreen(controller: controller));
    await tester.tap(find.text('Ergänzen'));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextFormField),
    );
    await tester.enterText(fields.at(0), 'kurz');
    await tester.tap(find.text('Speichern'));
    await tester.pump();
    expect(find.text('Mindestens 12 Zeichen.'), findsOneWidget);
    await tester.enterText(fields.at(0), 'ein langes Passwort');
    await tester.enterText(fields.at(1), 'etwas anderes');
    await tester.tap(find.text('Speichern'));
    await tester.pump();
    expect(find.text('Die Passwörter stimmen nicht überein.'), findsOneWidget);
    expect(identity.added, isEmpty);
    await tester.enterText(fields.at(1), 'ein langes Passwort');
    await tester.tap(find.text('Speichern'));
    await tester.pumpAndSettle();
    expect(identity.added, ['ein langes Passwort']);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('Passwort ergänzt'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
