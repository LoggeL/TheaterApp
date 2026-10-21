import 'package:flutter_test/flutter_test.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/demo_data.dart';
import 'package:theater_app/features/today/domain/today_digest.dart';

import 'app_controller_test.dart' show TestServer, fixedNow, signIn;

JsonMap _event(
  String id,
  int days, {
  String? productionId,
  List<String> sceneIds = const [],
}) {
  final start = fixedNow.add(Duration(days: days));
  return {
    'id': id,
    'title': 'Probe $id',
    'startsAt': start.toUtc().toIso8601String(),
    'endsAt': start.add(const Duration(hours: 2)).toUtc().toIso8601String(),
    'productionId': ?productionId,
    'sceneIds': sceneIds,
  };
}

JsonMap _poll(String id, {String? choice}) => {
  'id': id,
  'title': 'Frage $id',
  'choice': choice,
  'options': [
    {'id': 'a', 'label': 'Ja', 'votes': 0},
    {'id': 'b', 'label': 'Nein', 'votes': 0},
  ],
};

/// A plain member with a person record instead of the admin test account.
class _MemberServer extends TestServer {
  @override
  JsonMap get user => {...super.user, 'role': 'member', 'personId': 7};
}

Future<TodayDigest> _digest(TestServer server) async {
  final controller = server.controller();
  addTearDown(controller.dispose);
  await signIn(controller);
  return TodayDigest.from(controller);
}

void main() {
  test(
    'open responses after the next event are capped and not repeated',
    () async {
      final server = TestServer()
        ..data['events'] = [
          _event('past', -1),
          _event('next', 1),
          _event('a', 2),
          _event('answered', 3),
          _event('b', 4),
          _event('c', 5),
          _event('d', 6),
          _event('far', 20),
        ]
        ..data['attendanceByEvent'] = {'answered': 'yes'};
      final digest = await _digest(server);
      expect(digest.next?.id, 'next');
      expect(digest.nextOpen, isTrue);
      expect(digest.openResponses.map((e) => e.id), ['a', 'b', 'c']);
      // 'd' still waits; 'far' lies outside the response window.
      expect(digest.moreOpenResponses, 1);
      expect(digest.laterEvents.map((e) => e.id), ['answered', 'd', 'far']);
      expect(digest.hasPending, isTrue);
    },
  );

  test('nothing pending once everything is answered and read', () async {
    final server = TestServer()
      ..data['events'] = [_event('next', 1)]
      ..data['attendanceByEvent'] = {'next': 'yes'}
      ..data['messages'] = <dynamic>[]
      ..data['slotPools'] = <dynamic>[]
      ..data['polls'] = [_poll('voted', choice: 'a')];
    final digest = await _digest(server);
    expect(digest.nextOpen, isFalse);
    expect(digest.openResponses, isEmpty);
    // A single upcoming event leaves nothing for "Weitere Termine".
    expect(digest.laterEvents, isEmpty);
    expect(digest.pollsToVote, isEmpty);
    expect(digest.votedPoll?.id, 'voted');
    expect(digest.hasPending, isFalse);
  });

  test(
    'polls to vote hide the voted one and registrations count for admins',
    () async {
      final server = TestServer()
        ..data['polls'] = [_poll('open'), _poll('voted', choice: 'a')]
        ..data['pendingAccounts'] = [
          {'uid': 'new', 'status': 'pending', 'identityReady': true},
          {'uid': 'unverified', 'status': 'pending', 'identityReady': false},
        ];
      final digest = await _digest(server);
      expect(digest.pollsToVote.map((p) => p.id), ['open']);
      expect(digest.votedPoll, isNull);
      expect(digest.registrations, 1);

      final member = _MemberServer()
        ..data['pendingAccounts'] = server.data['pendingAccounts'];
      expect((await _digest(member)).registrations, 0);
    },
  );

  test(
    'admins outside a poll audience see it neither as open nor as voted',
    () async {
      final unaddressed = {
        ..._poll('others'),
        'personIds': [999],
      };
      final server = TestServer()..data['polls'] = [unaddressed];
      final digest = await _digest(server);
      expect(digest.pollsToVote, isEmpty);
      expect(digest.votedPoll, isNull);

      final mixed = TestServer()
        ..data['polls'] = [unaddressed, _poll('voted', choice: 'a')];
      expect((await _digest(mixed)).votedPoll?.id, 'voted');
    },
  );

  group('script shortcut', () {
    test('opens the next event production at its first scene', () async {
      final server = TestServer()
        ..data['events'] = [
          _event(
            'next',
            1,
            productionId: DemoData.secondProductionId,
            sceneIds: ['s2', 's3'],
          ),
        ];
      final digest = await _digest(server);
      expect(digest.scriptProduction?.id, DemoData.secondProductionId);
      expect(digest.scriptEvent?.id, 'next');
      expect(digest.scriptSceneId, 's2');
    });

    test('falls back to an active production of the person', () async {
      final server = _MemberServer()..data['events'] = [_event('next', 1)];
      for (final p in server.data['productions'] as List) {
        if ((p as Map)['id'] == DemoData.secondProductionId) {
          p['ensemble'] = [7];
        }
      }
      final digest = await _digest(server);
      expect(digest.scriptProduction?.id, DemoData.secondProductionId);
      expect(digest.scriptEvent, isNull);
      expect(digest.scriptSceneId, isNull);
    });

    test('else uses the first active production', () async {
      final server = TestServer()..data['events'] = [_event('next', 1)];
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      final digest = TodayDigest.from(controller);
      // Not the production picked by the ensemble case above.
      expect(
        controller.activeProductions.first.id,
        isNot(DemoData.secondProductionId),
      );
      expect(
        digest.scriptProduction?.id,
        controller.activeProductions.first.id,
      );
      expect(digest.scriptEvent, isNull);
    });
  });

  group('next event skips events the person will not attend', () {
    test('declined, absent or unanswered on an absence day', () async {
      final absent = dateOnly(fixedNow.add(const Duration(days: 2)));
      final server = TestServer()
        ..data['events'] = [
          _event('declined', 1),
          // Locked, so the server could not decline it for the absence.
          {..._event('away', 2), 'locked': true},
          _event('mine', 3),
          _event('later', 4),
        ]
        ..data['attendanceByEvent'] = {'declined': 'no'}
        ..data['absences'] = [
          {'id': 'urlaub', 'from': absent, 'to': absent, 'reason': 'Urlaub'},
        ];
      final digest = await _digest(server);
      expect(digest.next?.id, 'mine');
      expect(digest.nextOpen, isTrue);
      // The lists below are unchanged: the skipped events still show there.
      expect(digest.laterEvents.map((e) => e.id), ['declined', 'away']);
      expect(digest.openResponses.map((e) => e.id), ['later']);
    });

    test('a confirmation on an absence day keeps the event', () async {
      final day = dateOnly(fixedNow.add(const Duration(days: 1)));
      final server = TestServer()
        ..data['events'] = [_event('trotzdem', 1), _event('later', 2)]
        ..data['attendanceByEvent'] = {'trotzdem': 'yes'}
        ..data['absences'] = [
          {'id': 'urlaub', 'from': day, 'to': day, 'reason': ''},
        ];
      expect((await _digest(server)).next?.id, 'trotzdem');
    });

    test('only declined events leave the empty state', () async {
      final server = TestServer()
        ..data['events'] = [_event('a', 1), _event('b', 2)]
        ..data['attendanceByEvent'] = {'a': 'no', 'b': 'no'};
      final digest = await _digest(server);
      expect(digest.next, isNull);
      expect(digest.nextOpen, isFalse);
      expect(digest.laterEvents.map((e) => e.id), ['a', 'b']);
    });

    test('a queued deletion by the organizer is skipped', () async {
      final server = TestServer()
        ..data['events'] = [
          _event('single', 1),
          {..._event('s1', 2), 'seriesId': 'serie'},
          {..._event('s2', 3), 'seriesId': 'serie'},
          _event('mine', 4),
        ];
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      server.offline = true;
      for (final body in [
        {'action': 'event.delete', 'id': 'single', 'version': 1},
        {
          'action': 'event.delete',
          'id': 's1',
          'version': 1,
          'series': 'following',
        },
      ]) {
        await controller.performAction(body);
      }
      expect(controller.pendingCount, 2);
      // Deletions are not projected, so the events are still listed.
      expect(controller.events.map((e) => e.id), contains('s2'));
      expect(TodayDigest.from(controller).next?.id, 'mine');
    });

    test('a queued earlier end of a whole series is skipped', () async {
      final server = TestServer()
        ..data['events'] = [
          {..._event('s1', 1), 'seriesId': 'serie'},
          {..._event('s2', 2), 'seriesId': 'serie'},
          {..._event('s3', 3), 'seriesId': 'serie'},
          _event('mine', 4),
        ]
        ..data['attendanceByEvent'] = {'s1': 'no'};
      final controller = server.controller();
      addTearDown(controller.dispose);
      await signIn(controller);
      expect(TodayDigest.from(controller).next?.id, 's2');
      server.offline = true;
      final first = controller.events.firstWhere((e) => e.id == 's1');
      await controller.performAction({
        'action': 'event.save',
        'id': 's1',
        'version': 1,
        'series': 'all',
        'until': dateOnly(first.startsAt!),
      });
      expect(controller.pendingCount, 1);
      // s2 and s3 end with the series; s1, which was declined, stays.
      expect(TodayDigest.from(controller).next?.id, 'mine');
    });
  });

  for (final flagged in [true, false]) {
    test(
      'an event the admin is not invited to is never the next one '
      '(${flagged ? 'server flag' : 'fallback for older servers'})',
      () async {
        final server = _InvitedAdminServer()
          ..data['events'] = [
            {
              ..._event('technik', 1),
              'roleIds': ['role-3'],
              if (flagged) 'addressedToMe': false,
            },
            {..._event('mine', 2), if (flagged) 'addressedToMe': true},
          ];
        final digest = await _digest(server);
        expect(digest.next?.id, 'mine');
        expect(digest.openResponses, isEmpty);
        // Still visible below, marked as not invited.
        expect(digest.laterEvents.map((e) => e.id), ['technik']);
        expect(digest.laterEvents.single.needsResponse, isFalse);
      },
    );
  }
}

/// The admin test account with a person record in role-1.
class _InvitedAdminServer extends TestServer {
  @override
  JsonMap get user => {
    ...super.user,
    'personId': 1,
    'roleIds': ['role-1'],
  };
}
