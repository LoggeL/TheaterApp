part of '../app_controller.dart';

/// Optimistic projection of queued actions onto a snapshot.
extension ProjectionController on AppController {
  JsonMap _applyAction(
    JsonMap original,
    PendingAction action, {
    String? createdId,
  }) {
    final view = cloneJson(original), body = action.payload;
    switch (body['action']) {
      case 'production.archive':
        view['productions'] = jsonList(view['productions']).map((item) {
          final production = jsonMap(item);
          return production['id'] == body['id']
              ? {
                  ...production,
                  'archived': body['archived'] == true,
                  'version': intValue(production['version'] ?? 1) + 1,
                }
              : item;
        }).toList();
      case 'production.cast':
        view['productions'] = jsonList(view['productions']).map((item) {
          final production = jsonMap(item);
          return production['id'] == body['id']
              ? applyCastChanges(
                  production,
                  jsonList(body['changes']).map(jsonMap),
                )
              : item;
        }).toList();
      case 'attendance':
        final attendance = jsonMap(view['attendanceByEvent']),
            reasons = jsonMap(view['declineReasons']);
        attendance[textValue(body['eventId'])] = body['status'];
        reasons[textValue(body['eventId'])] = body['reason'];
        view['attendanceByEvent'] = attendance;
        view['declineReasons'] = reasons;
        view['expectedArrivals'] = {
          ...jsonMap(view['expectedArrivals']),
          textValue(body['eventId']): body['expectedArrivalAt'],
        };
      case 'poll.vote':
        view['polls'] = jsonList(view['polls']).map((e) {
          final poll = Poll.fromJson(jsonMap(e));
          // Keep fields the model does not know, e.g. from a newer server.
          return poll.id == body['pollId']
              ? {
                  ...jsonMap(e),
                  ...poll
                      .withChoice(
                        textValue(body['optionId']),
                        voter: _user?.personId == null
                            ? null
                            : PollVoter(
                                personId: _user!.personId!,
                                name: _user!.name,
                              ),
                      )
                      .toJson(),
                }
              : e;
        }).toList();
      case 'poll.delete':
        view['polls'] = jsonList(
          view['polls'],
        ).where((e) => jsonMap(e)['id'] != body['id']).toList();
      case 'absence.create':
        view['absences'] = [
          ...jsonList(view['absences']),
          {
            'id': createdId ?? 'local:${action.id}',
            'from': body['from'],
            'to': body['to'],
            'reason': body['reason'],
          },
        ];
        final attendance = jsonMap(view['attendanceByEvent']),
            reasons = jsonMap(view['declineReasons']),
            arrivals = jsonMap(view['expectedArrivals']);
        for (final item in jsonList(view['events'])) {
          final event = jsonMap(item);
          final end = dateValue(event['endsAt']),
              start = dateValue(event['startsAt']);
          final viewer = jsonMap(view['user']);
          final invited =
              TheaterMember(
                id: intValue(viewer['personId'], -1),
                name: '',
                roleIds: jsonList(viewer['roleIds']).map((e) => '$e').toList(),
              ).inAudience(
                jsonList(event['roleIds']).map((e) => '$e').toList(),
                jsonList(event['personIds']).map(intValue).toList(),
                ensemblesOf(jsonList(event['productionIds']).map((e) => '$e')),
              );
          if (event['locked'] == true ||
              event['slotPoolId'] != null ||
              !invited ||
              end == null ||
              end.isBefore(_clock()) ||
              (start != null &&
                  !start
                      .subtract(TheaterEvent.declineCutoff)
                      .isAfter(_clock()))) {
            continue;
          }
          final explicitDay = textValue(event['eventDate']);
          final sourceTimestamp = textValue(event['startsAt']);
          if (explicitDay.isEmpty && sourceTimestamp.length < 10) continue;
          // v1's eventDate is the authoritative Europe/Berlin calendar date.
          // Preserve the literal source date for older offset-bearing payloads.
          final day = explicitDay.isNotEmpty
              ? explicitDay
              : sourceTimestamp.substring(0, 10);
          if (day.compareTo(textValue(body['from'])) >= 0 &&
              day.compareTo(textValue(body['to'])) <= 0) {
            attendance[textValue(event['id'])] = 'no';
            reasons[textValue(event['id'])] = body['reason'];
            arrivals[textValue(event['id'])] = null;
          }
        }
        view['attendanceByEvent'] = attendance;
        view['declineReasons'] = reasons;
        view['expectedArrivals'] = arrivals;
      case 'absence.delete':
        view['absences'] = jsonList(
          view['absences'],
        ).where((e) => jsonMap(e)['id'] != body['id']).toList();
      case 'settings.reminders':
        view['reminders'] = body['value'];
      case 'checkin.save':
        final checkins = jsonMap(view['checkinsByEvent']);
        checkins[textValue(body['eventId'])] = {
          ...jsonMap(checkins[textValue(body['eventId'])]),
          for (final member in jsonList(body['members']))
            textValue(jsonMap(member)['id']): jsonMap(member)['present'],
        };
        view['checkinsByEvent'] = checkins;
        final versions = jsonMap(view['checkinVersions']);
        for (final item in jsonList(body['members'])) {
          final member = jsonMap(item);
          final key = '${body['eventId']}:${member['id']}';
          versions[key] = intValue(versions[key]) + 1;
        }
        view['checkinVersions'] = versions;
      case 'message.read':
        view['messages'] = jsonList(view['messages'])
            .map(
              (m) => jsonMap(m)['id'] == body['id']
                  ? {...jsonMap(m), 'read': true}
                  : m,
            )
            .toList();
      case 'message.readAll':
        view['messages'] = jsonList(
          view['messages'],
        ).map((m) => {...jsonMap(m), 'read': true}).toList();
      case 'message.delete':
        view['messages'] = jsonList(
          view['messages'],
        ).where((m) => jsonMap(m)['id'] != body['id']).toList();
      case 'member.delete':
        // Only the person disappears optimistically; the references the server
        // cleans up (casting, invitations, responses …) arrive with the refresh.
        view['members'] = jsonList(view['members'])
            .where(
              (m) => intValue(jsonMap(m)['id'], -1) != intValue(body['id'], -2),
            )
            .toList();
      case 'event.script':
        view['events'] = jsonList(view['events']).map((item) {
          final event = jsonMap(item);
          return event['id'] == body['eventId']
              ? {
                  ...event,
                  'productionId': body['productionId'],
                  'sceneIds': body['sceneIds'],
                  'version': intValue(event['version'], 1) + 1,
                }
              : event;
        }).toList();
      case 'slot.book' || 'slot.cancel' || 'slot.assign':
        final personId = body['action'] == 'slot.assign'
            ? intValue(body['personId'], -1)
            : _user?.personId;
        if (personId == null) break;
        final slotId = body['action'] == 'slot.cancel'
            ? null
            : body['slotId']?.toString();
        final name =
            _members.where((m) => m.id == personId).firstOrNull?.name ??
            (personId == _user?.personId ? _user!.name : '');
        view['slotPools'] = jsonList(view['slotPools']).map((item) {
          final pool = jsonMap(item);
          if (pool['id'] != body['poolId']) return item;
          return {
            ...pool,
            if (personId == _user?.personId) 'myBooking': slotId,
            'slots': jsonList(pool['slots']).map((entry) {
              final slot = jsonMap(entry);
              final people = [
                for (final p in jsonList(slot['people']).map(jsonMap))
                  if (intValue(p['personId'], -1) != personId) p,
                if (slot['id'] == slotId) {'personId': personId, 'name': name},
              ];
              return {...slot, 'people': people, 'booked': people.length};
            }).toList(),
          };
        }).toList();
      case 'account.reconsider':
        view['pendingAccounts'] = jsonList(view['pendingAccounts']).map((item) {
          final account = jsonMap(item);
          return account['uid'] == body['uid'] &&
                  account['status'] == 'rejected'
              ? {
                  ...account,
                  'status': 'pending',
                  'role': 'member',
                  'personId': null,
                  'version': intValue(account['version'], 1) + 1,
                }
              : account;
        }).toList();
    }
    return view;
  }

  // `event.save` and `event.delete` are not projected optimistically: a queued
  // new event (or a whole series, `repeat`) and a queued deletion (also
  // `series: 'following'`) show up once the server confirmed them and the
  // snapshot is refreshed, so the server alone computes series occurrences.
  String? _versionedEventId(JsonMap payload) {
    final id = switch (payload['action']) {
      'event.script' => textValue(payload['eventId']),
      'event.save' || 'event.delete' => textValue(payload['id']),
      _ => '',
    };
    return id.isEmpty ? null : id;
  }
}
