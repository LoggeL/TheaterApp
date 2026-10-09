import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/ui/app_navigation.dart';

import 'app_controller_test.dart' show TestServer, signIn;

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
}
