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
import 'private_web_caches.dart';

part 'controller/bot_check.dart';
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
    // A cache-first start shows stored data before Firebase has restored
    // its sign-in; requests made meanwhile wait for it.
    _api.firebaseToken = identity == null
        ? null
        : (uid) async {
            if (_identityPending) await _identityReady;
            try {
              return await identity.token(uid);
            } catch (error) {
              // A disabled or deleted account signs out like a 401.
              throw identityTokenFailure(error) ?? error;
            }
          };
  }

  /// Whether a start may show the stored data of the last approved Firebase
  /// account before Firebase has confirmed the sign-in. The snapshot's
  /// `capabilities.features` can switch it off (`noCacheFirstStart`) or, with
  /// this default off, on (`cacheFirstStart`); the stored snapshot decides,
  /// so a change applies from the start after the next sync.
  static const cacheFirstStartByDefault = true;

  /// How long a confirmed access counts before the background sync asks
  /// `/auth/session` again. In between the snapshot itself proves the access:
  /// the server answers it with 403 `access` once it is gone.
  static const accessCheckInterval = Duration(minutes: 15);

  /// A device token this account registered within this period is not sent
  /// again when push is restored at a start.
  static const deviceRegistrationInterval = Duration(hours: 24);

  final ApiClient _api;
  final LocalStore _store;
  final CredentialStore _credentials;
  final IdentityService? _identity;
  IdentityService? get identity => _identity;
  bool get usesFirebase => _identity != null;
  bool get hasAccess => _user?.isApproved == true;
  List<JsonMap> get messages =>
      jsonList(_view['messages']).map(jsonMap).toList();

  /// Slot pools ("Terminfinder"), newest first; includes queued bookings.
  List<JsonMap> get slotPools => _slotPools;
  List<JsonMap> _slotPools = const [];
  List<JsonMap> get pendingAccounts =>
      jsonList(_view['pendingAccounts']).map(jsonMap).toList();

  /// Registrations an admin can link now (confirmed identity). A missing
  /// self-supplied name does not block linking; the provider name is shown.
  int get openRegistrationCount => pendingAccounts
      .where((a) => a['status'] == 'pending' && a['identityReady'] == true)
      .length;
  JsonMap get memberAttendanceByEvent =>
      jsonMap(_baseSnapshot['memberAttendanceByEvent']);

  /// Leaders only: per auto-accepted event the people who attend implicitly
  /// (no own yes, late or no and no covering absence). Kept apart from
  /// [memberAttendanceByEvent], which only holds real answers.
  JsonMap get implicitAttendanceByEvent =>
      jsonMap(_baseSnapshot['implicitAttendanceByEvent']);
  JsonMap get arrivalsByEvent => jsonMap(_baseSnapshot['arrivalsByEvent']);
  JsonMap get checkinVersions => cloneJson(_checkinVersions);
  JsonMap _checkinVersions = {};

  /// Leaders only: the people of [eventId] whose attendance was adopted from
  /// their own commitment (Termin-Kisten) instead of recorded by hand.
  Set<int> autoCheckins(String eventId) => {
    for (final id in jsonList(jsonMap(_view['autoCheckinsByEvent'])[eventId]))
      intValue(id),
  };
  List<JsonMap> get productionRecords =>
      jsonList(_view['productions']).map(jsonMap).toList()..sort(
        (left, right) => Production.compareNewestFirst(
          Production.fromJson(left),
          Production.fromJson(right),
        ),
      );
  List<JsonMap> get memberRecords =>
      jsonList(_view['members']).map(jsonMap).toList();
  List<JsonMap> get personRoles =>
      jsonList(_view['personRoles']).map(jsonMap).toList();

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

  /// The first sync after a cache-first start; it waits for Firebase, and
  /// refreshes started meanwhile join it.
  Future<void>? _startSync;
  final _firstSyncPending = ValueNotifier(false);

  /// Completes (never with an error) once Firebase has restored its sign-in.
  Future<void> _identityReady = Future.value();
  bool _identityPending = false;
  bool _refreshSilent = false, _refreshing = false;
  int _generation = 0, _busyCount = 0, _mutationVersion = 0;
  bool _initialized = false,
      _isDemo = false,
      _isOffline = false,
      _storeReady = false,
      _disposed = false;
  String _apiBaseUrl = const String.fromEnvironment('API_BASE_URL');
  String? _token, _account, _error, _deviceToken;
  DateTime? _lastSync, _expiresAt, _deviceRegisteredAt, _accessCheckedAt;
  Future<void>? _deviceRegistration;
  String? _deviceRegistrationToken;
  AppUser? _user;

  /// The user in the stored Firebase sign-in, as last read or written; a
  /// cache-first start shows it until the server answers.
  JsonMap? _storedUser;
  JsonMap _baseSnapshot = {};

  /// [_baseSnapshot] with the queued changes applied; set by `_rebuild`.
  JsonMap _view = {};
  List<TheaterEvent> _events = [];
  List<Absence> _absences = [];
  List<Poll> _polls = [];
  List<Production> _productions = [];
  List<TheaterMember> _members = [];
  List<PendingAction> _outbox = [];

  /// Server replies of confirmed changes, by outbox id, until they are read.
  final Map<String, JsonMap> _results = {};

  /// Rejections whose outbox entry was removed right away because sending
  /// it again cannot help, by outbox id, until they are read.
  final Map<String, ApiException> _rejections = {};
  final Map<String, ScriptDocument> _scripts = {};
  final Map<String, FocusState> _demoFocus = {};
  final Set<String> _loadingScripts = {};
  JsonMap _preferences = {};
  Future<void> _identityTransition = Future<void>.value();

  /// Bot check state of this device, see `controller/bot_check.dart`.
  bool _botCheckPassed = false, _botCheckUnsupported = false;
  String? _botCheckAnswer, _botProof;
  DateTime? _botProofExpiresAt;

  /// Current time of the injected clock, e.g. whether a slot has started.
  DateTime get now => _clock();

  Map<String, bool> _reminders = {..._defaultReminders};

  /// Personal reminder lead time in minutes; null when switched off.
  int? _customReminderMinutes;
  JsonMap _checkinsByEvent = {}, _capabilities = {};

  bool get initialized => _initialized;
  int get sessionEpoch => _generation;
  bool get busy => _busyCount > 0;

  /// True while any refresh runs, also a silent background refresh.
  bool get isRefreshing => _refreshing;

  /// True until a cache-first start has finished its first sync: what the
  /// stored data lacks may simply be new. Its own listenable, because an
  /// unchanged start must not redraw the app.
  ValueListenable<bool> get firstSyncPending => _firstSyncPending;
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

  /// Whether the server announced [feature] in `capabilities.features`.
  /// Older servers announce nothing, so new options stay hidden there.
  bool supports(String feature) =>
      jsonList(_capabilities['features']).contains(feature);

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
      'deviceRegisteredAt': _deviceRegisteredAt?.toIso8601String(),
    },
  );

  Future<JsonMap> remote(
    String path, {
    String method = 'GET',
    JsonMap? body,
    String? idempotencyKey,
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
    final JsonMap result;
    try {
      result = await _api.request(
        _apiBaseUrl,
        method,
        path,
        token: _token,
        body: body,
        idempotencyKey: idempotencyKey,
      );
    } on ApiException catch (error) {
      // An expired session signs out here just like during a refresh.
      if (error.isUnauthorized) await _expire(generation, error);
      rethrow;
    }
    if (!_current(generation)) {
      throw const ApiException('Das Konto hat sich geändert.', statusCode: 401);
    }
    return result;
  }

  final _mediaCache = <String, MediaData>{};
  final _mediaLoading = <String, Future<MediaData>>{};

  /// The already loaded media at [path], so images can show it in their
  /// first frame instead of a placeholder.
  MediaData? cachedMedia(String path) =>
      _isDemo || !hasAccess || _token == null ? null : _mediaCache[path];

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

  /// Registers [token] for push. With [ifStale] (restoring push at a start)
  /// a token this account registered within [deviceRegistrationInterval] is
  /// not sent again, and a registration of the same token already running is
  /// shared.
  Future<void> registerDevice(
    String token,
    String platform, {
    bool notificationActions = false,
    bool ifStale = false,
  }) {
    if (_isDemo || _user == null) return Future.value();
    if (ifStale) {
      final running = _deviceRegistration;
      if (running != null && _deviceRegistrationToken == token) return running;
      final at = _deviceRegisteredAt;
      final age = at == null ? null : _clock().difference(at);
      if (token == _deviceToken &&
          age != null &&
          !age.isNegative &&
          age < deviceRegistrationInterval) {
        return Future.value();
      }
    }
    final task = _registerDevice(token, platform, notificationActions);
    _deviceRegistration = task;
    _deviceRegistrationToken = token;
    return task.whenComplete(() {
      if (identical(_deviceRegistration, task)) {
        _deviceRegistration = null;
        _deviceRegistrationToken = null;
      }
    });
  }

  Future<void> _registerDevice(
    String token,
    String platform,
    bool notificationActions,
  ) async {
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
    _deviceRegisteredAt = _clock();
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
    if (_deviceToken == token) {
      _deviceToken = null;
      _deviceRegisteredAt = null;
    }
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
    _firstSyncPending.dispose();
    super.dispose();
  }
}
