import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/pwa_install.dart';
import 'package:theater_app/ui/pwa_install.dart';

class Installation extends PwaInstallation {
  Installation({this.platform = 'desktop', this.promptAvailable = false});
  final String platform;
  bool promptAvailable;
  bool done = false;
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
  Future<bool> prompt() async {
    prompts++;
    done = true;
    notifyListeners();
    return true;
  }
}

Widget preview(PwaInstallation installation) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: PwaInstallCard(installation: installation),
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
}
