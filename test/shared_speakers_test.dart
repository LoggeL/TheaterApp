import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/features/casting/casting.dart';
import 'package:theater_app/features/scripts/scripts.dart';

// A line Romeo and Julia speak together, as the server sends it.
final script = ScriptDocument.fromJson({
  'productionId': 'romeo',
  'revision': 'script-v1-test',
  'roles': [
    {'id': 'ROMEO', 'name': 'Romeo Montague'},
    {'id': 'JULIA', 'name': 'Julia Capulet'},
    {'id': 'AMME', 'name': 'Amme'},
  ],
  'scenes': [
    {'id': '1', 'title': 'Balkon', 'ordinal': 0},
  ],
  'cues': [
    {
      'id': 'amme',
      'sceneId': '1',
      'ordinal': 0,
      'category': 'dialogue',
      'role': 'AMME',
      'roles': ['AMME'],
      'text': 'Kinder, es ist spät.',
    },
    {
      'id': 'together',
      'sceneId': '1',
      'ordinal': 1,
      'category': 'dialogue',
      'role': 'ROMEO & JULIA',
      'roles': ['ROMEO', 'JULIA'],
      'text': 'Das würde mich glücklich machen.',
    },
    {
      'id': 'romeo',
      'sceneId': '1',
      'ordinal': 2,
      'category': 'dialogue',
      'role': 'ROMEO',
      'roles': ['ROMEO'],
      'text': 'Gute Nacht.',
    },
  ],
});

void main() {
  test('a shared cue keeps its label and lists every speaker', () {
    final cue = script.cues[1];
    expect(cue.role, 'ROMEO & JULIA');
    expect(cue.roles, ['ROMEO', 'JULIA']);
    expect(cue.spokenByAny({'julia'}), isTrue);
    expect(cue.spokenByAny({'AMME'}), isFalse);
    // Offline copies keep both speakers.
    expect(ScriptCue.fromJson(cue.toJson()).roles, ['ROMEO', 'JULIA']);
  });

  test('cues from older servers fall back to their single role', () {
    final cue = ScriptCue.fromJson({
      'id': 'old',
      'sceneId': '1',
      'ordinal': 0,
      'category': 'dialogue',
      'role': 'ROMEO',
    });
    expect(cue.roles, ['ROMEO']);
    expect(
      ScriptCue.fromJson({
        'id': 'direction',
        'sceneId': '1',
        'ordinal': 1,
        'category': 'direction',
        'roles': [],
      }).roles,
      isEmpty,
    );
  });

  test('"Meine Texte" shows a shared cue for each of its roles', () {
    for (final role in ['ROMEO', 'JULIA']) {
      expect(
        visibleScriptCues(
          script,
          mode: 'actor',
          roles: {role},
          contextLines: 0,
        ).map((cue) => cue.id),
        contains('together'),
        reason: role,
      );
    }
    // With context, the line before is the cue word (Stichwort) for Julia.
    expect(
      visibleScriptCues(
        script,
        mode: 'actor',
        roles: {'JULIA'},
        contextLines: 1,
      ).map((cue) => cue.id),
      ['amme', 'together', 'romeo'],
    );
  });

  test('scene roles and line counts include every speaker of a shared cue', () {
    expect(script.scenes.single.roles, ['AMME', 'ROMEO', 'JULIA']);
    final counts = roleLineCounts(script);
    expect(linesOf(script.roles[0], counts), 2);
    expect(linesOf(script.roles[1], counts), 1);
    expect(counts.keys, isNot(contains(normalizeName('ROMEO & JULIA'))));
  });
}
