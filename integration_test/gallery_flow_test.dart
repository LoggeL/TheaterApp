import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:theater_app/main.dart' as app;
import 'package:theater_app/core/models.dart';
import 'package:theater_app/ui/calendar.dart';
import 'package:theater_app/ui/galleries.dart';
import 'package:theater_app/ui/profile.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real Firebase profile, calendar, Immich gallery and original bytes on Android',
    (tester) async {
      const email = String.fromEnvironment('QA_EMAIL'),
          password = String.fromEnvironment('QA_PASSWORD');
      expect(
        email.endsWith('@theater.test'),
        true,
        reason: 'Use only a disposable QA account.',
      );
      final semantics = tester.ensureSemantics();

      await app.main();
      Future<void> waitFor(Finder finder) async {
        for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(finder, findsWidgets);
      }

      for (
        var i = 0;
        i < 200 &&
            find.text('Anmelden').evaluate().isEmpty &&
            find.text('Heute').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      if (find.text('Heute').evaluate().isNotEmpty) {
        final existing = tester
            .widget<app.TheaterApp>(find.byType(app.TheaterApp))
            .controller;
        expect(existing.user!.email, email);
        await existing.logout();
        await tester.pumpAndSettle();
      }
      await waitFor(find.text('Anmelden'));
      await tester.enterText(find.byType(TextFormField).at(0), email);
      await tester.enterText(find.byType(TextFormField).at(1), password);
      await tester.tap(find.text('Anmelden'));
      await waitFor(find.text('Heute'));
      final c = tester
          .widget<app.TheaterApp>(find.byType(app.TheaterApp))
          .controller;
      expect(c.user!.email, email);
      await tester.tap(find.text('Termine'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kalender'));
      await tester.pumpAndSettle();
      expect(find.byType(RehearsalCalendar), findsOneWidget);
      await tester.tap(find.byTooltip('Vorheriger Monat'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final source = await rootBundle.load(
        'assets/brand/kolpingtheater-ramsen.png',
      );
      final uploaded = await c.remote(
        '/media',
        method: 'POST',
        body: {
          'kind': 'profile',
          'content': base64Encode(source.buffer.asUint8List()),
        },
      );
      await c.saveProfile(
        tagline: 'Temporäre Geräteprüfung',
        avatarId: textValue(uploaded['id']),
        version: c.user!.profileVersion,
      );
      expect(c.user!.avatarId, uploaded['id']);
      final profileBytes = await c.mediaBytes('/media/${uploaded['id']}');
      expect(profileBytes.mime, 'image/webp');
      expect(profileBytes.bytes.length, greaterThan(1000));
      await tester.tap(find.text('Mein Bereich'));
      await tester.pumpAndSettle();
      expect(find.text('Temporäre Geräteprüfung'), findsOneWidget);
      await tester.tap(find.text('Profil bearbeiten'));
      await tester.pumpAndSettle();
      expect(find.byType(ProfileScreen), findsOneWidget);
      await tester.enterText(
        find.byType(TextField),
        'Profil auf Android geprüft',
      );
      await tester.tap(find.text('Speichern'));
      await waitFor(find.text('Mein Bereich.'));
      expect(c.user!.tagline, 'Profil auf Android geprüft');
      await tester.tap(find.text('Galerien'));
      await waitFor(find.text('Unsere Erinnerungen.'));
      await tester.tap(find.text('Sommerstück 2026'));
      await waitFor(find.text('3970 Aufnahmen'));
      await waitFor(find.bySemanticsLabel('Aufnahme 1 öffnen'));
      await tester.tap(find.bySemanticsLabel('Aufnahme 1 öffnen'));
      await waitFor(find.text('1 / 3970'));
      expect(find.byType(GalleryLightbox), findsOneWidget);
      await tester.tap(find.byTooltip('Nächstes Bild'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 3970'), findsOneWidget);
      final galleries = jsonList(
        (await c.remote('/galleries'))['galleries'],
      ).map(jsonMap);
      final gallery = galleries.firstWhere(
        (g) =>
            g['sourceUrl'] ==
            'https://photo.rittmann.cloud/s/sommerstueck-2026',
      );
      final page = await c.remote(
        '/galleries/${gallery['id']}?offset=0&limit=1',
      );
      final asset = jsonMap(jsonList(page['assets']).first);
      final original = await c.mediaBytes(
        '${asset['path']}/original',
        cache: false,
      );
      expect(original.mime, 'image/jpeg');
      expect(original.bytes.length, greaterThan(3000000));
      expect(tester.takeException(), isNull);
      await c.logout();
      await tester.pumpAndSettle();
      semantics.dispose();
    },
  );
}
