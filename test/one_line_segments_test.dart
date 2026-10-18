import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/features/feedback/feedback.dart';
import 'package:theater_app/shared/widgets/one_line_segmented_button.dart';

import 'app_controller_test.dart' show TestServer, signIn;

/// The bundled Roboto, so label widths match the real app instead of the
/// square test font.
Future<void> _loadRoboto() async {
  final loader = FontLoader('Roboto');
  for (final weight in ['Regular', 'Medium', 'Bold']) {
    final bytes = File(
      'assets/fonts/roboto/Roboto-$weight.ttf',
    ).readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

void _screen(WidgetTester tester, double width, double textScale) {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Number of lines [text] occupies inside [within].
int _lines(WidgetTester tester, Finder within, String text) {
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: within, matching: find.text(text)),
  );
  expect(paragraph.didExceedMaxLines, isFalse, reason: text);
  return paragraph
      .getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: text.length),
      )
      .map((box) => box.top)
      .toSet()
      .length;
}

void main() {
  setUpAll(_loadRoboto);

  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('feedback categories stay on one line at $width dp, '
          'text scale $scale', (tester) async {
        final controller = TestServer().controller();
        addTearDown(controller.dispose);
        await signIn(controller);
        _screen(tester, width, scale);
        await tester.pumpWidget(
          MaterialApp(
            theme: StageTheme.build(Brightness.dark),
            home: FeedbackFormScreen(controller: controller),
          ),
        );
        await tester.pumpAndSettle();

        final choice = find.byKey(const ValueKey('feedback-category'));
        for (final label in ['Idee', 'Fehler', 'Sonstiges']) {
          expect(_lines(tester, choice, label), 1, reason: label);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  // Further choices in the app, measured at the content width of a 320 dp
  // and a 390 dp phone and inside the settings card.
  const choices = <String, List<(String, IconData?)>>{
    'Farbschema': [
      ('System', Icons.brightness_auto_outlined),
      ('Hell', Icons.light_mode_outlined),
      ('Dunkel', Icons.dark_mode_outlined),
    ],
    'Kommunikation': [
      ('Mitteilungen · 3', Icons.chat_bubble_outline),
      ('Abstimmungen · 2 offen', Icons.poll_outlined),
    ],
    'Abstimmungsart': [
      ('Anonym', Icons.visibility_off_outlined),
      ('Namentlich', Icons.people_outline),
    ],
    'Szenenplanung': [('Nach Anwesenheit', null), ('Nach Rückmeldungen', null)],
    'Mitteilungen': [('Alle', null), ('Ungelesen · 12', null)],
  };
  for (final width in [240.0, 272.0, 342.0]) {
    for (final scale in [1.0, 1.3]) {
      testWidgets('segment labels stay on one line in $width px, '
          'text scale $scale', (tester) async {
        _screen(tester, 400, scale);
        for (final MapEntry(key: name, value: segments) in choices.entries) {
          await tester.pumpWidget(
            MaterialApp(
              theme: StageTheme.build(Brightness.dark),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: OneLineSegmentedButton<int>(
                        key: ValueKey(name),
                        segments: [
                          for (final (i, (label, icon)) in segments.indexed)
                            ButtonSegment(
                              value: i,
                              label: Text(label),
                              icon: icon == null ? null : Icon(icon),
                            ),
                        ],
                        selected: const {0},
                        onSelectionChanged: (_) {},
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          for (final (label, _) in segments) {
            expect(
              _lines(tester, find.byKey(ValueKey(name)), label),
              1,
              reason: '$name: $label',
            );
          }
          expect(tester.takeException(), isNull, reason: name);
        }
      });
    }
  }

  testWidgets('icons stay when there is room for them', (tester) async {
    _screen(tester, 800, 1);
    await tester.pumpWidget(
      MaterialApp(
        theme: StageTheme.build(Brightness.dark),
        home: Scaffold(
          body: OneLineSegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: 0,
                label: Text('Idee'),
                icon: Icon(Icons.lightbulb_outline),
              ),
              ButtonSegment(
                value: 1,
                label: Text('Sonstiges'),
                icon: Icon(Icons.chat_bubble_outline),
              ),
            ],
            selected: const {0},
            onSelectionChanged: (_) {},
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.lightbulb_outline), findsOneWidget);
    expect(find.byIcon(Icons.chat_bubble_outline), findsOneWidget);
  });
}
