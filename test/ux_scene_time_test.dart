import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/core/scene_planning.dart';

void main() {
  group('scene planning clock time', () {
    test('post-midnight plan includes an already arrived cast member', () {
      final start = DateTime(2026, 10, 7, 23);
      final at = scenePlanningTime(
        startsAt: start,
        endsAt: DateTime(2026, 10, 8, 1),
        hour: 0,
        minute: 30,
      );
      expect(at, DateTime(2026, 10, 8, 0, 30));
      final scene = ScriptScene.fromJson({
        'id': 's',
        'roles': ['ROMEO'],
      });
      final availability = evaluateScene(
        scene: scene,
        casting: {'ROMEO': 1},
        checkins: {},
        responses: {'1': 'late'},
        arrivals: {'1': DateTime(2026, 10, 8, 0, 15).toIso8601String()},
        useCheckins: false,
        at: at,
      );
      expect(availability.playable, isTrue);
      expect(availability.details, isEmpty);
    });

    test('the starting time and later evening times stay on the start day', () {
      final start = DateTime(2026, 10, 7, 23);
      for (final minute in [0, 30]) {
        expect(
          scenePlanningTime(
            startsAt: start,
            endsAt: DateTime(2026, 10, 8, 1),
            hour: 23,
            minute: minute,
          ),
          DateTime(2026, 10, 7, 23, minute),
        );
      }
    });

    test('same-day and undated ends do not imply a next-day selection', () {
      final start = DateTime(2026, 10, 7, 19);
      for (final end in [null, DateTime(2026, 10, 7, 21)]) {
        expect(
          scenePlanningTime(startsAt: start, endsAt: end, hour: 18, minute: 30),
          DateTime(2026, 10, 7, 18, 30),
        );
      }
    });

    test('overnight selection handles a year boundary and preserves UTC', () {
      final at = scenePlanningTime(
        startsAt: DateTime.utc(2026, 12, 31, 23),
        endsAt: DateTime.utc(2027, 1, 1, 1),
        hour: 0,
        minute: 30,
      );
      expect(at, DateTime.utc(2027, 1, 1, 0, 30));
      expect(at.isUtc, isTrue);
    });

    test('an end before the start does not roll the clock time forward', () {
      expect(
        scenePlanningTime(
          startsAt: DateTime(2026, 10, 7, 23),
          endsAt: DateTime(2026, 10, 6, 23),
          hour: 0,
          minute: 30,
        ),
        DateTime(2026, 10, 7, 0, 30),
      );
    });
  });
}
