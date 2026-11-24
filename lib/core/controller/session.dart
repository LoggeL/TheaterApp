part of '../app_controller.dart';

class _LastSignIn {
  const _LastSignIn({this.email = '', this.provider = ''});
  final String email;
  final String provider;
}

final _lastSignIns = Expando<_LastSignIn>('lastSignIn');

/// Sign-in, registration, account access, password change and logout.
extension SessionController on AppController {
  /// Last email address used to sign in on this device, if remembered.
  String get lastSignInEmail => _lastSignIns[this]?.email ?? '';

  /// Last sign-in provider used on this device (e.g. `password`, `google.com`,
  /// `custom` for passkey), if remembered.
  String get lastSignInProvider => _lastSignIns[this]?.provider ?? '';

  /// Checks whether passkey sign-in is available on this device and server.
  /// Returns `null` when the check failed due to a transient error so the
  /// sign-in screen can retry later.
  Future<bool?> checkPasskeysAvailable() async {
    if (_identity is! PasskeyIdentity || _isDemo || _apiBaseUrl.isEmpty) {
      return false;
    }
    try {
      final config = await _api.request(_apiBaseUrl, 'GET', '/config');
      return await _passkeyDevice.supported(jsonMap(config['passkeys']));
    } catch (_) {
      return null;
    }
  }

  Future<void> _rememberSignIn({String? email, String? provider}) async {
    final current = _lastSignIns[this];
    final nextEmail = (email ?? current?.email ?? '').trim();
    final nextProvider = (provider ?? current?.provider ?? '').trim();
    if (nextEmail.isEmpty && nextProvider.isEmpty) return;
    if (current != null &&
        current.email == nextEmail &&
        current.provider == nextProvider) {
      return;
    }
    _lastSignIns[this] = _LastSignIn(email: nextEmail, provider: nextProvider);
    if (!_storeReady) return;
    await _write(
      () => _store.write('_device', 'last_sign_in', {
        if (nextEmail.isNotEmpty) 'email': nextEmail,
        if (nextProvider.isNotEmpty) 'provider': nextProvider,
      }),
    );
  }

  Future<T> _withIdentityTransition<T>(Future<T> Function() operation) {
    final previous = _identityTransition;
    final finished = Completer<void>();
    _identityTransition = finished.future;
    return () async {
      await previous;
      try {
        return await operation();
      } finally {
        finished.complete();
      }
    }();
  }

  Future<void> init() async {
    if (_initialized) return;
    final generation = _generation;
    // Firebase restores its sign-in while the local store opens.
    final identityStart = _identity == null ? null : _startIdentity();
    String? cachedUid;
    var deferFirebaseSync = false;
    var deferLegacySync = false;
    try {
      await _store.initialize();
      _storeReady = true;
      final settings = await _store.read('_device', 'settings');
      if (!_current(generation)) return;
      if (_apiBaseUrl.isEmpty) _apiBaseUrl = textValue(settings?['baseUrl']);
      final lastSignIn = await _store.read('_device', 'last_sign_in');
      if (!_current(generation)) return;
      if (lastSignIn != null) {
        _lastSignIns[this] = _LastSignIn(
          email: textValue(lastSignIn['email']),
          provider: textValue(lastSignIn['provider']),
        );
      }
      await _loadBotCheck();
      if (_identity != null) {
        cachedUid = await _restoreCached(generation);
        if (cachedUid == null) {
          await identityStart;
          if (!_current(generation)) return;
          deferFirebaseSync = await _restoreIdentity(
            generation,
            deferNetwork: true,
          );
        }
      } else {
        final saved = await _credentials.read();
        if (!_current(generation)) return;
        if (saved != null) {
          _apiBaseUrl = ApiClient.normalizeBaseUrl(textValue(saved['baseUrl']));
          _expiresAt = dateValue(saved['expiresAt']);
          if (_expiresAt != null && !_expiresAt!.isAfter(_clock())) {
            await _write(() => _credentials.clear());
            _error =
                'Deine Anmeldung ist abgelaufen. Bitte melde dich erneut an.';
          } else {
            _token = textValue(saved['token']);
            _user = AppUser.fromJson(jsonMap(saved['user']));
            if (_token!.isEmpty || _user!.id.isEmpty) {
              throw const FormatException('Invalid cached session');
            }
            _account = _accountKey(_apiBaseUrl, _user!.id);
            await _hydrate(generation);
            if (!_current(generation)) return;
            if (!_user!.mustChangePassword && _baseSnapshot.isNotEmpty) {
              deferLegacySync = true;
            } else {
              _isOffline = true;
            }
          }
        }
      }
    } catch (_) {
      if (_current(generation)) {
        cachedUid = null;
        deferFirebaseSync = false;
        deferLegacySync = false;
        _dropStartSession();
      }
    } finally {
      if (_current(generation)) {
        _initialized = true;
        _notify();
      }
    }
    if (!_current(generation)) return;
    if (cachedUid != null) {
      _firstSyncPending.value = true;
      _startSync = _verifyCachedStart(generation, cachedUid, identityStart!);
    } else if (deferFirebaseSync) {
      _firstSyncPending.value = true;
      _startSync = _syncFirebaseStart(generation);
    } else if (deferLegacySync) {
      _firstSyncPending.value = true;
      _startSync = _syncLegacyStart(generation);
    } else if (_identity == null && _user != null) {
      await refresh();
    }
  }

  /// The start failed: no session, and a hint what to do.
  void _dropStartSession() {
    _error = _storeReady
        ? 'Die lokale Anmeldung konnte nicht geladen werden. Bitte melde dich erneut an.'
        : 'Der lokale Datenspeicher konnte nicht geöffnet werden. Bitte starte die App erneut; Änderungen können noch nicht sicher gespeichert werden.';
    _token = null;
    _user = null;
    _account = null;
  }

  /// Starts restoring the Firebase sign-in. A sign-out waits for it.
  Future<void> _startIdentity() {
    final start = _withIdentityTransition(() => _identity!.initialize());
    _identityPending = true;
    void done() => _identityPending = false;
    _identityReady = start.then((_) => done(), onError: (Object _) => done());
    return start;
  }

  /// Members signed in before the bot check existed are never asked.
  Future<bool> _restoreIdentity(
    int generation, {
    bool deferNetwork = false,
  }) async {
    if (_identity!.uid != null && !_botCheckPassed) await _rememberBotCheck();
    return _restoreFirebase(generation, deferNetwork: deferNetwork);
  }

  /// Cache-first start: shows the stored data of the last approved Firebase
  /// account before Firebase has restored its sign-in. Returns that account's
  /// uid, or null when the start has to wait for Firebase (no usable cache,
  /// another server, a waiting account, or switched off by the server).
  Future<String?> _restoreCached(int generation) async {
    final saved = await _credentials.read();
    if (!_current(generation) || saved == null) return null;
    final user = AppUser.fromJson(jsonMap(saved['user']));
    if (user.id.isEmpty ||
        !user.isApproved ||
        user.mustChangePassword ||
        saved['baseUrl'] != _apiBaseUrl) {
      return null;
    }
    final account = _accountKey(_apiBaseUrl, user.id);
    final state = await _store.read(account, 'state');
    if (!_current(generation) || state == null) return null;
    final snapshot = jsonMap(state['snapshot']);
    final features = jsonList(jsonMap(snapshot['capabilities'])['features']);
    if (jsonMap(snapshot['user'])['userId'] != user.id ||
        features.contains('noCacheFirstStart') ||
        !(AppController.cacheFirstStartByDefault ||
            features.contains('cacheFirstStart'))) {
      return null;
    }
    _user = user;
    _storedUser = user.toJson();
    _token = 'firebase:${user.id}';
    _account = account;
    await _hydrate(generation, state: state);
    return _current(generation) ? user.id : null;
  }

  /// The background half of a cache-first start: once Firebase has restored
  /// its sign-in, a different or missing sign-in drops the shown data and
  /// starts like before; the same one checks the access and syncs. Errors
  /// show as offline or sync error, the stored data stays.
  Future<void> _verifyCachedStart(
    int generation,
    String uid,
    Future<void> identityStart,
  ) async {
    try {
      try {
        await identityStart;
      } catch (_) {
        if (!_current(generation)) return;
        ++_generation;
        _resetMemory();
        _dropStartSession();
        _notify();
        return;
      }
      if (!_current(generation)) return;
      if (_identity!.uid != uid) {
        final next = ++_generation;
        _resetMemory();
        _notify();
        try {
          await _restoreIdentity(next);
        } catch (_) {
          if (_current(next)) _dropStartSession();
        }
        if (_current(next)) _notify();
        return;
      }
      if (!_botCheckPassed) await _rememberBotCheck();
      await refreshAccess(refreshData: false);
      if (!_current(generation) || !hasAccess) return;
      _startSync = null;
      await refresh(silent: true, accessChecked: true);
    } catch (error) {
      if (!_current(generation)) return;
      // A Firebase token error becomes an ApiException (see
      // [identityTokenFailure]); any other error with the sign-in gone
      // ends the session as well.
      if (error is ApiException && error.isUnauthorized ||
          error is! ApiException && _identity!.uid != uid) {
        await _expire(generation, error);
        return;
      }
      _isOffline = error is ApiException && error.retryable;
      _error = _message(error);
      _notify();
    } finally {
      if (_current(generation)) {
        _startSync = null;
        _firstSyncPending.value = false;
      }
    }
  }

  /// Background half of a Firebase start whose local data was already hydrated
  /// after identity restoration (avoiding a 20s splash block when offline).
  Future<void> _syncFirebaseStart(int generation) async {
    final uid = _identity?.uid;
    try {
      await Future<void>.value();
      if (!_current(generation) || _identity == null || uid == null) return;
      await refreshAccess(refreshData: false);
      if (!_current(generation) || !hasAccess) return;
      _startSync = null;
      await refresh(silent: true, accessChecked: true);
    } catch (error) {
      if (!_current(generation)) return;
      if (error is ApiException && error.isUnauthorized ||
          error is! ApiException && _identity?.uid != uid) {
        await _expire(generation, error);
        return;
      }
      _isOffline = error is ApiException && error.retryable;
      _error = _message(error);
      _notify();
    } finally {
      if (_current(generation)) {
        _startSync = null;
        _firstSyncPending.value = false;
      }
    }
  }

  /// Background half of a legacy session start once local data is hydrated.
  Future<void> _syncLegacyStart(int generation) async {
    try {
      await Future<void>.value();
      if (!_current(generation) || _user == null) return;
      _startSync = null;
      await refresh(silent: true);
    } finally {
      if (_current(generation)) {
        _startSync = null;
        _firstSyncPending.value = false;
      }
    }
  }

  /// [_hydrate] for a sign-in that does not continue a stored session. The
  /// server keeps one row per device token and another account of this
  /// device may hold it by now, so the next push restore registers again.
  Future<void> _hydrateSignIn(int generation) async {
    await _hydrate(generation);
    if (!_current(generation) || _deviceRegisteredAt == null) return;
    _deviceRegisteredAt = null;
    await _persistCore(generation);
  }

  Future<void> _hydrate(int generation, {JsonMap? state}) async {
    final account = _account!;
    final results = await Future.wait<JsonMap?>([
      state == null ? _store.read(account, 'state') : Future.value(state),
      _store.read(account, 'preferences'),
      _store.read(account, 'script_index'),
    ]);
    state = results[0];
    final prefs = results[1];
    final scriptIndex = results[2];
    if (!_current(generation)) return;
    _baseSnapshot = jsonMap(state?['snapshot']);
    // The login response is newer than cached account roles/password flags.
    if (_user != null) _baseSnapshot['user'] = _user!.toJson();
    _replaceOutbox(
      jsonList(
        state?['outbox'],
      ).map((e) => PendingAction.fromJson(readJsonMap(e))),
    );
    _lastSync = dateValue(state?['lastSync']);
    _deviceToken = state?['deviceToken'] as String?;
    _deviceRegisteredAt = dateValue(state?['deviceRegisteredAt']);
    _preferences
      ..clear()
      ..addAll(prefs ?? const {});
    final scriptIds = [for (final id in jsonList(scriptIndex?['ids'])) '$id'];
    if (scriptIds.isNotEmpty) {
      final cachedScripts = await Future.wait<JsonMap?>([
        for (final id in scriptIds) _store.read(account, 'script:$id'),
      ]);
      if (!_current(generation)) return;
      for (var i = 0; i < scriptIds.length; i++) {
        final cached = cachedScripts[i];
        if (cached != null) {
          _scripts[scriptIds[i]] = ScriptDocument.fromJson(cached);
        }
      }
    }
    _rebuild();
  }

  /// [trap] is the sign-in form's bot trap, judged if this creates the
  /// server account.
  Future<void> login({
    required String email,
    required String password,
    required String baseUrl,
    BotTrapReport? trap,
  }) async {
    if (_identity != null) {
      final origin = ApiClient.normalizeBaseUrl(baseUrl);
      if (!_storeReady) await _ensureStore();
      await _withIdentityTransition(() async {
        await _identity.initialize();
        _apiBaseUrl = origin;
        final proof = await _freshBotProof();
        await _identity.signIn(email, password);
        await _write(
          () => _store.write('_device', 'settings', {'baseUrl': origin}),
        );
        await _rememberSignIn(email: email, provider: 'password');
        await _adoptFirebase(
          botCheckProof: proof,
          botTrap: trap,
          signInProvider: 'password',
        );
      });
      return;
    }
    if (!_storeReady) await _ensureStore();
    final origin = ApiClient.normalizeBaseUrl(baseUrl);
    if (email.trim().isEmpty || password.isEmpty) {
      throw const ApiException('Bitte E-Mail-Adresse und Passwort eingeben.');
    }
    final generation = ++_generation;
    _resetMemory();
    _busyCount = 1;
    _error = null;
    _notify();
    try {
      await _write(() async {
        if (_current(generation)) await _credentials.clear();
      });
      if (!_current(generation)) return;
      final response = await _api.login(origin, email, password);
      if (!_current(generation)) return;
      final token = textValue(response['token']);
      final user = AppUser.fromJson(jsonMap(response['user']));
      if (token.isEmpty || user.id.isEmpty) {
        throw const ApiException(
          'Die Anmeldung lieferte keine gültige Sitzung.',
          statusCode: 502,
        );
      }
      _apiBaseUrl = origin;
      _token = token;
      _user = user;
      _expiresAt = dateValue(response['expiresAt']);
      _account = _accountKey(origin, user.id);
      await _write(() async {
        if (!_current(generation)) return;
        await _credentials.write({
          'baseUrl': origin,
          'token': token,
          'user': user.toJson(),
          'expiresAt': response['expiresAt'],
        });
        await _store.write('_device', 'settings', {'baseUrl': origin});
      });
      await _rememberSignIn(
        email: user.email.isNotEmpty ? user.email : email,
        provider: 'password',
      );
      if (!_current(generation)) return;
      await _hydrateSignIn(generation);
      if (!_current(generation)) return;
      // Authentication succeeded. A following network failure remains an explicit
      // offline state; it never silently substitutes sample data.
      _notify();
      await refresh();
    } catch (error) {
      if (_current(generation)) {
        _error = _message(error);
        if (_token == null) {
          _user = null;
          _account = null;
        }
        _notify();
      }
      rethrow;
    } finally {
      if (_current(generation)) {
        _busyCount = 0;
        _notify();
      }
    }
  }

  Future<void> startDemo() async {
    if (!_storeReady) await _ensureStore();
    final generation = ++_generation;
    _resetMemory();
    _isDemo = true;
    _account = 'demo';
    _error = null;
    final demo = DemoData(now: _clock());
    _baseSnapshot = demo.snapshot();
    _scripts[DemoData.mainProductionId] = demo.script(
      DemoData.mainProductionId,
    );
    _scripts[DemoData.secondProductionId] = demo.script(
      DemoData.secondProductionId,
    );
    _lastSync = _clock();
    _rebuild();
    _notify();
    await _write(() async {
      if (_current(generation)) await _credentials.clear();
    });
    await _persistCore(generation);
  }

  Future<bool> _restoreFirebase(
    int generation, {
    bool deferNetwork = false,
  }) async {
    final uid = _identity!.uid;
    final saved = await _credentials.read();
    if (!_current(generation)) return false;
    if (uid == null) {
      await _credentials.clear();
      return false;
    }
    _token = 'firebase:$uid';
    _account = _accountKey(_apiBaseUrl, uid);
    if (saved != null &&
        jsonMap(saved['user'])['userId'] == uid &&
        saved['baseUrl'] == _apiBaseUrl) {
      _user = AppUser.fromJson(jsonMap(saved['user']));
      _storedUser = _user!.toJson();
      if (_user!.isApproved) await _hydrate(generation);
    }
    if (!_current(generation)) return false;
    final features = jsonList(
      jsonMap(_baseSnapshot['capabilities'])['features'],
    );
    if (deferNetwork &&
        _user != null &&
        _user!.isApproved &&
        !_user!.mustChangePassword &&
        _baseSnapshot.isNotEmpty &&
        !features.contains('noCacheFirstStart')) {
      return true;
    }
    try {
      await refreshAccess(refreshData: false);
      if (_current(generation) && hasAccess) {
        await refresh(accessChecked: true);
      }
    } on ApiException catch (e) {
      if (!_current(generation)) return false;
      if (!e.retryable) rethrow;
      _isOffline = true;
      _error = e.message;
    }
    return false;
  }

  Future<void> _adoptFirebase({
    String? registrationName,
    String? botCheckProof,
    BotTrapReport? botTrap,
    String? signInProvider,
  }) async {
    if (!_storeReady) await _ensureStore();
    final previousAccount = _account;
    final generation = ++_generation;
    _resetMemory();
    _token = 'firebase:${_identity!.uid}';
    _account = _accountKey(_apiBaseUrl, _identity.uid!);
    if (previousAccount != null && previousAccount != _account) {
      await _store.clearAccount(previousAccount);
    }
    await refreshAccess(
      registrationName: registrationName,
      botCheckProof: botCheckProof,
      botTrap: botTrap,
    );
    if (_current(generation)) {
      final email = _user?.email.isNotEmpty == true
          ? _user!.email
          : (_identity.email ?? '');
      await _rememberSignIn(
        email: email,
        provider: signInProvider ?? 'custom',
      );
    }
    if (botCheckProof != null) _consumeBotProof();
    if (!_botCheckPassed) await _rememberBotCheck();
  }

  /// [trap] is the registration form's bot trap.
  Future<void> register(
    String name,
    String email,
    String password, {
    BotTrapReport? trap,
  }) async {
    if (_identity == null) {
      throw const ApiException('Die Registrierung benötigt Firebase Auth.');
    }
    if (name.trim().isEmpty ||
        name.trim().length > 120 ||
        password.length < 12) {
      throw const ApiException(
        'Bitte Name und ein Passwort mit mindestens 12 Zeichen eingeben.',
      );
    }
    await _withIdentityTransition(() async {
      await _identity.initialize();
      final proof = await _freshBotProof();
      await _identity.register(name, email, password);
      await _rememberSignIn(email: email, provider: 'password');
      await _adoptFirebase(
        registrationName: name.trim(),
        botCheckProof: proof,
        botTrap: trap,
        signInProvider: 'password',
      );
    });
  }

  Future<void> loginWithProvider(String provider) async {
    await _withIdentityTransition(() async {
      await _identity!.initialize();
      final proof = await _freshBotProof();
      await _identity.social(provider);
      await _adoptFirebase(botCheckProof: proof, signInProvider: provider);
    });
  }

  Future<void> refreshIdentityAccess() async {
    if (_identity == null || _isDemo || _user == null) return;
    final generation = _generation, uid = _identity.uid;
    if (uid == null) return;
    await _withIdentityTransition(() async {
      if (!_current(generation) || _identity.uid != uid) return;
      await _identity.reload();
      if (!_current(generation) || _identity.uid != uid) return;
      await refreshAccess();
    });
  }

  Future<void> saveRegistrationName(String name) async {
    if (_isDemo || _user?.status != 'pending') {
      throw const ApiException(
        'Der Name kann nur vor der Freigabe geändert werden.',
      );
    }
    if (name.trim().isEmpty || name.trim().length > 120) {
      throw const ApiException(
        'Bitte deinen Namen mit höchstens 120 Zeichen eingeben.',
      );
    }
    await refreshAccess(registrationName: name.trim());
  }

  /// [botCheckProof] proves the answered bot check and [botTrap] reports the
  /// form's bot trap when the server creates the account; older servers
  /// ignore both.
  Future<void> refreshAccess({
    bool refreshData = true,
    String? registrationName,
    String? botCheckProof,
    BotTrapReport? botTrap,
  }) async {
    if (_identity == null || _isDemo) return;
    // A cache-first start may still be restoring the Firebase sign-in.
    if (_identityPending) await _identityReady;
    if (_identity.uid == null) return;
    var generation = _generation;
    final post =
        registrationName != null || botCheckProof != null || botTrap != null;
    final result = await _api.request(
      _apiBaseUrl,
      post ? 'POST' : 'GET',
      '/auth/session',
      token: _token,
      body: post
          ? {
              'registrationName': ?registrationName,
              'botCheckProof': ?botCheckProof,
              'botTrap': ?botTrap?.toJson(),
            }
          : null,
    );
    if (!_current(generation)) return;
    final previous = _user;
    final next = AppUser.fromJson(jsonMap(result['user']));
    if (next.id != _identity.uid) {
      throw const ApiException(
        'Die Anmeldung passt nicht zum Konto.',
        statusCode: 401,
      );
    }
    // Only a change is stored and shown; the background sync asks often.
    final changed =
        previous == null || !_sameJson(previous.toJson(), next.toJson());
    final settled = _error == null && !_isOffline;
    _user = next;
    _account ??= _accountKey(_apiBaseUrl, next.id);
    if (!next.isApproved) {
      if (previous?.isApproved == true) {
        generation = ++_generation;
        _refreshTask = null;
        _drainTask = null;
        _startSync = null;
        _firstSyncPending.value = false;
        _loadingScripts.clear();
        _busyCount = 0;
        _refreshing = false;
      }
      await _write(() => _store.clearAccount(_account!));
      if (!_current(generation)) return;
      _baseSnapshot = {'user': next.toJson()};
      _outbox.clear();
      _scripts.clear();
      _preferences.clear();
      _rebuild();
    } else if (previous?.isApproved != true) {
      await _hydrateSignIn(generation);
    } else {
      // The server's own map, so the next unchanged snapshot compares equal
      // (it carries fields the app does not keep, like `provider`).
      _baseSnapshot['user'] = jsonMap(result['user']);
    }
    if (!_current(generation)) return;
    _accessCheckedAt = _clock();
    await _storeFirebaseUser(generation, next);
    if (_current(generation) &&
        lastSignInEmail.isEmpty &&
        next.email.isNotEmpty) {
      await _rememberSignIn(email: next.email);
    }
    if (!_current(generation)) return;
    _error = null;
    _isOffline = false;
    if (changed || !settled) _notify();
    if (refreshData && next.isApproved) await refresh(accessChecked: true);
  }

  /// Keeps the stored Firebase sign-in in step with the shown user, also
  /// when a role or name arrives with a snapshot, so the next cache-first
  /// start shows it. Writes only a change.
  Future<void> _storeFirebaseUser(int generation, AppUser user) async {
    final json = user.toJson();
    final stored = _storedUser;
    if (stored != null && _sameJson(stored, json)) return;
    await _write(() async {
      if (!_current(generation)) return;
      await _credentials.write({
        'baseUrl': _apiBaseUrl,
        'token': _token,
        'user': json,
      });
      _storedUser = json;
    });
  }

  Future<void> changePassword(String current, String next) async {
    if (_isDemo) {
      throw const ApiException('Im Demo-Modus gibt es kein echtes Passwort.');
    }
    if (next.length < 12 || next.length > 200) {
      throw const ApiException(
        'Das neue Passwort muss 12 bis 200 Zeichen haben.',
        statusCode: 400,
      );
    }
    if (_identity != null) {
      await _identity.changePassword(current, next);
      await _identity.reload();
      await refreshAccess();
      return;
    }
    final generation = _generation;
    final response = await _api.request(
      _apiBaseUrl,
      'POST',
      '/auth/password',
      token: _token,
      body: {'currentPassword': current, 'password': next},
    );
    if (!_current(generation)) return;
    final newToken = textValue(response['token']);
    final nextUser = AppUser.fromJson(jsonMap(response['user']));
    if (newToken.isEmpty || nextUser.id != _user?.id) {
      throw const ApiException(
        'Die erneuerte Anmeldung ist ungültig.',
        statusCode: 502,
      );
    }
    // Token rotation invalidates every outstanding request using the old token,
    // while retaining this account's cache and durable changes.
    final renewedGeneration = ++_generation;
    _refreshTask = null;
    _drainTask = null;
    _loadingScripts.clear();
    _busyCount = 0;
    _token = newToken;
    _user = nextUser;
    _expiresAt = dateValue(response['expiresAt']);
    _baseSnapshot['user'] = nextUser.toJson();
    _deviceToken = null;
    _deviceRegisteredAt = null;
    await _write(() async {
      if (_current(renewedGeneration)) {
        await _credentials.write({
          'baseUrl': _apiBaseUrl,
          'token': newToken,
          'user': nextUser.toJson(),
          'expiresAt': response['expiresAt'],
        });
      }
    });
    await _persistCore(renewedGeneration);
    _notify();
    await refresh();
  }

  Future<void> logout() async {
    final exitingGeneration = _generation;
    try {
      await beforeLogout?.call();
    } catch (_) {
      /* Local logout must remain possible offline. */
    }
    if (!_current(exitingGeneration)) return;
    final token = _token, origin = _apiBaseUrl, account = _account;
    final deviceToken = _deviceToken;
    final generation = ++_generation;
    _resetMemory();
    _error = null;
    _notify();
    // Local removal is unconditional. Failed remote revocation is surfaced.
    // The web worker's picture caches go as well, even when no request is sent.
    unawaited(clearPrivateWebCaches());
    await _write(() async {
      await _credentials.clear();
      if (account != null) await _store.clearAccount(account);
    });
    if (token != null) {
      if (deviceToken != null) {
        try {
          await _api.request(
            origin,
            'DELETE',
            '/devices',
            token: token,
            body: {'token': deviceToken},
          );
        } catch (_) {
          /* The logout endpoint retries removal for this device only. */
        }
      }
      try {
        await _api.request(
          origin,
          'POST',
          '/auth/logout',
          token: token,
          body: {'deviceToken': deviceToken},
        );
      } catch (_) {
        if (_current(generation) && _user == null) {
          _error =
              'Lokal abgemeldet. Die Sitzung konnte am Server wegen der fehlenden Verbindung noch nicht widerrufen werden.';
          _notify();
        }
      }
    }
    if (_identity != null) {
      await _withIdentityTransition(() async {
        if (_current(generation)) await _identity.signOut();
      });
    }
  }

  void _resetMemory() {
    _mediaCache.clear();
    _mediaCacheBytes = 0;
    _mediaLoading.clear();
    _token = null;
    _account = null;
    _user = null;
    _storedUser = null;
    _expiresAt = null;
    _deviceToken = null;
    _deviceRegisteredAt = null;
    _accessCheckedAt = null;
    _deviceRegistration = null;
    _deviceRegistrationToken = null;
    _startSync = null;
    _firstSyncPending.value = false;
    _baseSnapshot = {};
    _events = [];
    _absences = [];
    _polls = [];
    _slotPools = const [];
    _productions = [];
    _members = [];
    _eventsView = const [];
    _absencesView = const [];
    _pollsView = const [];
    _productionsView = const [];
    _activeProductionsView = const [];
    _archivedProductionsView = const [];
    _membersView = const [];
    _memberById = const {};
    _eventById = const {};
    _productionById = const {};
    _messagesView = const [];
    _pendingAccountsView = const [];
    _openRegistrationCount = 0;
    _memberAttendanceByEventView = const {};
    _implicitAttendanceByEventView = const {};
    _arrivalsByEventView = const {};
    _autoCheckinsByEvent = const {};
    _productionRecordsView = const [];
    _memberRecordsView = const [];
    _personRolesView = const [];
    _outbox.clear();
    _scripts.clear();
    _preferences.clear();
    _demoFocus.clear();
    _loadingScripts.clear();
    _lastSync = null;
    _busyCount = 0;
    _refreshing = false;
    _isDemo = false;
    _isOffline = false;
    _refreshTask = null;
    _drainTask = null;
    _checkinsByEvent = {};
    _checkinsByEventView = const {};
    _checkinVersions = {};
    _checkinVersionsView = const {};
    _capabilities = {};
    _capabilitiesView = const {};
    _features = const {};
    _mutationVersion = 0;
    _reminders = {..._defaultReminders};
    _remindersView = _defaultReminders;
    _customReminderMinutes = null;
    _dataVersion++;
  }

  /// [cause] is the failed request's error; a session Firebase ended
  /// (e.g. a disabled account) keeps its own message.
  Future<void> _expire(int generation, [Object? cause]) async {
    if (!_current(generation)) return;
    // Keep the isolated durable outbox so logging into the same account can
    // continue it. Only explicit logout deliberately discards account data.
    await _persistCore(generation);
    await _write(() async {
      if (_current(generation)) await _credentials.clear();
    });
    if (!_current(generation)) return;
    ++_generation;
    _resetMemory();
    _error = cause is ApiException && cause.code == identitySessionEnded
        ? cause.message
        : 'Deine Anmeldung ist abgelaufen. Bitte melde dich erneut an.';
    _notify();
  }

  Future<void> _ensureStore() async {
    try {
      await _store.initialize();
      _storeReady = true;
    } catch (_) {
      throw const ApiException(
        'Der lokale Datenspeicher ist nicht verfügbar. Bitte starte die App erneut.',
      );
    }
  }

  String _accountKey(String baseUrl, String userId) =>
      base64Url.encode(utf8.encode('$baseUrl\n$userId'));
}
