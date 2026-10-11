import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/features/scripts/scripts.dart';

import 'app_controller_test.dart' show TestServer, jsonResponse, signIn;

const _productionId = DemoData.mainProductionId;

/// A server whose focus requests wait until the test releases them.
class _FocusServer {
  _FocusServer() {
    server.override = (request) {
      if (!request.url.path.endsWith('/focus/')) return null;
      if (request.method == 'GET') {
        final gate = Completer<http.Response>();
        polls.add(gate);
        return gate.future;
      }
      final body = jsonMap(jsonDecode(request.body));
      published.add(textValue(body['cueId']));
      final gate = Completer<http.Response>();
      publishes.add(gate);
      return gate.future;
    };
  }
  final server = TestServer();
  final polls = <Completer<http.Response>>[];
  final publishes = <Completer<http.Response>>[];
  final published = <String>[];

  static http.Response focus(String cueId, int sequence) => jsonResponse({
    'productionId': _productionId,
    'revision': 'r1',
    'cueId': cueId,
    'sequence': sequence,
    'canDirect': true,
  });
}

/// Lets the mock HTTP stack run until [done] holds.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(done(), isTrue);
}

void main() {
  test(
    'a publish during an in-flight poll is sent and a stale poll is ignored',
    () async {
      final fake = _FocusServer();
      final controller = fake.server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      final failures = <String>[];
      final live = LiveFocusController(
        controller: controller,
        productionId: _productionId,
        revision: () => 'r1',
        onPublishFailed: failures.add,
      );
      addTearDown(live.dispose);

      final poll = live.refresh();
      await _until(() => fake.polls.length == 1);
      final publish = live.publish('cue-b');
      await _until(() => fake.published.isNotEmpty);
      expect(fake.published, ['cue-b']);

      fake.publishes.single.complete(_FocusServer.focus('cue-b', 5));
      await publish;
      expect(live.focus?.cueId, 'cue-b');

      // The poll started before the publish and answers with older data.
      fake.polls.single.complete(_FocusServer.focus('cue-a', 4));
      await poll;
      expect(live.focus?.cueId, 'cue-b');
      expect(failures, isEmpty);
    },
  );

  test('taps during a running publish are coalesced to the latest', () async {
    final fake = _FocusServer();
    final controller = fake.server.controller();
    addTearDown(controller.dispose);
    await signIn(controller);
    final live = LiveFocusController(
      controller: controller,
      productionId: _productionId,
      revision: () => 'r1',
    );
    addTearDown(live.dispose);

    final first = live.publish('cue-a');
    await _until(() => fake.publishes.length == 1);
    unawaited(live.publish('cue-b'));
    unawaited(live.publish('cue-c'));
    fake.publishes.first.complete(_FocusServer.focus('cue-a', 1));
    await _until(() => fake.publishes.length == 2);
    expect(fake.published, ['cue-a', 'cue-c']);
    fake.publishes.last.complete(_FocusServer.focus('cue-c', 2));
    await first;
    expect(live.focus?.cueId, 'cue-c');
  });

  test(
    'following jumps once per new focus and reports revision changes',
    () async {
      final fake = _FocusServer();
      final controller = fake.server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      final jumps = <String?>[];
      var revision = 'r1';
      final live = LiveFocusController(
        controller: controller,
        productionId: _productionId,
        revision: () => revision,
        onFollow: (cueId) async => jumps.add(cueId),
        pollInterval: const Duration(hours: 1),
      );
      addTearDown(live.dispose);

      live.setFollowing(true);
      await _until(() => fake.polls.length == 1);
      fake.polls.last.complete(_FocusServer.focus('cue-a', 3));
      await _until(() => jumps.isNotEmpty);
      expect(jumps, ['cue-a']);

      final again = live.refresh();
      await _until(() => fake.polls.length == 2);
      fake.polls.last.complete(_FocusServer.focus('cue-a', 3));
      await again;
      expect(jumps, ['cue-a'], reason: 'An unchanged focus must not jump.');

      revision = 'r2';
      final changed = live.refresh();
      await _until(() => fake.polls.length == 3);
      fake.polls.last.complete(_FocusServer.focus('cue-b', 4));
      await changed;
      expect(jumps, ['cue-a']);
      expect(live.error, contains('Andere Drehbuchfassung'));
    },
  );
}
