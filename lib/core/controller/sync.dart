part of '../app_controller.dart';

/// The outbox: queueing, draining, retrying and the snapshot refresh.
extension SyncController on AppController {
  /// Queues [body] and sends it right away when possible. Throws when the
  /// server rejected the change; otherwise says whether it is already
  /// confirmed ([ActionOutcome.synced]) or still waits in the outbox
  /// ([ActionOutcome.queued]).
  Future<ActionOutcome> performAction(JsonMap body) async =>
      (await performActionWithResult(body)).outcome;

  /// Like [performAction], but also hands over the server's reply (for
  /// example `pushQueued` or `recipients`) once the change is confirmed.
  Future<ActionResult> performActionWithResult(JsonMap body) async {
    final id = await _enqueue(body);
    return _resultOf(id);
  }

  /// Sends [body] straight to the server and never through the outbox, for
  /// admin changes that must not wait offline and apply later (account
  /// rights). Throws when the server refused it or could not be reached;
  /// after an [ApiException.retryable] error it is open whether the change
  /// arrived.
  Future<JsonMap> performActionOnline(JsonMap body) =>
      remote('/actions', method: 'POST', body: body, idempotencyKey: _uuid());

  /// The result of the outbox entry [id] right after it was handed over:
  /// throws its rejection, else reports whether it is still queued.
  ActionResult _resultOf(String id) {
    final rejection = _rejections.remove(id);
    if (rejection != null) throw rejection;
    final pending = _outbox.where((a) => a.id == id).firstOrNull;
    if (pending != null && pending.failed) {
      throw ApiException(
        pending.lastErrorCode == 'version_conflict'
            ? 'Inzwischen geändert – aktueller Stand geladen.'
            : pending.lastError ?? 'Die Änderung wurde abgelehnt.',
        statusCode: pending.lastStatus ?? 409,
        code: pending.lastErrorCode,
      );
    }
    final data = _results.remove(id);
    // Demo changes never enter the outbox.
    if (!_isDemo && pending != null) {
      return const ActionResult(ActionOutcome.queued);
    }
    return ActionResult(ActionOutcome.synced, data);
  }

  /// Error codes that make a member's own change pointless to send again:
  /// it is dropped from the outbox right away instead of staying as failed.
  static const _selfResolvingCodes = {
    'closed',
    'not_found',
    'full',
    'nothing_open',
    'cooldown',
  };
  static const _selfResolvingActions = {
    'attendance',
    'poll.vote',
    'slot.book',
    'slot.cancel',
    'message.read',
    'absence.delete',
    'message.remind',
    'event.remindOpen',
    'poll.remindOpen',
    'slotPool.remindOpen',
  };

  /// Keeps only the newest [limit] entries of a transient result map.
  void _trim(Map<String, Object> entries, [int limit = 50]) {
    while (entries.length > limit) {
      entries.remove(entries.keys.first);
    }
  }

  /// Queues [payload], sends it when possible and returns its outbox id.
  Future<String> _enqueue(JsonMap payload) async {
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
      return action.id;
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
    if (!_current(generation)) return action.id;
    _rebuild();
    _notify();
    await _drain(generation);
    // After a clean send the refresh only confirms the projection, so it
    // stays silent and redraws only when the server state differs. A
    // rejection keeps the visible refresh.
    if (_current(generation) && !_isOffline) {
      await refresh(silent: _error == null);
    }
    return action.id;
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
        _results[action.id] = result;
        _trim(_results);
        _isOffline = false;
        try {
          await _persistCore(generation);
        } catch (_) {
          // The original pending record is still durable. Keep the same key in
          // memory, too: retrying an acknowledged request is safe server-side.
          if (_current(generation)) {
            _baseSnapshot = previousSnapshot;
            _results.remove(action.id);
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
        final code = error.code;
        if (code != null &&
            _selfResolvingCodes.contains(code) &&
            _selfResolvingActions.contains(action.payload['action'])) {
          // A deadline passed, a slot filled up or the target is gone:
          // sending it again cannot help. Drop it (the refresh that follows
          // every send loads the current state) and report it to the caller.
          _outbox.removeWhere((e) => e.id == action.id);
          _rejections[action.id] = error;
          _trim(_rejections);
          await _persistCore(generation);
          if (_current(generation)) {
            _rebuild();
            _notify();
          }
          continue;
        }
        // Invalid/forbidden/conflicting actions are visible and rolled back,
        // rather than retried forever or shown as successfully synchronized.
        // A `version_conflict` keeps the entry, too: its payload is the
        // member's draft. The refresh after sending loads the current state.
        var afterRejectedAction = false;
        final rejectedEventId = _versionedEventId(action.payload);
        _outbox = _outbox.map((pending) {
          if (pending.id == action.id) {
            afterRejectedAction = true;
            return pending.withStatus(
              'failed',
              _error,
              error.statusCode,
              error.code,
            );
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

  /// Sends queued changes and loads a fresh snapshot. A [silent] refresh (the
  /// automatic background sync) leaves [busy] untouched; [isRefreshing] still
  /// reports it. [accessChecked] skips the `/auth/session` check of a
  /// Firebase account because the caller has just made it.
  Future<void> refresh({bool silent = false, bool accessChecked = false}) {
    if (_user == null) return Future.value();
    // The first sync after a cache-first start waits for Firebase.
    final starting = _startSync;
    if (starting != null) {
      if (!silent) _busyUntil(starting);
      return starting;
    }
    final running = _refreshTask;
    if (running != null) {
      // Someone waits for a silent refresh: show its progress from now on.
      if (!silent && _refreshSilent) _busyUntil(running);
      return running;
    }
    final generation = _generation;
    _refreshSilent = silent;
    final task = _refresh(
      generation,
      silent: silent,
      accessChecked: accessChecked,
    );
    _refreshTask = task;
    return task.whenComplete(() {
      if (_current(generation)) _refreshTask = null;
    });
  }

  void _busyUntil(Future<void> task) {
    final generation = _generation;
    _refreshSilent = false;
    _busyCount++;
    _notify();
    unawaited(
      task.catchError((Object _) {}).whenComplete(() {
        if (_current(generation)) {
          _busyCount = max(0, _busyCount - 1);
          _notify();
        }
      }),
    );
  }

  /// Whether the background sync asks `/auth/session` again; in between the
  /// snapshot itself proves the access (see [_refresh]).
  bool get _accessCheckDue {
    final at = _accessCheckedAt;
    if (at == null || !hasAccess) return true;
    final age = _clock().difference(at);
    return age.isNegative || age >= AppController.accessCheckInterval;
  }

  Future<void> _refresh(
    int generation, {
    bool silent = false,
    bool accessChecked = false,
  }) async {
    if (_isDemo) {
      _error = null;
      _lastSync = _clock();
      _notify();
      return;
    }
    final origin = _apiBaseUrl, token = _token!;
    if (!silent) _busyCount++;
    _refreshing = true;
    // A background refresh shows nothing while it runs. Every notification
    // rebuilds the visible screen, which made scrolling on the web stutter.
    final quietStart = silent && _error == null;
    var quietEnd = false;
    _error = null;
    if (!quietStart) _notify();
    try {
      if (_identity != null && !accessChecked && _accessCheckDue) {
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
      final unchanged =
          silent && !_isOffline && _sameSnapshot(snapshot, _baseSnapshot);
      _baseSnapshot = snapshot;
      _lastSync = _clock();
      _isOffline = false;
      // Nothing new: keep the projected view and the stored copy. Only the
      // in-memory time of the last check moves on.
      if (unchanged) {
        quietEnd = quietStart;
        return;
      }
      _rebuild();
      await _persistCore(generation);
    } catch (error) {
      if (_current(generation) &&
          _identity != null &&
          error is ApiException &&
          error.statusCode == 403 &&
          error.code == 'access') {
        // The access is gone: the session says how (waiting, suspended).
        try {
          await refreshAccess(refreshData: false);
        } catch (_) {
          /* The snapshot's error below stays. */
        }
        if (!_current(generation) || !hasAccess) return;
      }
      if (_current(generation)) {
        _isOffline = error is ApiException && error.retryable;
        _error = _message(error);
        if (error is ApiException && error.isUnauthorized) {
          await _expire(generation);
        }
      }
    } finally {
      if (_current(generation)) {
        if (!silent) _busyCount = max(0, _busyCount - 1);
        _refreshing = false;
        if (!quietEnd) _notify();
      }
    }
  }

  /// Whether two snapshots carry the same data; `serverTime` differs on
  /// every response and is not shown.
  bool _sameSnapshot(JsonMap next, JsonMap previous) {
    bool shown(String key) => key != 'serverTime';
    if (next.keys.where(shown).length != previous.keys.where(shown).length) {
      return false;
    }
    for (final entry in next.entries) {
      if (!shown(entry.key)) continue;
      if (!previous.containsKey(entry.key) ||
          !_sameJson(entry.value, previous[entry.key])) {
        return false;
      }
    }
    return true;
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
    // Ensembles and the own member record decide the audience fallback below.
    _productions = jsonList(view['productions']).map((e) {
      final production = Production.fromJson(jsonMap(e));
      return _scripts[production.id] == null
          ? production
          : production.withScript(_scripts[production.id]!);
    }).toList()..sort(Production.compareNewestFirst);
    _members = jsonList(
      view['members'],
    ).map((e) => TheaterMember.fromJson(jsonMap(e))).toList();
    final me = _audienceMember();
    // Before the events: own absences decide implicit attendance below.
    _absences =
        jsonList(
            view['absences'],
          ).map((e) => Absence.fromJson(jsonMap(e))).toList()
          ..sort((a, b) => a.from.compareTo(b.from));
    _events =
        jsonList(view['events']).map((e) {
          final json = jsonMap(e);
          final event = TheaterEvent.fromJson(json);
          final projected = event.copyWith(
            // Older servers send no `addressedToMe`; admins receive every
            // event there, so the event's audience decides for them.
            addressedToMe: json.containsKey('addressedToMe') || me == null
                ? null
                : me.inAudience(
                    event.roleIds,
                    event.personIds,
                    ensemblesOf(event.productionIds),
                  ),
            response: textValue(attendance[event.id], event.response),
            declineReason: textValue(reasons[event.id], event.declineReason),
            expectedArrivalAt: dateValue(arrivals[event.id])?.toLocal(),
            clearExpectedArrival:
                arrivals.containsKey(event.id) && arrivals[event.id] == null,
          );
          // Mirrors the server's `implicitYes` (theater.mjs): queued answers
          // and absences change it offline, so the local rule decides.
          final start = projected.startsAt;
          return projected.copyWith(
            implicitYes:
                projected.autoAccept &&
                !projected.fromSlotPool &&
                projected.addressedToMe &&
                !const {'yes', 'late', 'no'}.contains(projected.response) &&
                !(start != null && _absences.any((a) => a.coversDay(start))),
          );
        }).toList()..sort(
          (a, b) => (a.startsAt ?? DateTime(9999)).compareTo(
            b.startsAt ?? DateTime(9999),
          ),
        );
    _polls = jsonList(
      view['polls'],
    ).map((e) => Poll.fromJson(jsonMap(e))).toList();
    _slotPools = List.unmodifiable(jsonList(view['slotPools']).map(jsonMap));
    final reminders = jsonMap(view['reminders']);
    _reminders = {
      for (final key in ['dayBefore', 'twoHours', 'changes', 'emailEnabled'])
        key: reminders[key] == true,
      // Push kinds are on unless switched off.
      for (final key in ['lateDeclines', ...memberPushKeys, ...adminPushKeys])
        key: reminders[key] != false,
    };
    final customMinutes = jsonMap(view['reminders'])['customMinutes'];
    _customReminderMinutes = customMinutes is num
        ? customMinutes.toInt()
        : null;
    _checkinsByEvent = jsonMap(view['checkinsByEvent']);
    _checkinVersions = jsonMap(view['checkinVersions']);
    _capabilities = jsonMap(view['capabilities']);
    _view = view;
  }

  /// The signed-in admin as a member, to decide audiences that older servers
  /// do not decide for them; null for members (the server only sends what
  /// they are invited to) and for admins without a person record.
  TheaterMember? _audienceMember() {
    final user = _user, personId = user?.personId;
    if (user == null || !user.isAdmin || personId == null) return null;
    return _members.where((m) => m.id == personId).firstOrNull ??
        TheaterMember(id: personId, name: user.name, roleIds: user.roleIds);
  }
}

bool _sameJson(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || !_sameJson(entry.value, b[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
