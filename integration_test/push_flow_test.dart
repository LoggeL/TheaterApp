import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:theater_app/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Production Firebase login and real FCM foreground delivery', (
    tester,
  ) async {
    await app.main();
    Future<void> waitFor(Finder f) async {
      for (var i = 0; i < 200 && f.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(f, findsWidgets);
    }

    await waitFor(find.text('Anmelden'));
    await tester.enterText(
      find.byType(TextFormField).at(0),
      const String.fromEnvironment('QA_EMAIL'),
    );
    await tester.enterText(
      find.byType(TextFormField).at(1),
      const String.fromEnvironment('QA_PASSWORD'),
    );
    await tester.tap(find.text('Anmelden'));
    await waitFor(find.text('Heute'));
    final c = tester
        .widget<app.TheaterApp>(find.byType(app.TheaterApp))
        .controller;
    expect(c.hasAccess, isTrue);
    final messaging = FirebaseMessaging.instance;
    final token = await messaging.getToken();
    expect(token, isNotNull);
    await c.registerDevice(token!, 'android');
    final received = Completer<RemoteMessage>();
    final sub = FirebaseMessaging.onMessage.listen((m) {
      if (!received.isCompleted) received.complete(m);
    });
    try {
      await c.performAction({'action': 'push.test'});
      final message = await received.future.timeout(
        const Duration(seconds: 75),
      );
      expect(message.notification?.title, 'Theater-App');
      expect(message.notification?.body, 'Deine Testbenachrichtigung ist da.');
      expect(tester.takeException(), isNull);
    } finally {
      await sub.cancel();
      await c.unregisterDevice(token);
      await messaging.deleteToken();
      await c.logout();
    }
  });
}
