import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/pwa_install.dart';
import 'package:theater_app/ui/pwa_install.dart';

class Installation extends PwaInstallation {
  Installation({
    this.platform = 'desktop',
    this.promptAvailable = false,
    this.inApp = false,
  });
  final String platform;
  final bool inApp;
  bool promptAvailable;
  bool done = false, hidden = false;
  int prompts = 0;
  @override
  bool get available => true;
  @override
  bool get installed => done;
  @override
  bool get canPrompt => promptAvailable;
  @override
  String get devicePlatform => platform;
  @override
  bool get embedded => inApp;
  @override
  bool get dismissed => hidden;
  @override
  void dismiss() {
    hidden = true;
    notifyListeners();
  }

  @override
  Future<bool> prompt() async {
    prompts++;
    done = true;
    notifyListeners();
    return true;
  }
}

Widget preview(PwaInstallation installation, {bool homeHint = false}) =>
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PwaInstallCard(installation: installation, homeHint: homeHint),
        ),
      ),
    );

void main() {
  testWidgets('native apps do not offer a second web installation', (
    tester,
  ) async {
    await tester.pumpWidget(preview(PwaInstallation()));
    expect(find.text('Theater-App installieren'), findsNothing);
  });
  testWidgets(
    'supported install invokes the prompt and hides the card after acceptance',
    (tester) async {
      final installation = Installation(promptAvailable: true);
      await tester.pumpWidget(preview(installation));
      await tester.tap(find.text('Installieren'));
      await tester.pumpAndSettle();
      expect(installation.prompts, 1);
      expect(find.text('Theater-App installieren'), findsNothing);
    },
  );
  testWidgets(
    'iOS shows usable manual installation instructions at mobile width',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final installation = Installation(platform: 'ios');
      await tester.pumpWidget(preview(installation));
      await tester.tap(find.text('Installationsanleitung'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Zum Home-Bildschirm'), findsOneWidget);
      expect(installation.prompts, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('iOS in-app browsers are first sent to Safari', (tester) async {
    await tester.pumpWidget(
      preview(Installation(platform: 'ios', inApp: true)),
    );
    await tester.tap(find.text('Installationsanleitung'));
    await tester.pumpAndSettle();
    expect(find.text('1. In Safari öffnen'), findsOneWidget);
    expect(find.text('2. Teilen antippen'), findsOneWidget);
  });
  testWidgets('home hint appears only on iOS and stays dismissed', (
    tester,
  ) async {
    await tester.pumpWidget(preview(Installation(), homeHint: true));
    expect(find.text('Zum Home-Bildschirm hinzufügen'), findsNothing);
    final installation = Installation(platform: 'ios');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(preview(installation, homeHint: true));
    expect(find.text('Zum Home-Bildschirm hinzufügen'), findsOneWidget);
    await tester.tap(find.byTooltip('Hinweis ausblenden'));
    await tester.pump();
    expect(installation.hidden, isTrue);
    expect(find.text('Zum Home-Bildschirm hinzufügen'), findsNothing);
  });
}
