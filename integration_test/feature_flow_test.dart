import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:theater_app/main.dart' as app;
import 'package:theater_app/core/models.dart';
import 'package:theater_app/ui/events.dart';
import 'package:theater_app/ui/polls.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native roles, descriptions, general vote and profile upload round trip',
    (tester) async {
      await app.main();
      Future<void> waitFor(Finder finder) async {
        for (var i = 0; i < 150 && finder.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(finder, findsWidgets);
      }

      await waitFor(find.text('Anmelden'));
      await tester.enterText(
        find.byType(TextFormField).at(0),
        'admin@theater.test',
      );
      await tester.enterText(
        find.byType(TextFormField).at(1),
        'TheaterProbe!2026',
      );
      await tester.tap(find.text('Anmelden'));
      await waitFor(find.text('Heute'));
      final c = tester
          .widget<app.TheaterApp>(find.byType(app.TheaterApp))
          .controller;
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final title = 'Werkstatt $stamp';
      await c.performAction({
        'action': 'event.save',
        'title': title,
        'description': 'Werkzeug mitbringen',
        'type': 'setup',
        'startsAt': '2027-09-17T17:00:00Z',
        'endsAt': '2027-09-17T19:00:00Z',
      });
      final event = c.events.firstWhere((e) => e.title == title);
      expect(event.kind, 'setup');
      expect(event.description, 'Werkzeug mitbringen');
      final person = c.memberRecords.firstWhere(
        (m) => m['id'] == c.user!.personId,
      );
      final roles = c.personRoles.take(2).map((r) => r['id']).toList();
      await c.performAction({
        ...person,
        'action': 'member.save',
        'roleIds': roles,
      });
      expect(c.user!.roleIds, roles);
      await c.performAction({
        'action': 'poll.save',
        'title': 'Essen $stamp',
        'options': [
          {'label': 'Pizza'},
          {'label': 'Pasta'},
        ],
      });
      final poll = c.polls.firstWhere((p) => p.title == 'Essen $stamp');
      final shellContext = tester.element(find.byType(app.AppShell));
      Navigator.of(shellContext).push(
        MaterialPageRoute(
          builder: (_) => EventDetailScreen(controller: c, eventId: event.id),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Werkzeug mitbringen'), findsOneWidget);
      expect(find.text('Aufbau'), findsOneWidget);
      await tester.tap(find.byTooltip('Zurück'));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(app.AppShell))).push(
        MaterialPageRoute(
          builder: (_) => PollDetailScreen(controller: c, pollId: poll.id),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pasta'));
      for (
        var i = 0;
        i < 100 &&
            c.polls.firstWhere((p) => p.id == poll.id).selectedOptionId == null;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      await c.refresh();
      final voted = c.polls.firstWhere((p) => p.id == poll.id);
      expect(voted.selectedOptionId, poll.options[1].id);
      expect(voted.totalVotes, 1);
      final source = await rootBundle.load(
        'assets/brand/kolpingtheater-ramsen.png',
      );
      final upload = await c.remote(
        '/media',
        method: 'POST',
        body: {
          'kind': 'profile',
          'content': base64Encode(source.buffer.asUint8List()),
        },
      );
      await c.saveProfile(
        avatarId: textValue(upload['id']),
        version: c.user!.profileVersion,
      );
      expect(c.user!.avatarId, upload['id']);
      expect((await c.mediaBytes('/media/${upload['id']}')).mime, 'image/webp');
      await c.performAction({
        'action': 'poll.close',
        'id': voted.id,
        'version': voted.version,
      });
      await c.performAction({
        'action': 'event.delete',
        'id': event.id,
        'version': event.version,
      });
      await c.logout();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
