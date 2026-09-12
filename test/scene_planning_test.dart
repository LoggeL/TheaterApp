import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/core/scene_planning.dart';

void main() {
  final scene = ScriptScene.fromJson({
    'id': 's1',
    'title': 'Probe',
    'roles': ['LENA', 'OSKAR'],
  });
  final at = DateTime.utc(2026, 9, 13, 18);
  SceneAvailability evaluate({
    bool actual = false,
    JsonMap checkins = const {},
    JsonMap responses = const {'1': 'yes', '2': 'late'},
    JsonMap arrivals = const {},
    JsonMap casting = const {'LENA': 1, 'OSKAR': 2},
  }) => evaluateScene(
    scene: scene,
    casting: casting,
    checkins: checkins,
    responses: responses,
    arrivals: arrivals,
    useCheckins: actual,
    at: at,
  );
  test(
    'late without ETA remains unknown',
    () => expect(evaluate().status, 'unknown'),
  );
  test('late arrival is available at exactly the announced time', () {
    expect(
      evaluate(
        arrivals: {'2': at.add(const Duration(minutes: 1)).toIso8601String()},
      ).status,
      'missing',
    );
    expect(evaluate(arrivals: {'2': at.toIso8601String()}).status, 'playable');
  });
  test('a promise and ETA never become a physical check-in', () {
    expect(
      evaluate(actual: true, arrivals: {'2': at.toIso8601String()}).status,
      'unknown',
    );
    expect(
      evaluate(actual: true, checkins: {'1': true, '2': false}).status,
      'missing',
    );
    expect(
      evaluate(
        actual: true,
        checkins: {'1': true, '2': true},
        responses: {'1': 'no', '2': 'no'},
      ).playable,
      isTrue,
    );
  });
  test(
    'one person may cover multiple roles but an uncast role stays unknown',
    () {
      expect(evaluate(casting: {'LENA': 1, 'OSKAR': 1}).playable, isTrue);
      expect(evaluate(casting: {'LENA': 1}).status, 'unknown');
    },
  );
}
