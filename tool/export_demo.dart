import 'dart:convert';
import 'dart:io';
import 'package:theater_app/data/demo_data.dart';

void main() {
  final data = DemoData();
  final bundle = {
    'snapshot': data.snapshot(),
    'scripts': [
      data.script(DemoData.mainProductionId).toJson(),
      data.script(DemoData.secondProductionId).toJson(),
    ],
  };
  final target = File('server/fixtures/example-data.json');
  target.parent.createSync(recursive: true);
  target.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(bundle));
}
