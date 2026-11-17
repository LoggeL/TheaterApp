import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Words that must not ship in the app: what the admins plan for later
/// stays on the server, which sends its labels with the admin catalog.
final _forbidden = RegExp(
  r'advent|türchen|weihnachtsedition|2\.\s*kostüm|zweites\s+kostüm|kuschel--weihnachten',
  caseSensitive: false,
);

/// Everything that goes into the web and Android bundles as source or text.
const _shipped = ['lib', 'web', 'android/app/src/main'];

void main() {
  test('the app sources carry no word of unannounced content', () {
    final hits = <String>[];
    for (final root in _shipped) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final file in dir.listSync(recursive: true).whereType<File>()) {
        final path = file.path.replaceAll(r'\', '/');
        if (_forbidden.hasMatch(path)) hits.add(path);
        final String text;
        try {
          text = utf8.decode(file.readAsBytesSync());
        } on FormatException {
          continue; // Pictures and other binaries.
        }
        for (final (index, line)
            in const LineSplitter().convert(text).indexed) {
          if (_forbidden.hasMatch(line)) hits.add('$path:${index + 1}: $line');
        }
      }
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });
}
