import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../data/api_client.dart';
import '../data/demo_data.dart';
import '../data/local_store.dart';
import '../features/casting/domain/casting.dart';
import 'models.dart';
import 'identity.dart';

part 'controller/projection.dart';
part 'controller/session.dart';
part 'controller/sync.dart';
part '../features/absences/state/absences_controller.dart';
part '../features/events/state/events_controller.dart';
part '../features/polls/state/polls_controller.dart';
part '../features/profile/state/profile_controller.dart';
part '../features/rehearsal/state/checkin_controller.dart';
part '../features/scripts/state/scripts_controller.dart';
part '../features/settings/state/settings_controller.dart';

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

  /// Slot pools ("Terminfinder"), newest first; includes queued bookings.
  List<JsonMap> get slotPools => _slotPools;
  List<JsonMap> _slotPools = const [];
  List<JsonMap> get pendingAccounts =>
      jsonList(_baseSnapshot['pendingAccounts']).map(jsonMap).toList();

  /// Registrations an admin can link now (confirmed identity and name given).
  int get openRegistrationCount => pendingAccounts
      .where(
        (a) =>
            a['status'] == 'pending' &&
            a['identityReady'] == true &&
            a['nameProvided'] != false,
      )
      .length;
  JsonMap get memberAttendanceByEvent =>
      jsonMap(_baseSnapshot['memberAttendanceByEvent']);
  JsonMap get arrivalsByEvent => jsonMap(_baseSnapshot['arrivalsByEvent']);
  JsonMap get checkinVersions => cloneJson(_checkinVersions);
  JsonMap _checkinVersions = {};
  List<JsonMap> get productionRecords =>
      jsonList(_baseSnapshot['productions']).map((item) {
        final record = jsonMap(item);
        final projected = _productions
            .where((p) => p.id == record['id'])
            .firstOrNull;
        return projected == null
            ? record
            : {
                ...record,
                'archived': projected.archived,
                'version': projected.version,
              };
      }).toList()..sort(
        (left, right) => Production.compareNewestFirst(
          Production.fromJson(left),
          Production.fromJson(right),
        ),
      );
  List<JsonMap> get memberRecords =>
      jsonList(_baseSnapshot['members']).map(jsonMap).toList();
  List<JsonMap> get personRoles =>
      jsonList(_baseSnapshot['personRoles']).map(jsonMap).toList();

  /// Readable target audience; no roles, productions or people = everyone.
  String audienceLabel(
    Iterable<String> roleIds, [
    Iterable<int> personIds = const [],
    Iterable<String> productionIds = const [],
  ]) {
    if (roleIds.isEmpty && personIds.isEmpty && productionIds.isEmpty) {
      return 'Alle';
    }
    final names = roleNames(roleIds);
    return [
      if (roleIds.isNotEmpty) names.isEmpty ? 'Gelöschte Rolle' : names,
      for (final id in productionIds)
        'Ensemble ${_productions.where((p) => p.id == id).firstOrNull?.title ?? 'Gelöschtes Stück'}',
      ..._members.where((m) => personIds.contains(m.id)).map((m) => m.name),
    ].join(' · ');
  }

  /// Active members reached by roles, production ensembles and named people;
  /// [everyone] reaches all active members.
  List<TheaterMember> recipientsOf(
    Iterable<String> roleIds,
    Iterable<int> personIds,
    Iterable<String> productionIds, {
    bool everyone = false,
  }) {
    final ensembles = ensemblesOf(productionIds).expand((e) => e).toSet();
    return _members
        .where(
          (m) =>
              m.active &&
              (everyone ||
                  roleIds.any(m.roleIds.contains) ||
                  personIds.contains(m.id) ||
                  ensembles.contains(m.id)),
        )
        .toList();
  }

  /// The ensembles of the given productions, one list per production.
  List<List<int>> ensemblesOf(Iterable<String> productionIds) => [
    for (final id in productionIds)
      _productions.where((p) => p.id == id).firstOrNull?.ensemble ?? const [],
  ];

  String roleNames(Iterable<String> ids) => personRoles
      .where((r) => ids.contains(r['id']))
      .map((r) => textValue(r['name']))
      .join(' · ');
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
  Future<void> _identityTransition = Future<void>.value();

  /// Current time of the injected clock, e.g. whether a slot has started.
  DateTime get now => _clock();

  Map<String, bool> _reminders = {
    'dayBefore': false,
    'twoHours': true,
    'changes': true,
    'emailEnabled': false,
  };

  /// Personal reminder lead time in minutes; null when switched off.
  int? _customReminderMinutes;
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
  List<Production> get activeProductions =>
      _productions.where((p) => !p.archived).toList();
  List<Production> get archivedProductions =>
      _productions.where((p) => p.archived).toList();
  List<TheaterMember> get members => List.unmodifiable(_members);
  List<PendingAction> get outbox => List.unmodifiable(_outbox);
  Map<String, ScriptDocument> get scripts => Map.unmodifiable(_scripts);
  Map<String, dynamic> get preferences => Map.unmodifiable(_preferences);
  Map<String, bool> get reminders => Map.unmodifiable(_reminders);
  int? get customReminderMinutes => _customReminderMinutes;
  JsonMap get checkinsByEvent => cloneJson(_checkinsByEvent);
  JsonMap get capabilities => Map.unmodifiable(_capabilities);
  Set<String> get loadingScripts => Set.unmodifiable(_loadingScripts);
  int get pendingCount => _outbox.where((e) => !e.failed).length;
  int get failedCount => _outbox.where((e) => e.failed).length;
  bool get pushConfigured =>
      _capabilities['pushConfigured'] == true ||
      _capabilities['pushEnabled'] == true ||
      _capabilities['push'] == true;

  bool get emailConfigured => _capabilities['emailConfigured'] == true;

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

  final _mediaCache = <String, MediaData>{};
  final _mediaLoading = <String, Future<MediaData>>{};
  Future<MediaData> mediaBytes(String path, {bool cache = true}) async {
    if (_isDemo || !hasAccess || _token == null) {
      throw const ApiException(
        'Bitte mit einem freigegebenen Theaterkonto anmelden.',
      );
    }
    if (cache && _mediaCache.containsKey(path)) {
      final value = _mediaCache.remove(path)!;
      _mediaCache[path] = value;
      return value;
    }
    if (cache && _mediaLoading.containsKey(path)) return _mediaLoading[path]!;
    final generation = _generation;
    Future<MediaData> fetch() async {
      final result = await _api.binary(_apiBaseUrl, path, token: _token!);
      if (!_current(generation) || !hasAccess) {
        throw const ApiException(
          'Das Konto hat sich geändert.',
          statusCode: 401,
        );
      }
      if (cache) {
        _mediaCache[path] = result;
        while (_mediaCache.length > 60 ||
            _mediaCache.values.fold<int>(0, (n, v) => n + v.bytes.length) >
                32 * 1024 * 1024) {
          _mediaCache.remove(_mediaCache.keys.first);
        }
      }
      return result;
    }

    final task = fetch();
    if (cache) _mediaLoading[path] = task;
    try {
      return await task;
    } finally {
      if (_current(generation)) _mediaLoading.remove(path);
    }
  }

  Future<void> Function()? beforeLogout;

  Future<void> registerDevice(
    String token,
    String platform, {
    bool notificationActions = false,
  }) async {
    if (_isDemo || _user == null) return;
    final generation = _generation;
    final response = await _api.request(
      _apiBaseUrl,
      'POST',
      '/devices',
      token: _token,
      body: {
        'token': token,
        'platform': platform,
        'notificationActions': notificationActions,
      },
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

  String _message(Object error) => identityError(error);

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
