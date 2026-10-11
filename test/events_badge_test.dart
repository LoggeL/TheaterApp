import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/features/events/events.dart';

import 'app_controller_test.dart' show TestServer, signIn;

/// An admin with a person record in role-1.
class _AdminServer extends TestServer {
  @override
  JsonMap get user => {
    ...super.user,
    'personId': 1,
    'roleIds': ['role-1'],
  };
}

void main() {
  test(
    'the events badge counts open responses of the next two weeks',
    () async {
      final now = DateTime.now();
      String at(int days) =>
          now.add(Duration(days: days)).toUtc().toIso8601String();
      final server = TestServer();
      server.data['attendanceByEvent'] = {};
      server.data['events'] = [
        for (final (id, days) in [
          ('soon', 3),
          ('edge', 13),
          ('later', 20),
          ('past', -2),
        ])
          {
            'id': id,
            'title': id,
            'startsAt': at(days),
            'endsAt': now
                .add(Duration(days: days, hours: 2))
                .toUtc()
                .toIso8601String(),
          },
      ];
      final controller = server.controller();
      await signIn(controller);
      expect(controller.events.where((e) => e.needsResponse), hasLength(4));
      expect(unansweredSoon(controller, now), 2);
      controller.dispose();
    },
  );

  for (final flagged in [true, false]) {
    test(
      'admins only count events they are invited to '
      '(${flagged ? 'server flag' : 'fallback for older servers'})',
      () async {
        final now = DateTime.now();
        JsonMap event(String id, List<String> roles, {bool? addressed}) => {
          'id': id,
          'title': id,
          'startsAt': now
              .add(const Duration(days: 2))
              .toUtc()
              .toIso8601String(),
          'endsAt': now
              .add(const Duration(days: 2, hours: 2))
              .toUtc()
              .toIso8601String(),
          'roleIds': roles,
          if (flagged) 'addressedToMe': ?addressed,
        };
        final server = _AdminServer();
        server.data['attendanceByEvent'] = {};
        server.data['events'] = [
          event('mine', ['role-1'], addressed: true),
          event('technik', ['role-3'], addressed: false),
          event('all', [], addressed: true),
        ];
        final controller = server.controller();
        await signIn(controller);
        expect(unansweredSoon(controller, now), 2);
        expect(
          controller.events.firstWhere((e) => e.id == 'technik').addressedToMe,
          isFalse,
        );
        controller.dispose();
      },
    );
  }
}
