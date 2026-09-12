import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:theater_app/core/app_controller.dart';
import 'package:theater_app/core/identity.dart';
import 'package:theater_app/core/models.dart';
import 'package:theater_app/data/api_client.dart';
import 'package:theater_app/data/local_store.dart';

class FakeIdentity implements IdentityService {
  @override
  String? uid;
  @override
  String? email;
  String tokenValue = 'fresh-token';
  @override
  bool emailVerified = true;
  @override
  List<String> linkedProviders = ['password'];
  @override
  Future<void> initialize() async {}
  @override
  Future<String> token(String expectedUid) async {
    if (uid != expectedUid) {
      throw const ApiException('Account changed', statusCode: 401);
    }
    return tokenValue;
  }

  @override
  Future<void> signIn(String email, String password) async {
    uid = email;
    this.email = email;
  }

  @override
  Future<void> register(String name, String email, String password) =>
      signIn(email, password);
  @override
  Future<void> social(String provider, {bool link = false}) async {}
  @override
  Future<void> verifyEmail() async {}
  @override
  Future<void> reload() async {}
  @override
  Future<void> resetPassword(String email) async {}
  @override
  Future<void> changePassword(String oldPassword, String nextPassword) async {}
  @override
  Future<void> addPassword(String password) async {}
  @override
  Future<void> unlink(String provider) async {}
  @override
  Future<void> signOut() async {
    uid = null;
  }
}

void main() {
  late FakeIdentity identity;
  late MemoryLocalStore store;
  late MemoryCredentialStore credentials;
  late AppController c;
  late String status;
  late List<String> paths, tokens;
  Completer<http.Response>? snapshotGate;
  Completer<void>? snapshotRequested;
  JsonMap user() => {
    'userId': identity.uid,
    'displayName': 'QA',
    'email': identity.email,
    'status': status,
    'identityReady': true,
    'emailVerified': true,
    'personId': status == 'approved' ? 1 : null,
    'role': 'member',
  };
  JsonMap snapshot() => {
    'apiVersion': 1,
    'user': user(),
    'events': [
      {
        'id': 'event',
        'title': 'Geschlossene Probe',
        'startsAt': '2027-01-01T18:00:00Z',
        'endsAt': '2027-01-01T20:00:00Z',
      },
    ],
  };
  http.Response response(JsonMap data) => http.Response(
    jsonEncode(data),
    200,
    headers: {'content-type': 'application/json'},
  );
  setUp(() async {
    identity = FakeIdentity();
    store = MemoryLocalStore();
    credentials = MemoryCredentialStore();
    status = 'pending';
    paths = [];
    tokens = [];
    snapshotGate = null;
    snapshotRequested = null;
    c = AppController(
      identity: identity,
      localStore: store,
      credentialStore: credentials,
      apiClient: ApiClient(
        client: MockClient((request) async {
          paths.add(request.url.path);
          tokens.add(request.headers['Authorization'] ?? '');
          if (request.url.path
              .replaceFirst(RegExp(r'/$'), '')
              .endsWith('/auth/session')) {
            return response({'user': user()});
          }
          if (request.url.path
              .replaceFirst(RegExp(r'/$'), '')
              .endsWith('/snapshot')) {
            snapshotRequested?.complete();
            return snapshotGate?.future ?? response(snapshot());
          }
          return response({'ok': true});
        }),
      ),
    );
    await c.init();
  });
  tearDown(() => c.dispose());
  Future<void> login(String email) => c.login(
    email: email,
    password: 'Long password!2026',
    baseUrl: 'https://theater.example.invalid',
  );
  test(
    'pending identity receives no snapshot; approval opens data and tokens refresh per request',
    () async {
      await login('one@example.invalid');
      expect(c.hasAccess, isFalse);
      expect(paths.where((x) => x.endsWith('/snapshot')), isEmpty);
      await expectLater(
        c.remote('/admin/accounts'),
        throwsA(isA<ApiException>()),
      );
      status = 'approved';
      identity.tokenValue = 'renewed-token';
      await c.refreshAccess();
      expect(c.hasAccess, isTrue);
      expect(c.events.single.title, 'Geschlossene Probe');
      expect(tokens.last, 'Bearer renewed-token');
      expect(credentials.value!['token'], 'firebase:one@example.invalid');
    },
  );
  test(
    'suspension clears private data and fences an earlier snapshot',
    () async {
      status = 'approved';
      await login('one@example.invalid');
      await c.setPreference('private-note', 'Privat');
      snapshotGate = Completer<http.Response>();
      snapshotRequested = Completer<void>();
      final stale = snapshot();
      final refresh = c.refresh();
      await snapshotRequested!.future;
      final epoch = c.sessionEpoch;
      status = 'suspended';
      await c.refreshAccess(refreshData: false);
      expect(c.sessionEpoch, greaterThan(epoch));
      expect(c.hasAccess, isFalse);
      expect(c.events, isEmpty);
      expect(c.preferences, isEmpty);
      snapshotGate!.complete(response(stale));
      await refresh;
      expect(c.hasAccess, isFalse);
      expect(c.events, isEmpty);
    },
  );
  test(
    'switching from approved account to pending account never carries internal data',
    () async {
      status = 'approved';
      await login('one@example.invalid');
      await c.setPreference('private-note', 'Privat');
      status = 'pending';
      await login('two@example.invalid');
      expect(c.user!.id, 'two@example.invalid');
      expect(c.hasAccess, isFalse);
      expect(c.events, isEmpty);
      expect(c.preferences, isEmpty);
      await c.logout();
      expect(identity.uid, isNull);
      expect(credentials.value, isNull);
    },
  );
}
