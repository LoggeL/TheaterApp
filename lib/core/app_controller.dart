import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/api_client.dart';
import '../data/demo_data.dart';
import '../data/local_store.dart';
import 'models.dart';
import 'identity.dart';

/// Owns one signed-in account. Screens listen to this controller; all requests,
/// cache writes and queued changes are fenced against a later account switch.
class AppController extends ChangeNotifier {
  AppController({
    ApiClient? apiClient,
    LocalStore? localStore,
    CredentialStore? credentialStore,
    IdentityService? identity,
    DateTime Function()? clock,
  }) : _api = apiClient ?? ApiClient(),
       _store =
           localStore ??
           (kIsWeb ? PreferencesLocalStore() : SqliteLocalStore()),
       _credentials =
           credentialStore ??
           (kIsWeb ? PreferencesCredentialStore() : SecureCredentialStore()),
       _identity = identity,
       _clock = clock ?? DateTime.now {
    _api.firebaseToken = identity?.token;
  }

  final ApiClient _api;
  final LocalStore _store;
  final CredentialStore _credentials;
  final IdentityService? _identity;
  IdentityService? get identity => _identity;
  bool get usesFirebase => _identity != null;
  bool get hasAccess => _user?.isApproved == true;
  List<JsonMap> get messages =>
      jsonList(_baseSnapshot['messages']).map(jsonMap).toList();
  List<JsonMap> get pendingAccounts =>
      jsonList(_baseSnapshot['pendingAccounts']).map(jsonMap).toList();
  JsonMap get memberAttendanceByEvent =>
      jsonMap(_baseSnapshot['memberAttendanceByEvent']);
  JsonMap get arrivalsByEvent => jsonMap(_baseSnapshot['arrivalsByEvent']);
  JsonMap get checkinVersions => cloneJson(_checkinVersions);
  JsonMap _checkinVersions = {};
  List<JsonMap> get productionRecords =>
      jsonList(_baseSnapshot['productions']).map(jsonMap).toList();
  List<JsonMap> get memberRecords =>
      jsonList(_baseSnapshot['members']).map(jsonMap).toList();
  final DateTime Function() _clock;
  Future<void> _writeTail = Future.value();
  Future<void>? _refreshTask, _drainTask;
  int _generation = 0, _busyCount = 0, _mutationVersion = 0;
  bool _initialized = false,
      _isDemo = false,
      _isOffline = false,
      _storeReady = false,
      _disposed = false;
  String _apiBaseUrl = const String.fromEnvironment('API_BASE_URL');
  String? _token, _account, _error, _deviceToken;
  DateTime? _lastSync, _expiresAt;
  AppUser? _user;
  JsonMap _baseSnapshot = {};
  List<TheaterEvent> _events = [];
  List<Absence> _absences = [];
  List<Poll> _polls = [];
  List<Production> _productions = [];
  List<TheaterMember> _members = [];
  List<PendingAction> _outbox = [];
  final Map<String, ScriptDocument> _scripts = {};
  final Map<String, FocusState> _demoFocus = {};
  final Set<String> _loadingScripts = {};
  JsonMap _preferences = {};
  Map<String, bool> _reminders = {
    'dayBefore': true,
    'twoHours': true,
    'changes': true,
  };
  JsonMap _checkinsByEvent = {}, _capabilities = {};

  bool get initialized => _initialized;
  int get sessionEpoch => _generation;
  bool get busy => _busyCount > 0;
  bool get isDemo => _isDemo;
  bool get isOffline => _isOffline;
  bool get isAuthenticated => _user != null;
  String get apiBaseUrl => _apiBaseUrl;
  AppUser? get user => _user;
  String? get error => _error;
  DateTime? get lastSync => _lastSync;
  DateTime? get expiresAt => _expiresAt;
  List<TheaterEvent> get events => List.unmodifiable(_events);
  List<Absence> get absences => List.unmodifiable(_absences);
  List<Poll> get polls => List.unmodifiable(_polls);
  List<Production> get productions => List.unmodifiable(_productions);
  List<TheaterMember> get members => List.unmodifiable(_members);
  List<PendingAction> get outbox => List.unmodifiable(_outbox);
  Map<String, ScriptDocument> get scripts => Map.unmodifiable(_scripts);
  Map<String, dynamic> get preferences => Map.unmodifiable(_preferences);
  Map<String, bool> get reminders => Map.unmodifiable(_reminders);
  JsonMap get checkinsByEvent => cloneJson(_checkinsByEvent);
  JsonMap get capabilities => Map.unmodifiable(_capabilities);
  Set<String> get loadingScripts => Set.unmodifiable(_loadingScripts);
  int get pendingCount => _outbox.where((e) => !e.failed).length;
  int get failedCount => _outbox.where((e) => e.failed).length;
  bool get pushConfigured =>
      _capabilities['pushConfigured'] == true ||
      _capabilities['pushEnabled'] == true ||
      _capabilities['push'] == true;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void clearError() {
    _error = null;
    _notify();
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> _write(Future<void> Function() work) {
    final task = _writeTail.catchError((Object _) {}).then((_) => work());
    _writeTail = task;
    return task;
  }

  Future<void> _persist(int generation, String key, JsonMap Function() value) =>
      _write(() async {
        if (_current(generation) && _account != null) {
          await _store.write(_account!, key, value());
        }
      });
  Future<void> _persistCore(int generation) => _persist(
    generation,
    'state',
    () => {
      'snapshot': _baseSnapshot,
      'outbox': _outbox.map((e) => e.toJson()).toList(),
      'lastSync': _lastSync?.toIso8601String(),
      'deviceToken': _deviceToken,
    },
  );

  Future<void> init() async {
    if (_initialized) return;
    final generation = _generation;
    try {
      await _store.initialize();
      _storeReady = true;
      final settings = await _store.read('_device', 'settings');
      if (!_current(generation)) return;
      if (_apiBaseUrl.isEmpty) _apiBaseUrl = textValue(settings?['baseUrl']);
      if (_identity != null) {
        await _identity.initialize();
        if (!_current(generation)) return;
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

  Future<void> login({
    required String email,
    required String password,
    required String baseUrl,
  }) async {
    if (_identity != null) {
      final origin = ApiClient.normalizeBaseUrl(baseUrl);
      if (!_storeReady) await _ensureStore();
      await _identity.initialize();
      await _identity.signIn(email, password);
      _apiBaseUrl = origin;
      await _write(
        () => _store.write('_device', 'settings', {'baseUrl': origin}),
      );
      await _adoptFirebase();
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

  Future<void> _adoptFirebase() async {
    if (!_storeReady) await _ensureStore();
    final previousAccount = _account;
    ++_generation;
    _resetMemory();
    _token = 'firebase:${_identity!.uid}';
    _account = _accountKey(_apiBaseUrl, _identity.uid!);
    if (previousAccount != null && previousAccount != _account) {
      await _store.clearAccount(previousAccount);
    }
    await refreshAccess();
  }

  Future<void> register(String name, String email, String password) async {
    if (_identity == null) {
      throw const ApiException('Die Registrierung benötigt Firebase Auth.');
    }
    if (name.trim().isEmpty || password.length < 12) {
      throw const ApiException(
        'Bitte Name und ein Passwort mit mindestens 12 Zeichen eingeben.',
      );
    }
    await _identity.initialize();
    await _identity.register(name, email, password);
    await _adoptFirebase();
  }

  Future<void> loginWithProvider(String provider) async {
    await _identity!.initialize();
    await _identity.social(provider);
    await _adoptFirebase();
  }

  Future<void> refreshAccess({bool refreshData = true}) async {
    if (_identity == null || _identity.uid == null || _isDemo) return;
    var generation = _generation;
    final result = await _api.request(
      _apiBaseUrl,
      'GET',
      '/auth/session',
      token: _token,
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

  Future<JsonMap> remote(
    String path, {
    String method = 'GET',
    JsonMap? body,
  }) async {
    if (_isDemo) {
      throw const ApiException(
        'Diese Funktion benötigt ein verbundenes Theaterkonto.',
      );
    }
    if (!hasAccess) {
      throw const ApiException(
        'Der Zugang ist noch nicht freigegeben.',
        statusCode: 403,
      );
    }
    final generation = _generation;
    final result = await _api.request(
      _apiBaseUrl,
      method,
      path,
      token: _token,
      body: body,
    );
    if (!_current(generation)) {
      throw const ApiException('Das Konto hat sich geändert.', statusCode: 401);
    }
    return result;
  }

  Future<void> performAction(JsonMap body) async {
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
  }

  Future<void> Function()? beforeLogout;

  Future<void> logout() async {
    try {
      await beforeLogout?.call();
    } catch (_) {
      /* Local logout must remain possible offline. */
    }
    final token = _token, origin = _apiBaseUrl, account = _account;
    final deviceToken = _deviceToken;
    ++_generation;
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
        if (_user == null) {
          _error =
              'Lokal abgemeldet. Die Sitzung konnte am Server wegen der fehlenden Verbindung noch nicht widerrufen werden.';
          _notify();
        }
      }
    }
    if (_identity != null) await _identity.signOut();
  }

  void _resetMemory() {
    _token = null;
    _account = null;
    _user = null;
    _expiresAt = null;
    _deviceToken = null;
    _baseSnapshot = {};
    _events = [];
    _absences = [];
    _polls = [];
    _productions = [];
    _members = [];
    _outbox = [];
    _scripts.clear();
    _preferences = {};
    _demoFocus.clear();
    _loadingScripts.clear();
    _lastSync = null;
    _busyCount = 0;
    _isDemo = false;
    _isOffline = false;
    _refreshTask = null;
    _drainTask = null;
    _checkinsByEvent = {};
    _checkinVersions = {};
    _capabilities = {};
    _mutationVersion = 0;
    _reminders = {'dayBefore': true, 'twoHours': true, 'changes': true};
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

  Future<void> respond(
    String eventId,
    String status, {
    String reason = '',
    DateTime? expectedArrivalAt,
  }) async {
    final event = _events.where((e) => e.id == eventId).firstOrNull;
    if (event == null) {
      throw const ApiException(
        'Der Termin ist nicht mehr verfügbar.',
        statusCode: 404,
      );
    }
    if (event.locked) {
      throw const ApiException(
        'Die Rückmeldefrist ist abgelaufen.',
        statusCode: 409,
      );
    }
    if (!const {'open', 'yes', 'late', 'no'}.contains(status)) {
      throw const ApiException('Ungültige Rückmeldung.', statusCode: 400);
    }
    if (reason.trim().length > 500) {
      throw const ApiException(
        'Der Absagegrund darf höchstens 500 Zeichen haben.',
        statusCode: 400,
      );
    }
    if (status == 'late' &&
        expectedArrivalAt != null &&
        (event.startsAt == null ||
            event.endsAt == null ||
            !expectedArrivalAt.isAfter(event.startsAt!) ||
            !expectedArrivalAt.isBefore(event.endsAt!))) {
      throw const ApiException(
        'Die Ankunft muss zwischen Beginn und Ende der Probe liegen.',
        statusCode: 400,
      );
    }
    await performAction({
      'action': 'attendance',
      'eventId': eventId,
      'status': status,
      'reason': status == 'no' ? reason.trim() : '',
      'expectedArrivalAt': status == 'late'
          ? expectedArrivalAt?.toUtc().toIso8601String()
          : null,
    });
  }

  Future<void> vote(String pollId, String optionId) async {
    final poll = _polls.where((e) => e.id == pollId).firstOrNull;
    if (poll == null || !poll.options.any((e) => e.id == optionId)) {
      throw const ApiException(
        'Diese Abstimmungsoption ist nicht verfügbar.',
        statusCode: 404,
      );
    }
    if (poll.isClosed) {
      throw const ApiException(
        'Die Abstimmung ist bereits beendet.',
        statusCode: 409,
      );
    }
    await _enqueue({
      'action': 'poll.vote',
      'pollId': pollId,
      'optionId': optionId,
    });
  }

  Future<void> addAbsence(DateTime from, DateTime to, String reason) async {
    if (dateOnly(to).compareTo(dateOnly(from)) < 0) {
      throw const ApiException(
        'Das Enddatum liegt vor dem Startdatum.',
        statusCode: 400,
      );
    }
    if (reason.trim().length > 500) {
      throw const ApiException(
        'Der Grund darf höchstens 500 Zeichen haben.',
        statusCode: 400,
      );
    }
    await _enqueue({
      'action': 'absence.create',
      'from': dateOnly(from),
      'to': dateOnly(to),
      'reason': reason.trim(),
    });
  }

  Future<void> deleteAbsence(String id) async {
    final generation = _generation;
    if (id.startsWith('local:')) {
      final pendingId = id.substring(6);
      // A request may already be in flight; wait until its outcome is known.
      if (_drainTask != null) await _drainTask;
      if (!_current(generation)) return;
      final pending = _outbox.where((e) => e.id == pendingId).firstOrNull;
      if (pending != null) {
        _outbox.removeWhere((e) => e.id == pendingId);
        _rebuild();
        await _persistCore(generation);
        _notify();
        return;
      }
      throw const ApiException(
        'Die Abwesenheit wurde bereits synchronisiert. Bitte aktualisieren und erneut auswählen.',
        statusCode: 409,
      );
    }
    await _enqueue({'action': 'absence.delete', 'id': id});
  }

  Future<void> saveReminders(Map<String, bool> value) => _enqueue({
    'action': 'settings.reminders',
    'value': {
      for (final key in ['dayBefore', 'twoHours', 'changes'])
        key: value[key] ?? false,
    },
  });
  Future<void> checkIn(String eventId, List<int> memberIds) async {
    if (_user?.isAdmin != true) {
      throw const ApiException(
        'Für den Check-in ist eine Adminrolle erforderlich.',
        statusCode: 403,
      );
    }
    if (!_events.any((e) => e.id == eventId)) {
      throw const ApiException(
        'Der Termin ist nicht verfügbar.',
        statusCode: 404,
      );
    }
    await _enqueue({
      'action': 'checkin.save',
      'eventId': eventId,
      'members': _members
          .where((m) => m.active)
          .map((m) => {'id': m.id, 'present': memberIds.contains(m.id)})
          .toList(),
    });
  }

  Future<void> linkEventScript(
    String eventId,
    String? productionId,
    List<String> sceneIds,
  ) async {
    if (_user?.isAdmin != true) {
      throw const ApiException(
        'Für die Zuordnung ist eine Adminrolle erforderlich.',
        statusCode: 403,
      );
    }
    if (!_events.any((e) => e.id == eventId)) {
      throw const ApiException(
        'Der Termin ist nicht verfügbar.',
        statusCode: 404,
      );
    }
    if (productionId != null &&
        !_productions.any((p) => p.id == productionId)) {
      throw const ApiException(
        'Die Produktion ist nicht verfügbar.',
        statusCode: 404,
      );
    }
    await _enqueue({
      'action': 'event.script',
      'eventId': eventId,
      'productionId': productionId,
      'sceneIds': productionId == null ? <String>[] : sceneIds.toSet().toList(),
    });
  }

  Future<void> linkEventToScript(
    String eventId,
    String? productionId,
    List<String> sceneIds,
  ) => linkEventScript(eventId, productionId, sceneIds);

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
        _outbox = _outbox
            .map((e) => e.id == action.id ? e.withStatus('failed', _error) : e)
            .toList();
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
    _productions = jsonList(view['productions']).map((e) {
      final production = Production.fromJson(jsonMap(e));
      return _scripts[production.id] == null
          ? production
          : production.withScript(_scripts[production.id]!);
    }).toList();
    _members = jsonList(
      view['members'],
    ).map((e) => TheaterMember.fromJson(jsonMap(e))).toList();
    _reminders = {
      for (final key in ['dayBefore', 'twoHours', 'changes'])
        key: jsonMap(view['reminders'])[key] == true,
    };
    _checkinsByEvent = jsonMap(view['checkinsByEvent']);
    _checkinVersions = jsonMap(view['checkinVersions']);
    _capabilities = jsonMap(view['capabilities']);
  }

  JsonMap _applyAction(
    JsonMap original,
    PendingAction action, {
    String? createdId,
  }) {
    final view = cloneJson(original), body = action.payload;
    switch (body['action']) {
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
          return poll.id == body['pollId']
              ? poll.withChoice(textValue(body['optionId'])).toJson()
              : e;
        }).toList();
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
            reasons = jsonMap(view['declineReasons']);
        for (final item in jsonList(view['events'])) {
          final event = jsonMap(item);
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
          }
        }
        view['attendanceByEvent'] = attendance;
        view['declineReasons'] = reasons;
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
      case 'event.script':
        view['events'] = jsonList(view['events']).map((item) {
          final event = jsonMap(item);
          return event['id'] == body['eventId']
              ? {
                  ...event,
                  'productionId': body['productionId'],
                  'sceneIds': body['sceneIds'],
                }
              : event;
        }).toList();
    }
    return view;
  }

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

  Future<void> setPreference(String key, Object? value) async {
    if (_account == null) return;
    if (value == null) {
      _preferences.remove(key);
    } else {
      _preferences[key] = value;
    }
    final generation = _generation;
    _notify();
    await _persist(generation, 'preferences', () => _preferences);
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

  Future<void> registerDevice(String token, String platform) async {
    if (_isDemo || _user == null) return;
    final generation = _generation;
    final response = await _api.request(
      _apiBaseUrl,
      'POST',
      '/devices',
      token: _token,
      body: {'token': token, 'platform': platform},
    );
    if (!_current(generation)) return;
    _deviceToken = token;
    _capabilities['pushConfigured'] = response['pushEnabled'] == true;
    await _persistCore(generation);
    _notify();
  }

  Future<void> unregisterDevice(String token) async {
    if (_isDemo || _user == null) return;
    final generation = _generation;
    await _api.request(
      _apiBaseUrl,
      'DELETE',
      '/devices',
      token: _token,
      body: {'token': token},
    );
    if (!_current(generation)) return;
    if (_deviceToken == token) _deviceToken = null;
    await _persistCore(generation);
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

  String _message(Object error) => identityError(error);
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
  String _uuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  @override
  void dispose() {
    _disposed = true;
    ++_generation;
    _api.close();
    super.dispose();
  }
}
