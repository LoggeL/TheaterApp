part of '../../../core/app_controller.dart';

/// Script loading, archiving and the shared live focus.
extension ScriptsController on AppController {
  Future<void> loadScript(String productionId) async {
    if (_user == null) {
      throw const ApiException('Bitte zuerst anmelden.', statusCode: 401);
    }
    if (_isDemo || _loadingScripts.contains(productionId)) return;
    final generation = _generation, origin = _apiBaseUrl, token = _token!;
    _loadingScripts.add(productionId);
    _error = null;
    _notify();
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
      _scripts[productionId] = script;
      _isOffline = script.stale;
      _rebuild();
      await _persist(generation, 'script:$productionId', script.toJson);
      await _persist(
        generation,
        'script_index',
        () => {'ids': _scripts.keys.toList()},
      );
    } catch (error) {
      if (_current(generation)) {
        _error = _message(error);
        _isOffline = error is ApiException && error.retryable;
        if (error is ApiException && error.isUnauthorized) {
          await _expire(generation);
        }
      }
    } finally {
      if (_current(generation)) {
        _loadingScripts.remove(productionId);
        _notify();
      }
    }
  }

  Future<void> setProductionArchived(String productionId, bool archived) async {
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
    await performAction({
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
