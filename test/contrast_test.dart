import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/app/theme/stage_theme.dart';
import 'package:theater_app/features/events/ui/event_style.dart';
import 'package:theater_app/shared/widgets/state_pill.dart';

/// WCAG AA: normal text, large text and UI components / icons.
const _text = 4.5, _ui = 3.0;

String _hex(Color c) =>
    '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}';

void _expectContrast(Color fg, Color bg, double minimum, String what) {
  final ratio = StageTheme.contrast(fg, bg);
  expect(
    ratio,
    greaterThanOrEqualTo(minimum),
    reason:
        '$what: ${_hex(fg)} on ${_hex(bg)} is '
        '${ratio.toStringAsFixed(2)}:1, needs $minimum:1',
  );
}

/// The opaque surfaces text sits on in [brightness].
Map<String, Color> _surfaces(Brightness brightness) {
  final theme = StageTheme.build(brightness);
  return {'surface': theme.colorScheme.surface, 'card': theme.cardTheme.color!};
}

/// [accent] as a tinted label: its fill over the label base.
Color _pillBackground(Color accent, Brightness brightness) => Color.alphaBlend(
  StageTheme.tintedLabel(accent, brightness).fill,
  StageTheme.labelBase(brightness),
);

void main() {
  test('contrast follows the WCAG formula', () {
    expect(StageTheme.contrast(Colors.black, Colors.white), closeTo(21, .01));
    expect(StageTheme.contrast(Colors.white, Colors.white), 1);
  });

  for (final brightness in Brightness.values) {
    final name = brightness.name;
    final theme = StageTheme.build(brightness);
    final scheme = theme.colorScheme;
    final surfaces = _surfaces(brightness);

    group('$name theme', () {
      test('text roles reach 4.5:1 on surface and cards', () {
        for (final MapEntry(key: where, value: bg) in surfaces.entries) {
          _expectContrast(scheme.onSurface, bg, _text, 'onSurface/$where');
          _expectContrast(
            scheme.onSurfaceVariant,
            bg,
            _text,
            'onSurfaceVariant/$where',
          );
          // Text links and buttons such as „Profil bearbeiten“.
          _expectContrast(scheme.primary, bg, _text, 'primary/$where');
          _expectContrast(scheme.secondary, bg, _text, 'secondary/$where');
          _expectContrast(scheme.error, bg, _text, 'error/$where');
        }
        _expectContrast(scheme.onPrimary, scheme.primary, _text, 'onPrimary');
        _expectContrast(
          scheme.onSurface,
          StageTheme.selectedTint(brightness),
          _text,
          'selected chip label',
        );
        final tooltip = theme.tooltipTheme;
        _expectContrast(
          tooltip.textStyle!.color!,
          (tooltip.decoration! as BoxDecoration).color!,
          _text,
          'tooltip',
        );
      });

      test('outlines and the brand orange reach 3:1 as UI elements', () {
        for (final MapEntry(key: where, value: bg) in surfaces.entries) {
          _expectContrast(scheme.outline, bg, _ui, 'outline/$where');
          _expectContrast(StageTheme.orange, bg, _ui, 'orange/$where');
        }
      });

      test('accent tones reach 4.5:1 as text and on their tint', () {
        final tones = {
          'orange': StageTheme.orangeTone,
          'green': StageTheme.greenTone,
          'violet': StageTheme.violetTone,
          'amber': StageTheme.amberTone,
          'red': StageTheme.redTone,
          'neutral': StageTheme.neutralTone,
        };
        for (final MapEntry(key: tone, value: pair) in tones.entries) {
          final fg = pair.of(brightness);
          for (final MapEntry(key: where, value: bg) in surfaces.entries) {
            _expectContrast(fg, bg, _text, '$tone/$where');
          }
          // The tone itself needs no further shifting inside a pill.
          _expectContrast(
            fg,
            _pillBackground(fg, brightness),
            _text,
            '$tone pill',
          );
        }
      });

      test('brand accents switch to their tone as text', () {
        for (final (accent, tone) in [
          (StageTheme.orange, StageTheme.orangeTone),
          (StageTheme.green, StageTheme.greenTone),
          (StageTheme.violet, StageTheme.violetTone),
          (StageTheme.amber, StageTheme.amberTone),
        ]) {
          expect(
            StageTheme.accentText(accent, brightness),
            tone.of(brightness),
          );
          expect(
            StageTheme.tintedLabel(accent, brightness).foreground,
            tone.of(brightness),
          );
        }
      });

      test('every status label colour is legible on its tint', () {
        final dark = brightness == Brightness.dark;
        final accents = <String, Color>{
          'orange': StageTheme.orange,
          'green': StageTheme.green,
          'violet': StageTheme.violet,
          'amber': StageTheme.amber,
          'outline': scheme.outline,
          'onSurfaceVariant': scheme.onSurfaceVariant,
          'error': scheme.error,
          'tertiary': scheme.tertiary,
          'primary': scheme.primary,
          for (final s in ['yes', 'late', 'no', 'open'])
            'response $s': responseColor(s, dark: dark),
          for (final k in ['performance', 'dress', 'rehearsal', 'meeting'])
            'kind $k': eventKindColor(k, dark: dark),
        };
        for (final MapEntry(key: what, value: accent) in accents.entries) {
          _expectContrast(
            StageTheme.tintedLabel(accent, brightness).foreground,
            _pillBackground(accent, brightness),
            _text,
            '$what pill',
          );
        }
      });

      testWidgets('StatePill draws its label in the legible tone', (
        tester,
      ) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: const Scaffold(
              body: StatePill(
                'Offen',
                color: StageTheme.orange,
                icon: Icons.schedule,
              ),
            ),
          ),
        );
        final text = tester.widget<Text>(find.text('Offen'));
        final icon = tester.widget<Icon>(find.byIcon(Icons.schedule));
        expect(text.style!.color, StageTheme.orangeTone.of(brightness));
        expect(icon.color, text.style!.color);
        _expectContrast(
          text.style!.color!,
          _pillBackground(StageTheme.orange, brightness),
          _text,
          'StatePill',
        );
      });
    });
  }

  test('white text on orange fills and accents on ink cards', () {
    _expectContrast(Colors.white, StageTheme.orangeDeep, _text, 'orangeDeep');
    _expectContrast(StageTheme.orangeDeep, StageTheme.ink, _ui, 'orange fill');
    _expectContrast(StageTheme.orange, StageTheme.ink, _ui, 'orange border');
    _expectContrast(StageTheme.onInkAccent, StageTheme.ink, _text, 'ink text');
    // Light-theme marker on cards: primary with onPrimary.
    final light = StageTheme.build(Brightness.light).colorScheme;
    _expectContrast(light.onPrimary, light.primary, _text, 'marker');
  });

  test('legible keeps the hue and only shifts when needed', () {
    const bg = StageTheme.cream;
    expect(StageTheme.legible(StageTheme.ink, bg), StageTheme.ink);
    final shifted = StageTheme.legible(StageTheme.orange, bg);
    expect(StageTheme.contrast(shifted, bg), greaterThanOrEqualTo(_text));
    expect(
      HSLColor.fromColor(shifted).hue,
      closeTo(HSLColor.fromColor(StageTheme.orange).hue, 1),
    );
    final lifted = StageTheme.legible(StageTheme.green, StageTheme.inkCard);
    expect(
      StageTheme.contrast(lifted, StageTheme.inkCard),
      greaterThanOrEqualTo(_text),
    );
  });
}
