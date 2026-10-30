part of '../../../core/app_controller.dart';

/// Script loading, archiving and the shared live focus.
extension ScriptsController on AppController {
  /// Fetches the script of [productionId] and keeps it for offline reading.
  ///
  /// With [ifChanged] a stored script is only fetched again when its
  /// production changed on the server since (its `revision` and `version`
  /// in the snapshot: a new script import, a new cast or a cast person's new
  /// name); readers opening a script use this. An unchanged result keeps the stored document as it
  /// is, without rebuilding, storing or notifying.
  Future<void> loadScript(String productionId, {bool ifChanged = false}) async {
    if (_user == null) {
      throw const ApiException('Bitte zuerst anmelden.', statusCode: 401);
    }
    if (_isDemo || _loadingScripts.contains(productionId)) return;
    final generation = _generation, origin = _apiBaseUrl, token = _token!;
    final stored = _scripts[productionId];
    final stamp = scriptStamp(productionId);
    if (ifChanged && stored != null && stamp != null && _account != null) {
      final index = await _store.read(_account!, 'script_index');
      if (!_current(generation) || _loadingScripts.contains(productionId)) {
        return;
      }
      if (jsonMap(index?['stamps'])[productionId] == stamp) return;
    }
    _loadingScripts.add(productionId);
    // With a stored script nobody waits, so the fetch starts silently.
    if (stored == null || _error != null) {
      _error = null;
      _notify();
    }
    var changed = false;
    try {
      final response = await _api.script(origin, token, productionId);
      if (!_current(generation)) return;
      final script = ScriptDocument.fromJson(response);
      if (script.productionId != productionId || script.revision.isEmpty) {
        throw const ApiException(
          'Das Drehbuchformat ist ungültig.',
          statusCode: 502,
        );
      }
      changed = _isOffline != script.stale;
      _isOffline = script.stale;
      final current = _scripts[productionId];
      if (current == null || !_sameScript(current, script)) {
        _scripts[productionId] = script;
        changed = true;
        _rebuild();
        await _persist(generation, 'script:$productionId', script.toJson);
      }
      await _persistScriptIndex(generation, productionId, stamp);
    } catch (error) {
      if (_current(generation)) {
        _error = _message(error);
        _isOffline = error is ApiException && error.retryable;
        changed = true;
        if (error is ApiException && error.isUnauthorized) {
          await _expire(generation, error);
        }
      }
    } finally {
      if (_current(generation)) {
        _loadingScripts.remove(productionId);
        if (changed) _notify();
      }
    }
  }

  /// What the stored script of [productionId] depends on, as the server
  /// last reported it: the script's revision and the production's version
  /// (bumped by imports, casting and renaming a cast person). Null when the
  /// production is unknown.
  String? scriptStamp(String productionId) {
    for (final production in jsonList(_baseSnapshot['productions'])) {
      final json = jsonMap(production);
      if (textValue(json['id']) == productionId) {
        return '${textValue(json['revision'])}:${textValue(json['version'])}';
      }
    }
    return null;
  }

  /// The same script, apart from when it was fetched.
  static bool _sameScript(ScriptDocument a, ScriptDocument b) {
    final left = a.toJson()..remove('cache'),
        right = b.toJson()..remove('cache');
    return a.stale == b.stale && _sameJson(left, right);
  }

  /// The stored scripts and, per script, the [scriptStamp] it was fetched
  /// at. Read and written within the write queue, so parallel loads of
  /// different scripts keep each other's stamps.
  Future<void> _persistScriptIndex(
    int generation,
    String productionId,
    String? stamp,
  ) => _write(() async {
    final account = _account;
    if (!_current(generation) || account == null) return;
    final previous = await _store.read(account, 'script_index');
    final stamps = {
      for (final entry in jsonMap(previous?['stamps']).entries)
        if (_scripts.containsKey(entry.key)) entry.key: entry.value,
    };
    if (stamp == null) {
      stamps.remove(productionId);
    } else {
      stamps[productionId] = stamp;
    }
    if (!_current(generation)) return;
    await _store.write(account, 'script_index', {
      'ids': _scripts.keys.toList(),
      'stamps': stamps,
    });
  });

  Future<ActionOutcome> setProductionArchived(
    String productionId,
    bool archived,
  ) async {
    if (_user?.isAdmin != true) {
      throw const ApiException(
        'Nur die Theaterleitung kann Drehbücher archivieren.',
        statusCode: 403,
      );
    }
    final production = _productions
        .where((p) => p.id == productionId)
        .firstOrNull;
    if (production == null) {
      throw const ApiException(
        'Die Produktion ist nicht verfügbar.',
        statusCode: 404,
      );
    }
    return performAction({
      'action': 'production.archive',
      'id': productionId,
      'version': production.version,
      'archived': archived,
    });
  }

  Future<FocusState> getFocus(String productionId) async {
    if (_isDemo) {
      return _demoFocus[productionId] ??
          FocusState(productionId: productionId, canDirect: true);
    }
    final generation = _generation;
    final response = await _api.request(
      _apiBaseUrl,
      'GET',
      '/productions/${Uri.encodeComponent(productionId)}/focus',
      token: _token,
    );
    if (!_current(generation)) {
      throw const ApiException(
        'Die Anmeldung hat sich geändert.',
        statusCode: 401,
      );
    }
    return FocusState.fromJson(response);
  }

  Future<FocusState> publishFocus(
    String productionId, {
    required String revision,
    required String cueId,
  }) async {
    if (_isDemo) {
      final focus = FocusState(
        productionId: productionId,
        revision: revision,
        cueId: cueId,
        sequence: (_demoFocus[productionId]?.sequence ?? 0) + 1,
        updatedBy: _user?.id,
        updatedAt: _clock(),
        canDirect: true,
      );
      _demoFocus[productionId] = focus;
      return focus;
    }
    final generation = _generation;
    final response = await _api.request(
      _apiBaseUrl,
      'PUT',
      '/productions/${Uri.encodeComponent(productionId)}/focus',
      token: _token,
      body: {'revision': revision, 'cueId': cueId},
    );
    if (!_current(generation)) {
      throw const ApiException(
        'Die Anmeldung hat sich geändert.',
        statusCode: 401,
      );
    }
    return FocusState.fromJson(response);
  }

  Future<FocusState> clearFocus(String productionId) async {
    if (_isDemo) {
      final focus = FocusState(
        productionId: productionId,
        sequence: (_demoFocus[productionId]?.sequence ?? 0) + 1,
        canDirect: true,
      );
      _demoFocus[productionId] = focus;
      return focus;
    }
    final generation = _generation;
    final response = await _api.request(
      _apiBaseUrl,
      'DELETE',
      '/productions/${Uri.encodeComponent(productionId)}/focus',
      token: _token,
    );
    if (!_current(generation)) {
      throw const ApiException(
        'Die Anmeldung hat sich geändert.',
        statusCode: 401,
      );
    }
    return FocusState.fromJson(response);
  }
}
