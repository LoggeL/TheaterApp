import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:theater_app/app/shell/app_navigation.dart';
import 'package:theater_app/main.dart';

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

Finder _inBar(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

void main() {
  setUpAll(() async {
    await initializeDateFormatting('de');
    await _loadRoboto();
  });

  const labels = ['Heute', 'Termine', 'Skript', 'Post', 'Ich'];

  for (final width in [320.0, 360.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('tab labels stay whole on one line at ${width.toInt()} dp, '
          'text scale $scale', (tester) async {
        _screen(tester, width, scale);
        final c = TestServer().controller();
        await signIn(c);
        await tester.pumpWidget(
          TheaterApp(controller: c, enableDeviceServices: false),
        );
        await tester.pumpAndSettle();
        final slot = width / labels.length;
        for (final label in labels) {
          final paragraph = tester.renderObject<RenderParagraph>(_inBar(label));
          expect(paragraph.maxLines, 1, reason: label);
          expect(paragraph.softWrap, isFalse, reason: label);
          // Fits without an ellipsis.
          expect(paragraph.didExceedMaxLines, isFalse, reason: label);
          expect(paragraph.size.width, lessThanOrEqualTo(slot), reason: label);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      });
    }
  }

  testWidgets('short tab labels keep the full section name for screen '
      'readers and in the tooltip', (tester) async {
    _screen(tester, 390, 1);
    final semantics = tester.ensureSemantics();
    final c = TestServer().controller();
    await signIn(c);
    await tester.pumpWidget(
      TheaterApp(controller: c, enableDeviceServices: false),
    );
    await tester.pumpAndSettle();
    for (final (label, name) in [
      ('Skript', 'Drehbücher'),
      ('Post', 'Mitteilungen'),
      ('Ich', 'Mein Bereich'),
    ]) {
      final node = tester.getSemantics(_inBar(label));
      // Voice control finds the visible word; the tooltip adds the full name.
      expect(node.label, startsWith(label));
      expect(node.tooltip, name);
      expect(find.byTooltip(RegExp('^$name')), findsOneWidget);
    }
    // Where label and name are the same, nothing is added.
    expect(tester.getSemantics(_inBar('Heute')).tooltip, isEmpty);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('the rail keeps labels on one line with the full name', (
    tester,
  ) async {
    _screen(tester, 1000, 1.3);
    final semantics = tester.ensureSemantics();
    final c = TestServer().controller();
    await signIn(c);
    await tester.pumpWidget(
      TheaterApp(controller: c, enableDeviceServices: false),
    );
    await tester.pumpAndSettle();
    final skript = find.descendant(
      of: find.byType(AppNavigationRail),
      matching: find.text('Skript'),
    );
    final paragraph = tester.renderObject<RenderParagraph>(skript);
    expect(paragraph.maxLines, 1);
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(tester.getSemantics(skript).tooltip, 'Drehbücher');
    expect(find.byTooltip('Drehbücher'), findsOneWidget);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('a label too long for its tab ends with an ellipsis', (
    tester,
  ) async {
    _screen(tester, 320, 1.5);
    const long = 'Mitteilungsübersicht';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: AppNavigationBar(
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            destinations: [
              for (final label in ['Heute', 'Termine', long, 'Post', 'Ich'])
                NavigationDestination(
                  icon: const Icon(Icons.star),
                  label: label,
                ),
            ],
          ),
        ),
      ),
    );
    final paragraph = tester.renderObject<RenderParagraph>(find.text(long));
    expect(paragraph.maxLines, 1);
    expect(paragraph.didExceedMaxLines, isTrue);
    expect(paragraph.size.width, lessThanOrEqualTo(320 / 5));
    expect(tester.takeException(), isNull);
  });
}
