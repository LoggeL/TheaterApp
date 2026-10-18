part of '../app_controller.dart';

/// Sign-in, registration, account access, password change and logout.
extension SessionController on AppController {
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
    try {
      await _store.initialize();
      _storeReady = true;
      final settings = await _store.read('_device', 'settings');
      if (!_current(generation)) return;
      if (_apiBaseUrl.isEmpty) _apiBaseUrl = textValue(settings?['baseUrl']);
      await _loadBotCheck();
      if (_identity != null) {
        await _identity.initialize();
        if (!_current(generation)) return;
        // Members signed in before the bot check existed are never asked.
        if (_identity.uid != null && !_botCheckPassed) {
          await _rememberBotCheck();
        }
        await _restoreFirebase(generation);
        return;
      }
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
          _isOffline = true;
        }
      }
    } catch (_) {
      if (_current(generation)) {
        _error = _storeReady
            ? 'Die lokale Anmeldung konnte nicht geladen werden. Bitte melde dich erneut an.'
            : 'Der lokale Datenspeicher konnte nicht geöffnet werden. Bitte starte die App erneut; Änderungen können noch nicht sicher gespeichert werden.';
        _token = null;
        _user = null;
        _account = null;
      }
    } finally {
      if (_current(generation)) {
        _initialized = true;
        _notify();
      }
    }
    if (_current(generation) && _user != null) await refresh();
  }

  Future<void> _hydrate(int generation) async {
    final account = _account!;
    final state = await _store.read(account, 'state');
    final prefs = await _store.read(account, 'preferences');
    final scriptIndex = await _store.read(account, 'script_index');
    if (!_current(generation)) return;
    _baseSnapshot = jsonMap(state?['snapshot']);
    // The login response is newer than cached account roles/password flags.
    if (_user != null) _baseSnapshot['user'] = _user!.toJson();
    _outbox = jsonList(
      state?['outbox'],
    ).map((e) => PendingAction.fromJson(jsonMap(e))).toList();
    _lastSync = dateValue(state?['lastSync']);
    _deviceToken = state?['deviceToken'] as String?;
    _preferences = prefs ?? {};
    for (final id in jsonList(scriptIndex?['ids'])) {
      final cached = await _store.read(account, 'script:$id');
      if (!_current(generation)) return;
      if (cached != null) {
        _scripts[id.toString()] = ScriptDocument.fromJson(cached);
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
        await _adoptFirebase(botCheckProof: proof, botTrap: trap);
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
      if (!_current(generation)) return;
      await _hydrate(generation);
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

  Future<void> _restoreFirebase(int generation) async {
    final uid = _identity!.uid;
    final saved = await _credentials.read();
    if (!_current(generation)) return;
    if (uid == null) {
      await _credentials.clear();
      return;
    }
    _token = 'firebase:$uid';
    _account = _accountKey(_apiBaseUrl, uid);
    if (saved != null &&
        jsonMap(saved['user'])['userId'] == uid &&
        saved['baseUrl'] == _apiBaseUrl) {
      _user = AppUser.fromJson(jsonMap(saved['user']));
      if (_user!.isApproved) await _hydrate(generation);
    }
    try {
      await refreshAccess(refreshData: false);
      if (_current(generation) && hasAccess) await refresh();
    } on ApiException catch (e) {
      if (!_current(generation)) return;
      if (!e.retryable) rethrow;
      _isOffline = true;
      _error = e.message;
    }
  }

  Future<void> _adoptFirebase({
    String? registrationName,
    String? botCheckProof,
    BotTrapReport? botTrap,
  }) async {
    if (!_storeReady) await _ensureStore();
    final previousAccount = _account;
    ++_generation;
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
      await _adoptFirebase(
        registrationName: name.trim(),
        botCheckProof: proof,
        botTrap: trap,
      );
    });
  }

  Future<void> loginWithProvider(String provider) async {
    await _withIdentityTransition(() async {
      await _identity!.initialize();
      final proof = await _freshBotProof();
      await _identity.social(provider);
      await _adoptFirebase(botCheckProof: proof);
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
    if (_identity == null || _identity.uid == null || _isDemo) return;
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
    _user = next;
    _account ??= _accountKey(_apiBaseUrl, next.id);
    if (!next.isApproved) {
      if (previous?.isApproved == true) {
        generation = ++_generation;
        _refreshTask = null;
        _drainTask = null;
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
      await _hydrate(generation);
    } else {
      _baseSnapshot['user'] = next.toJson();
    }
    if (!_current(generation)) return;
    await _write(
      () => _credentials.write({
        'baseUrl': _apiBaseUrl,
        'token': _token,
        'user': next.toJson(),
      }),
    );
    _error = null;
    _isOffline = false;
    _notify();
    if (refreshData && next.isApproved) await refresh();
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
    _mediaLoading.clear();
    _token = null;
    _account = null;
    _user = null;
    _expiresAt = null;
    _deviceToken = null;
    _baseSnapshot = {};
    _view = {};
    _events = [];
    _absences = [];
    _polls = [];
    _slotPools = const [];
    _productions = [];
    _members = [];
    _outbox = [];
    _scripts.clear();
    _preferences = {};
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
    _checkinVersions = {};
    _capabilities = {};
    _mutationVersion = 0;
    _reminders = {
      'dayBefore': false,
      'twoHours': true,
      'changes': true,
      'emailEnabled': false,
      'lateDeclines': true,
    };
    _customReminderMinutes = null;
  }

  Future<void> _expire(int generation) async {
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
    _error = 'Deine Anmeldung ist abgelaufen. Bitte melde dich erneut an.';
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
