part of '../app_controller.dart';

extension PasskeyController on AppController {
  PasskeyDevice get _device => _passkeyDevice;

  Future<bool> passkeysAvailable() async {
    if (_identity is! PasskeyIdentity || _isDemo || _apiBaseUrl.isEmpty) {
      return false;
    }
    try {
      final config = await _api.request(_apiBaseUrl, 'GET', '/config');
      return await _device.supported(jsonMap(config['passkeys']));
    } catch (_) {
      return false;
    }
  }

  void _passkeyAccount(int generation, String? uid) {
    if (!_current(generation) || _identity?.uid != uid) {
      throw const ApiException(
        'Das Konto hat sich geändert. Bitte erneut versuchen.',
        code: 'account_changed',
      );
    }
  }

  Future<void> loginWithPasskey() async {
    final identity = _identity;
    if (identity is! PasskeyIdentity) {
      throw const ApiException('Passkeys sind nicht verfügbar.');
    }
    if (!_storeReady) await _ensureStore();
    await _withIdentityTransition(() async {
      await identity!.initialize();
      final generation = _generation, beforeUid = identity.uid;
      final origin = _apiBaseUrl;
      final challenge = await _api.request(
        origin,
        'POST',
        '/auth/passkeys/options',
        body: {},
      );
      _passkeyAccount(generation, beforeUid);
      final response = await _device.authenticate(
        jsonMap(challenge['options']),
      );
      _passkeyAccount(generation, beforeUid);
      final result = await _api.request(
        origin,
        'POST',
        '/auth/passkeys/verify',
        body: {'challengeId': challenge['challengeId'], 'response': response},
      );
      _passkeyAccount(generation, beforeUid);
      final token = textValue(result['token']), uid = textValue(result['uid']);
      if (token.isEmpty || uid.isEmpty) {
        throw const ApiException(
          'Die Passkey-Anmeldung lieferte keine gültige Sitzung.',
        );
      }
      await (identity as PasskeyIdentity).signInWithCustomToken(token, uid);
      if (!_current(generation)) {
        if (identity.uid == uid) await identity.signOut();
        throw const ApiException(
          'Die Anmeldung wurde abgebrochen.',
          code: 'account_changed',
        );
      }
      // Only the account marker is persisted by _adoptFirebase, never the
      // short-lived custom token or the WebAuthn assertion.
      await _adoptFirebase();
    });
  }

  Future<List<JsonMap>> listPasskeys() async {
    final generation = _generation, uid = _identity?.uid;
    final result = await _api.request(
      _apiBaseUrl,
      'GET',
      '/passkeys',
      token: _token,
    );
    _passkeyAccount(generation, uid);
    return jsonList(result['passkeys']).map(jsonMap).toList();
  }

  Future<void> confirmPasskeyManagement({String? password, String? provider}) =>
      _withIdentityTransition(() async {
        final identity = _identity;
        if (identity is! PasskeyIdentity) {
          throw const ApiException('Bitte erneut anmelden.');
        }
        final generation = _generation, uid = identity!.uid;
        await (identity as PasskeyIdentity).reauthenticateForPasskeys(
          password: password,
          provider: provider,
        );
        _passkeyAccount(generation, uid);
      });

  Future<List<JsonMap>> addPasskey(String name) =>
      _withIdentityTransition(() async {
        final generation = _generation, uid = _identity?.uid;
        final token = _token, origin = _apiBaseUrl;
        final challenge = await _api.request(
          origin,
          'POST',
          '/passkeys/options',
          token: token,
          body: {'name': name},
        );
        _passkeyAccount(generation, uid);
        final response = await _device.register(jsonMap(challenge['options']));
        _passkeyAccount(generation, uid);
        final result = await _api.request(
          origin,
          'POST',
          '/passkeys/verify',
          token: token,
          body: {'challengeId': challenge['challengeId'], 'response': response},
        );
        _passkeyAccount(generation, uid);
        return jsonList(result['passkeys']).map(jsonMap).toList();
      });

  Future<List<JsonMap>> removePasskey(String id) async {
    final generation = _generation, uid = _identity?.uid;
    final result = await _api.request(
      _apiBaseUrl,
      'DELETE',
      '/passkeys/${Uri.encodeComponent(id)}',
      token: _token,
    );
    _passkeyAccount(generation, uid);
    return jsonList(result['passkeys']).map(jsonMap).toList();
  }
}
