part of '../app_controller.dart';

/// The outbox: queueing, draining, retrying and the snapshot refresh.
extension SyncController on AppController {
  /// Queues [body] and sends it right away when possible. Throws when the
  /// server rejected the change; otherwise says whether it is already
  /// confirmed ([ActionOutcome.synced]) or still waits in the outbox
  /// ([ActionOutcome.queued]).
  Future<ActionOutcome> performAction(JsonMap body) async {
    final previous = _outbox.map((a) => a.id).toSet();
    await _enqueue(body);
    final failed = _outbox
        .where((a) => a.failed && !previous.contains(a.id))
        .firstOrNull;
    if (failed != null) {
      throw ApiException(
        failed.lastError ?? 'Die Änderung wurde abgelehnt.',
        statusCode: 409,
      );
    }
    return _outcomeSince(previous);
  }

  /// [ActionOutcome.queued] while an entry added after [previous] was taken is
  /// still in the outbox. Demo changes never enter the outbox.
  ActionOutcome _outcomeSince(Set<String> previous) =>
      !_isDemo && _outbox.any((a) => !previous.contains(a.id))
      ? ActionOutcome.queued
      : ActionOutcome.synced;

  Future<void> _enqueue(JsonMap payload) async {
    if (_user == null) {
      throw const ApiException('Bitte zuerst anmelden.', statusCode: 401);
    }
    if (!_user!.isApproved) {
      throw const ApiException(
        'Dein Zugang ist noch nicht freigegeben.',
        statusCode: 403,
      );
    }
    if (_user!.mustChangePassword && !_isDemo) {
      throw const ApiException(
        'Bitte zuerst das vorläufige Passwort ändern.',
        statusCode: 403,
      );
    }
    final generation = _generation;
    final action = PendingAction(
      id: _uuid(),
      payload: payload,
      createdAt: _clock(),
    );
    _error = null;
    if (_isDemo) {
      _baseSnapshot = _applyAction(
        _baseSnapshot,
        action,
        createdId: 'demo-${action.id}',
      );
      _rebuild();
      await _persistCore(generation);
      _notify();
      return;
    }
    _outbox.add(action);
    try {
      await _persistCore(generation);
    } catch (_) {
      if (_current(generation)) _outbox.removeWhere((e) => e.id == action.id);
      throw const ApiException(
        'Die Änderung konnte nicht sicher auf diesem Gerät gespeichert werden. Bitte erneut versuchen.',
      );
    }
    if (!_current(generation)) return;
    _rebuild();
    _notify();
    await _drain(generation);
    if (_current(generation) && !_isOffline) await refresh();
  }

  Future<void> _drain(int generation) {
    if (_drainTask != null) return _drainTask!;
    final task = _drainQueue(generation);
    _drainTask = task;
    return task.whenComplete(() {
      if (_current(generation)) _drainTask = null;
    });
  }

  Future<void> _drainQueue(int generation) async {
    if (_isDemo || _token == null) return;
    final origin = _apiBaseUrl, token = _token!;
    while (_current(generation)) {
      final action = _outbox.where((e) => !e.failed).firstOrNull;
      if (action == null) break;
      try {
        final result = await _api.action(origin, token, action);
        if (!_current(generation)) return;
        if (result['ok'] != true) {
          throw const ApiException(
            'Der Server hat die Änderung nicht eindeutig bestätigt.',
            statusCode: 502,
          );
        }
        final previousSnapshot = _baseSnapshot;
        _baseSnapshot = _applyAction(
          _baseSnapshot,
          action,
          createdId: result['id']?.toString(),
        );
        _mutationVersion++;
        _outbox.removeWhere((e) => e.id == action.id);
        _isOffline = false;
        try {
          await _persistCore(generation);
        } catch (_) {
          // The original pending record is still durable. Keep the same key in
          // memory, too: retrying an acknowledged request is safe server-side.
          if (_current(generation)) {
            _baseSnapshot = previousSnapshot;
            _outbox.insert(0, action);
            _error =
                'Die Serverbestätigung konnte lokal nicht gespeichert werden. Die Änderung bleibt zur sicheren Wiederholung vorgemerkt.';
            _isOffline = true;
            _rebuild();
            _notify();
          }
          return;
        }
      } catch (error) {
        if (!_current(generation)) return;
        _error = _message(error);
        if (error is ApiException && error.isUnauthorized) {
          await _expire(generation);
          return;
        }
        if (error is! ApiException || error.retryable) {
          _isOffline = true;
          _outbox = _outbox
              .map(
                (e) => e.id == action.id ? e.withStatus('pending', _error) : e,
              )
              .toList();
          await _persistCore(generation);
          _rebuild();
          _notify();
          return;
        }
        // Invalid/forbidden/conflicting actions are visible and rolled back,
        // rather than retried forever or shown as successfully synchronized.
        var afterRejectedAction = false;
        final rejectedEventId = _versionedEventId(action.payload);
        _outbox = _outbox.map((pending) {
          if (pending.id == action.id) {
            afterRejectedAction = true;
            return pending.withStatus('failed', _error);
          }
          if (afterRejectedAction &&
              !pending.failed &&
              rejectedEventId != null &&
              _versionedEventId(pending.payload) == rejectedEventId) {
            // Later projected versions depend on the preceding save succeeding.
            // Keep the original base version for explicit retry as well, so a
            // coincidentally matching foreign version cannot be overwritten.
            return PendingAction(
              id: pending.id,
              payload: {
                ...pending.payload,
                'version':
                    action.payload['version'] ??
                    jsonList(_baseSnapshot['events'])
                        .map(jsonMap)
                        .where((e) => e['id'] == rejectedEventId)
                        .map((e) => intValue(e['version'], 1))
                        .firstOrNull ??
                    1,
              },
              createdAt: pending.createdAt,
              status: 'failed',
              lastError:
                  'Eine frühere Terminänderung wurde abgelehnt. Lade den aktuellen Termin und prüfe deinen Entwurf vor dem Speichern.',
            );
          }
          return pending;
        }).toList();
        await _persistCore(generation);
      }
      if (_current(generation)) {
        _rebuild();
        _notify();
      }
    }
  }

  Future<void> retryPending() => refresh();
  Future<void> retryFailed(String id) async {
    final generation = _generation;
    // A new idempotency key is required: the server may cache a rejected result.
    final action = _outbox.where((e) => e.id == id && e.failed).firstOrNull;
    if (action == null) return;
    final replacement = PendingAction(
      id: _uuid(),
      payload: action.payload,
      createdAt: _clock(),
    );
    _outbox = _outbox.map((e) => e.id == id ? replacement : e).toList();
    try {
      await _persistCore(generation);
    } catch (_) {
      if (_current(generation)) {
        _outbox = _outbox
            .map((e) => e.id == replacement.id ? action : e)
            .toList();
      }
      rethrow;
    }
    if (!_current(generation)) return;
    _rebuild();
    _notify();
    await _drain(generation);
    if (_current(generation) && !_isOffline) await refresh();
  }

  Future<void> discardAction(String id) async {
    final generation = _generation;
    if (_drainTask != null) await _drainTask;
    if (!_current(generation)) return;
    _outbox.removeWhere((e) => e.id == id);
    _rebuild();
    await _persistCore(generation);
    _notify();
  }

  Future<void> refresh() {
    if (_user == null) return Future.value();
    if (_refreshTask != null) return _refreshTask!;
    final generation = _generation;
    final task = _refresh(generation);
    _refreshTask = task;
    return task.whenComplete(() {
      if (_current(generation)) _refreshTask = null;
    });
  }

  Future<void> _refresh(int generation) async {
    if (_isDemo) {
      _error = null;
      _lastSync = _clock();
      _notify();
      return;
    }
    final origin = _apiBaseUrl, token = _token!;
    _busyCount++;
    _error = null;
    _notify();
    try {
      if (_identity != null) {
        await refreshAccess(refreshData: false);
        if (!_current(generation) || !hasAccess) return;
      }
      await _drain(generation);
      if (!_current(generation)) return;
      JsonMap snapshot;
      // If an action commits while an older snapshot is in flight, fetch again
      // before installing it. Otherwise that stale response would erase the
      // already acknowledged change after its outbox entry had been removed.
      while (true) {
        final version = _mutationVersion;
        snapshot = await _api.snapshot(origin, token);
        if (!_current(generation)) return;
        if (version == _mutationVersion) break;
      }
      if (snapshot['apiVersion'] != 1 ||
          jsonMap(snapshot['user'])['userId'] != _user?.id) {
        throw const ApiException(
          'Die Serverantwort passt nicht zu dieser Anmeldung oder API-Version.',
          statusCode: 502,
        );
      }
      if (jsonMap(snapshot['scriptService'])['available'] == false) {
        snapshot['productions'] = jsonList(_baseSnapshot['productions']);
      }
      _baseSnapshot = snapshot;
      _lastSync = _clock();
      _isOffline = false;
      _rebuild();
      await _persistCore(generation);
    } catch (error) {
      if (_current(generation)) {
        _isOffline = error is ApiException && error.retryable;
        _error = _message(error);
        if (error is ApiException && error.isUnauthorized) {
          await _expire(generation);
        }
      }
    } finally {
      if (_current(generation)) {
        _busyCount = max(0, _busyCount - 1);
        _notify();
      }
    }
  }

  void _rebuild() {
    var view = cloneJson(_baseSnapshot);
    for (final action in _outbox.where((e) => !e.failed)) {
      view = _applyAction(view, action);
    }
    if (jsonMap(view['user']).isNotEmpty) {
      _user = AppUser.fromJson(jsonMap(view['user']));
    }
    final attendance = jsonMap(view['attendanceByEvent']),
        reasons = jsonMap(view['declineReasons']);
    final arrivals = jsonMap(view['expectedArrivals']);
    _events =
        jsonList(view['events']).map((e) {
          final event = TheaterEvent.fromJson(jsonMap(e));
          return event.copyWith(
            response: textValue(attendance[event.id], event.response),
            declineReason: textValue(reasons[event.id], event.declineReason),
            expectedArrivalAt: dateValue(arrivals[event.id])?.toLocal(),
            clearExpectedArrival:
                arrivals.containsKey(event.id) && arrivals[event.id] == null,
          );
        }).toList()..sort(
          (a, b) => (a.startsAt ?? DateTime(9999)).compareTo(
            b.startsAt ?? DateTime(9999),
          ),
        );
    _absences =
        jsonList(
            view['absences'],
          ).map((e) => Absence.fromJson(jsonMap(e))).toList()
          ..sort((a, b) => a.from.compareTo(b.from));
    _polls = jsonList(
      view['polls'],
    ).map((e) => Poll.fromJson(jsonMap(e))).toList();
    _slotPools = List.unmodifiable(jsonList(view['slotPools']).map(jsonMap));
    _productions = jsonList(view['productions']).map((e) {
      final production = Production.fromJson(jsonMap(e));
      return _scripts[production.id] == null
          ? production
          : production.withScript(_scripts[production.id]!);
    }).toList()..sort(Production.compareNewestFirst);
    _members = jsonList(
      view['members'],
    ).map((e) => TheaterMember.fromJson(jsonMap(e))).toList();
    _reminders = {
      for (final key in ['dayBefore', 'twoHours', 'changes', 'emailEnabled'])
        key: jsonMap(view['reminders'])[key] == true,
    };
    final customMinutes = jsonMap(view['reminders'])['customMinutes'];
    _customReminderMinutes = customMinutes is num
        ? customMinutes.toInt()
        : null;
    _checkinsByEvent = jsonMap(view['checkinsByEvent']);
    _checkinVersions = jsonMap(view['checkinVersions']);
    _capabilities = jsonMap(view['capabilities']);
  }
}
